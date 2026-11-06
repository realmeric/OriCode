import AppKit
import cmark_gfm
import cmark_gfm_extensions
import SwiftUI

/// A reply's words in one read-only NSTextView on TextKit 2, so a drag runs from its first word
/// to its last and ⌘A takes the reply: SwiftUI's selection stays inside one view, and a reply
/// drawn as a view for each block stopped a drag at every paragraph's end. Prose, lists,
/// headings and quotes are text; code, tables, drawings and rules stay the views they were, each
/// laid over a line of the text held to its height, so the selection runs through them and Copy
/// gives their text in place.
@MainActor
final class ReplyPage: NSObject, NSTextViewDelegate {
    /// A view laid over the text: what ReplyBlock draws it from, and where.
    struct Piece: Identifiable {
        let id: Int
        let source: String
        /// What Copy gives for it.
        let copy: String
        let indent: CGFloat
        /// Still growing, the last of a reply still streaming.
        var open: Bool
        /// Its line in the text.
        var location: Int
        var height: CGFloat
        let style: NSParagraphStyle
    }

    private struct Shown {
        let source: String
        let rendered: ReplyMarkup.Rendered
        /// Where its text starts in the storage, after the line break before it.
        var start: Int
        var end: Int { start + rendered.text.length }
    }

    private(set) var pieces: [Piece] = []
    /// Moves with every change to the text, so the layout and the view hear of it.
    private(set) var version = 0
    private var shown: [Shown] = []
    private var live = false
    private var view: ReplyTextView?
    private var width: CGFloat = 0
    var openURL: OpenURLAction?

    var textView: ReplyTextView {
        if let view { return view }
        let view = ReplyTextView(usingTextLayoutManager: true)
        view.page = self
        view.delegate = self
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.autoresizingMask = []
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.writingToolsBehavior = .none
        view.linkTextAttributes = [
            .foregroundColor: ReplyMarkup.primary,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        if let container = view.textContainer {
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.size = CGSize(width: max(width, 1), height: .greatestFiniteMagnitude)
        }
        self.view = view
        return view
    }

    /// The reply as `text`, its blocks rendered again only from the first that changed: a delta
    /// touches the growing tail and none of the blocks before it.
    func show(id: UUID, text: String, live: Bool) {
        let sources = Reply.blocks(of: id, text: text)
        var first = 0
        while first < shown.count, first < sources.count, shown[first].source == sources[first] { first += 1 }
        if first == shown.count, first == sources.count {
            if live != self.live { self.live = live; markOpen() }
            return
        }
        self.live = live
        let storage = textView.textStorage!
        let keep = first == 0 ? 0 : shown[first - 1].end
        let kept = pieces.filter { $0.location < keep }
        let heights = Dictionary(uniqueKeysWithValues: pieces.map { ($0.id, $0.height) })
        shown.removeSubrange(first...)
        pieces = kept
        let tail = NSMutableAttributedString()
        var end = keep
        for index in first..<sources.count {
            let before = index == 0 ? 0 : ReplyMarkup.gap(top: ReplyMarkup.margins(of: sources[index]).top, after: shown.last?.rendered.margins)
            let rendered = ReplyMarkup.render(sources[index], before: before)
            guard rendered.text.length > 0 else {
                shown.append(Shown(source: sources[index], rendered: rendered, start: end))
                continue
            }
            if end > 0 {
                // The line break between two blocks is the earlier one's, as a paragraph's is.
                tail.append(ReplyMarkup.separator(after: end > keep ? tail : storage))
                end += 1
            }
            for piece in rendered.pieces {
                let id = pieces.count
                let height = heights[id] ?? piece.estimate
                pieces.append(Piece(id: id, source: piece.source, copy: piece.copy, indent: piece.indent, open: false,
                                    location: end + piece.offset, height: height, style: piece.style))
            }
            shown.append(Shown(source: sources[index], rendered: rendered, start: end))
            tail.append(rendered.text)
            end += rendered.text.length
        }
        let manager = textView.textContentStorage!
        manager.performEditingTransaction {
            storage.replaceCharacters(in: NSRange(location: keep, length: storage.length - keep), with: tail)
            for piece in pieces where piece.location >= keep { apply(piece, to: storage) }
        }
        markOpen()
        version += 1
    }

    private func markOpen() {
        let last = shown.last.map { $0.start } ?? 0
        for index in pieces.indices {
            pieces[index].open = live && index == pieces.count - 1 && pieces[index].location >= last
        }
    }

    private func apply(_ piece: Piece, to storage: NSTextStorage) {
        let style = piece.style.mutableCopy() as! NSMutableParagraphStyle
        style.minimumLineHeight = max(piece.height, 1)
        style.maximumLineHeight = max(piece.height, 1)
        storage.addAttribute(.paragraphStyle, value: style, range: NSRange(location: piece.location, length: 1))
    }

    /// Each piece's height at the width it's laid out at, as SwiftUI measured its view; its line
    /// is held to it.
    func measured(_ heights: [CGFloat]) {
        var changed: [Int] = []
        for (index, height) in heights.enumerated() where index < pieces.count {
            let height = height.rounded(.up)
            if abs(pieces[index].height - height) > 0.5 {
                pieces[index].height = height
                changed.append(index)
            }
        }
        guard !changed.isEmpty, let storage = view?.textStorage, let manager = view?.textContentStorage else { return }
        manager.performEditingTransaction {
            for index in changed { apply(pieces[index], to: storage) }
        }
    }

    /// The text's height at `width`, laid out to its end.
    func height(at width: CGFloat) -> CGFloat {
        let view = textView
        guard let manager = view.textLayoutManager, let container = view.textContainer else { return 0 }
        if abs(container.size.width - width) > 0.01 {
            self.width = width
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        }
        guard view.textStorage?.length ?? 0 > 0 else { return 0 }
        manager.ensureLayout(for: manager.documentRange)
        var bottom: CGFloat = 0
        manager.enumerateTextLayoutFragments(from: manager.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            bottom = fragment.layoutFragmentFrame.maxY
            return false
        }
        return ceil(bottom)
    }

    /// Where each piece's line is, laid out at the width last asked for.
    func frames() -> [CGRect] {
        guard let view, let manager = view.textLayoutManager, let content = view.textContentStorage else { return [] }
        return pieces.map { piece in
            guard let location = content.location(content.documentRange.location, offsetBy: piece.location),
                  let fragment = manager.textLayoutFragment(for: location) else { return .zero }
            let line = fragment.textLineFragments.first?.typographicBounds ?? .zero
            return CGRect(x: piece.indent, y: fragment.layoutFragmentFrame.minY + line.minY,
                          width: max(width - piece.indent, 0), height: piece.height)
        }
    }

    /// The selection as it reads: a piece's own text in its place, list markers as written, a
    /// blank line between paragraphs that are apart.
    func copy(_ range: NSRange) -> String {
        guard let storage = view?.textStorage, range.length > 0 else { return "" }
        var out = ""
        let string = storage.string as NSString
        storage.enumerateAttributes(in: range) { attributes, run, _ in
            if attributes[.replyPiece] != nil {
                if let piece = pieces.first(where: { NSLocationInRange($0.location, run) }) { out += piece.copy }
                return
            }
            if let marker = attributes[.replyMarker] as? String {
                // A marker is a tab, its bullet and a tab, copied once.
                if run.location == 0 || storage.attribute(.replyMarker, at: run.location - 1, effectiveRange: nil) == nil { out += marker }
                return
            }
            var text = string.substring(with: run)
            if text.contains("\n") {
                // The break before a paragraph apart from the one above is a blank line.
                var pieces: [String] = []
                var offset = run.location
                for (index, part) in text.components(separatedBy: "\n").enumerated() {
                    if index > 0 {
                        let next = offset
                        let style = next < storage.length ? storage.attribute(.paragraphStyle, at: next, effectiveRange: nil) as? NSParagraphStyle : nil
                        let gap = (style?.paragraphSpacingBefore ?? 0) + (style?.lineSpacing ?? 0)
                        pieces.append(gap >= 5 ? "\n\n" : "\n")
                    }
                    pieces.append(part)
                    offset += (part as NSString).length + 1
                }
                text = pieces.joined()
            }
            out += text.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{200B}", with: "")
        }
        return out
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
        guard let url else { return false }
        if let openURL { openURL(url) } else { NSWorkspace.shared.open(url) }
        return true
    }
}

final class ReplyTextView: NSTextView {
    weak var page: ReplyPage?

    /// The link under a point in the view, by the rectangle its characters are drawn in.
    func link(at point: CGPoint) -> URL? {
        guard let storage = textStorage, let manager = textLayoutManager, let content = textContentStorage else { return nil }
        let index = characterIndexForInsertion(at: point)
        for candidate in [index - 1, index] where candidate >= 0 && candidate < storage.length {
            guard let url = storage.attribute(.link, at: candidate, effectiveRange: nil) as? URL,
                  let start = content.location(content.documentRange.location, offsetBy: candidate),
                  let end = content.location(start, offsetBy: 1),
                  let range = NSTextRange(location: start, end: end) else { continue }
            var hit = false
            manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
                hit = frame.contains(point)
                return !hit
            }
            if hit { return url }
        }
        return nil
    }

    /// What a reply's text offers on a right-click: its link's, and Copy. An editor's menu
    /// would offer to cut, paste and check the spelling of words nobody can change.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let url = link(at: convert(event.locationInWindow, from: nil)) {
            let open = NSMenuItem(title: "Open Link", action: #selector(openLink(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = url
            menu.addItem(open)
            let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLink(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = url
            menu.addItem(copy)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: ""))
        return menu
    }

    /// A click on a link opens it, as a link in the old reply did: a press that ends on the
    /// same link without having selected anything. The first click of a double-click opens it,
    /// the second picks the word. AppKit's own opening waits to see whether a double-click
    /// follows, and is turned off below so a link opens once.
    private var pressed: URL?

    /// The first click into an inactive window is the window's to take, as it is for the rest of
    /// the transcript.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let content = window?.contentView, content !== self else { return false }
        return content.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event.clickCount == 1 ? link(at: convert(event.locationInWindow, from: nil)) : nil
        super.mouseDown(with: event)
        // AppKit's text tracks the press to its end here, or hands the end to mouseUp.
        if let up = window?.currentEvent, up.type == .leftMouseUp { released(up) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        released(event)
    }

    private func released(_ up: NSEvent) {
        guard let url = pressed else { return }
        pressed = nil
        guard selectedRange().length == 0, link(at: convert(up.locationInWindow, from: nil)) == url else { return }
        _ = delegate?.textView?(self, clickedOnLink: url, at: 0)
    }

    override func clicked(onLink link: Any, at charIndex: Int) {}

    @objc private func openLink(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        _ = delegate?.textView?(self, clickedOnLink: url, at: 0)
    }

    @objc private func copyLink(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        LinkArea.copy(url)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let page else { return super.writeSelection(to: pboard, types: types) }
        let text = MainActor.assumeIsolated {
            selectedRanges.map { page.copy($0.rangeValue) }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard !text.isEmpty else { return false }
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(text, forType: .string)
    }
}

/// The text view, sized by the page at the width it's given.
private struct ReplyTextHost: NSViewRepresentable {
    let page: ReplyPage
    let version: Int
    let openURL: OpenURLAction

    func makeNSView(context: Context) -> ReplyTextView {
        page.textView
    }

    func updateNSView(_ view: ReplyTextView, context: Context) {
        page.openURL = openURL
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ReplyTextView, context: Context) -> CGSize? {
        let width = ReplyLayout.width(proposal)
        return CGSize(width: width, height: page.height(at: width))
    }
}

/// The text with each piece's view laid over its line: the pieces are measured first, at the
/// width they'll have, their lines held to those heights, and the text measured after, all in
/// one pass, so nothing lands a frame late.
private struct ReplyLayout: Layout {
    let page: ReplyPage
    let version: Int

    static func width(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite, width > 0 else { return 560 }
        return width
    }

    private func measure(_ subviews: Subviews, width: CGFloat) {
        MainActor.assumeIsolated {
            let pieces = page.pieces
            var heights: [CGFloat] = []
            for (index, piece) in pieces.enumerated() where index + 1 < subviews.count {
                heights.append(subviews[index + 1].sizeThatFits(ProposedViewSize(width: max(width - piece.indent, 0), height: nil)).height)
            }
            page.measured(heights)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = Self.width(proposal)
        measure(subviews, width: width)
        return CGSize(width: width, height: MainActor.assumeIsolated { page.height(at: width) })
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        measure(subviews, width: bounds.width)
        let (height, frames) = MainActor.assumeIsolated { (page.height(at: bounds.width), page.frames()) }
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: height))
        for (index, frame) in frames.enumerated() where index + 1 < subviews.count {
            subviews[index + 1].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                      proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

struct ReplyText: View {
    let id: UUID
    let text: String
    let live: Bool
    @State private var page = ReplyPage()
    @Environment(\.openURL) private var openURL

    var body: some View {
        page.show(id: id, text: text, live: live)
        return ReplyLayout(page: page, version: page.version) {
            ReplyTextHost(page: page, version: page.version, openURL: openURL)
            ForEach(page.pieces) { piece in
                ReplyBlock(source: piece.source, open: piece.open)
                    .equatable()
            }
        }
    }
}

extension NSAttributedString.Key {
    /// The line a piece's view is laid over.
    static let replyPiece = NSAttributedString.Key("OriCodeReplyPiece")
    /// A list's marker and the tabs around it, copied as written.
    static let replyMarker = NSAttributedString.Key("OriCodeReplyMarker")
}

/// Markdown as the glass theme draws it (MarkdownTheme.swift), written as attributed text:
/// the same fonts, ink and margins, spaced by MarkdownUI's rule, the larger of a block's top
/// margin and the bottom margin of the one before.
enum ReplyMarkup {
    struct Margins: Equatable {
        var top: CGFloat?
        var bottom: CGFloat?

        mutating func merge(_ other: Margins) {
            top = [top, other.top].compactMap { $0 }.max()
            bottom = [bottom, other.bottom].compactMap { $0 }.max()
        }
    }

    struct Piece {
        let source: String
        let copy: String
        let indent: CGFloat
        /// Its line, from the block's start.
        let offset: Int
        let estimate: CGFloat
        let style: NSParagraphStyle
    }

    final class Rendered {
        let text: NSAttributedString
        let pieces: [Piece]
        let margins: Margins

        init(text: NSAttributedString, pieces: [Piece], margins: Margins) {
            self.text = text
            self.pieces = pieces
            self.margins = margins
        }
    }

    static let primary = NSColor(white: 1, alpha: 0.92)
    static let secondary = NSColor(white: 1, alpha: 0.55)
    static let card = NSColor(white: 1, alpha: 0.05)
    static let size: CGFloat = 14
    /// SwiftUI's spacing between two blocks when neither has a margin.
    static let fallback: CGFloat = 8
    /// The gap between a list's marker and its text.
    static let markerGap: CGFloat = 8
    /// A paragraph's `.lineSpacing(3)`.
    static let lineSpacing: CGFloat = 3

    nonisolated(unsafe) private static let cache: NSCache<NSString, Rendered> = {
        let cache = NSCache<NSString, Rendered>()
        cache.countLimit = 2000
        return cache
    }()

    /// The line break after a paragraph, which is the paragraph's, and not its piece's or marker's.
    static func separator(after text: NSAttributedString) -> NSAttributedString {
        var attributes = text.attributes(at: text.length - 1, effectiveRange: nil)
        attributes[.replyPiece] = nil
        attributes[.replyMarker] = nil
        attributes[.attachment] = nil
        attributes[.link] = nil
        return NSAttributedString(string: "\n", attributes: attributes)
    }

    static func gap(top: CGFloat?, after previous: Margins?, tight: Bool = false) -> CGFloat {
        [top, tight ? nil : previous?.bottom].compactMap { $0 }.max() ?? fallback
    }

    /// A block's margins, the largest of each among its nodes, as the reply spaces it.
    static func margins(of source: String) -> Margins {
        parse(source) { document in
            var margins = Margins()
            var node = cmark_node_first_child(document)
            while let child = node {
                margins.merge(Self.margins(child))
                node = cmark_node_next(child)
            }
            return margins
        } ?? Margins()
    }

    /// A top-level block's text, its first paragraph `before` below the block above.
    static func render(_ source: String, before: CGFloat) -> Rendered {
        let key = "\(before)|\(source)" as NSString
        if let rendered = cache.object(forKey: key) { return rendered }
        let rendered = parse(source) { document -> Rendered in
            let writer = Writer()
            writer.gap = before
            var nodes: [UnsafeMutablePointer<cmark_node>] = []
            var node = cmark_node_first_child(document)
            while let child = node {
                nodes.append(child)
                node = cmark_node_next(child)
            }
            var margins = Margins()
            for child in nodes { margins.merge(Self.margins(child)) }
            writer.whole = nodes.count == 1 ? source : nil
            writer.sequence(nodes, Context())
            return Rendered(text: writer.out, pieces: writer.pieces, margins: margins)
        } ?? Rendered(text: NSAttributedString(), pieces: [], margins: Margins())
        cache.setObject(rendered, forKey: key)
        return rendered
    }

    private static func parse<T>(_ source: String, _ body: (UnsafeMutablePointer<cmark_node>) -> T) -> T? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        return body(document)
    }

    fileprivate static func type(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        String(cString: cmark_node_get_type_string(node))
    }

    fileprivate static func children(_ node: UnsafeMutablePointer<cmark_node>) -> [UnsafeMutablePointer<cmark_node>] {
        var out: [UnsafeMutablePointer<cmark_node>] = []
        var child = cmark_node_first_child(node)
        while let next = child {
            out.append(next)
            child = cmark_node_next(next)
        }
        return out
    }

    /// The theme's margins for a node, the largest among it and what's inside it.
    fileprivate static func margins(_ node: UnsafeMutablePointer<cmark_node>) -> Margins {
        switch type(node) {
        case "paragraph", "html_block": return Margins(top: 0, bottom: 10)
        case "heading":
            switch cmark_node_get_heading_level(node) {
            case 1: return Margins(top: 16, bottom: 8)
            case 2: return Margins(top: 14, bottom: 6)
            case 3: return Margins(top: 12, bottom: 4)
            default: return Margins()
            }
        case "code_block", "table": return Margins(top: 4, bottom: 12)
        case "thematic_break": return Margins(top: 10, bottom: 10)
        case "item", "tasklist":
            var margins = Margins(top: 3)
            for child in children(node) { margins.merge(Self.margins(child)) }
            return margins
        default:
            var margins = Margins()
            for child in children(node) { margins.merge(Self.margins(child)) }
            return margins
        }
    }

    fileprivate struct Context {
        var indent: CGFloat = 0
        var color = primary
        var tight = false
        var level = 0
    }

    fileprivate struct Inline {
        var size: CGFloat = ReplyMarkup.size
        var weight: NSFont.Weight = .regular
        var italic = false
        var strike = false
        var color = primary
        var link: URL?
    }

    nonisolated(unsafe) private static var fonts: [String: NSFont] = [:]

    fileprivate static func font(size: CGFloat, weight: NSFont.Weight, italic: Bool, mono: Bool) -> NSFont {
        let key = "\(size)|\(weight.rawValue)|\(italic)|\(mono)"
        if let font = fonts[key] { return font }
        var font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        fonts[key] = font
        return font
    }

    nonisolated(unsafe) private static var bullets: [String: NSTextAttachment] = [:]

    fileprivate static func bullet(_ symbol: String, color: NSColor) -> NSTextAttachment {
        let key = "\(symbol)|\(color.alphaComponent)"
        if let made = bullets[key] { return made }
        let attachment = NSTextAttachment()
        let configuration = NSImage.SymbolConfiguration(pointSize: round(size / 3), weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        attachment.image = image
        let side = image?.size ?? CGSize(width: 5, height: 5)
        attachment.bounds = CGRect(x: 0, y: bulletRise, width: side.width, height: side.height)
        bullets[key] = attachment
        return attachment
    }

    static let bulletRise: CGFloat = 2

    fileprivate final class Writer {
        let out = NSMutableAttributedString()
        var pieces: [Piece] = []
        /// The space above the next paragraph.
        var gap: CGFloat = 0
        /// A list item's marker, which its first paragraph starts with.
        var marker: (text: String, copy: String, at: CGFloat, width: CGFloat)?
        /// The block's source when it is one node, which a piece that is the whole block is drawn from.
        var whole: String?

        func sequence(_ nodes: [UnsafeMutablePointer<cmark_node>], _ context: Context) {
            var previous: Margins?
            for (index, node) in nodes.enumerated() {
                let margins = ReplyMarkup.margins(node)
                if index > 0 { gap = ReplyMarkup.gap(top: margins.top, after: previous, tight: context.tight) }
                block(node, context)
                previous = margins
            }
        }

        private func block(_ node: UnsafeMutablePointer<cmark_node>, _ context: Context) {
            switch ReplyMarkup.type(node) {
            case "paragraph":
                if contains(node, "image") {
                    piece(source: commonmark(node), copy: plain(node), context, estimate: 120)
                } else {
                    paragraph(context, lineSpacing: ReplyMarkup.lineSpacing) { inlines(node, Inline(color: context.color), into: $0) }
                }
            case "html_block":
                var literal = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                if literal.hasSuffix("\n") { literal.removeLast() }
                paragraph(context, lineSpacing: ReplyMarkup.lineSpacing) {
                    $0.append(NSAttributedString(string: literal.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes(Inline(color: context.color))))
                }
            case "heading":
                var style = Inline(color: context.color)
                switch cmark_node_get_heading_level(node) {
                case 1: style.size = 18; style.weight = .semibold
                case 2: style.size = 16; style.weight = .semibold
                case 3: style.size = 14; style.weight = .semibold
                default: break
                }
                paragraph(context, lineSpacing: 0) { inlines(node, style, into: $0) }
            case "block_quote":
                var inner = context
                inner.indent += 12
                inner.color = ReplyMarkup.secondary
                sequence(ReplyMarkup.children(node), inner)
            case "list":
                list(node, context)
            case "code_block":
                var literal = cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
                if literal.hasSuffix("\n") { literal.removeLast() }
                let info = cmark_node_get_fence_info(node).map { String(cString: $0) } ?? ""
                let lines = CGFloat(literal.split(separator: "\n", omittingEmptySubsequences: false).count)
                piece(source: whole(node) ?? fenced(literal, info: info), copy: literal, context, estimate: 28 + lines * 15)
            case "table":
                piece(source: whole(node) ?? commonmark(node), copy: table(node), context, estimate: 30 * CGFloat(ReplyMarkup.children(node).count))
            case "thematic_break":
                piece(source: whole(node) ?? "---\n", copy: "", context, estimate: 1)
            default:
                break
            }
        }

        /// The block's whole source, when this node is all of it.
        private func whole(_ node: UnsafeMutablePointer<cmark_node>) -> String? {
            guard let whole, cmark_node_parent(node).map({ ReplyMarkup.type($0) == "document" }) == true else { return nil }
            return whole
        }

        private func list(_ node: UnsafeMutablePointer<cmark_node>, _ context: Context) {
            let tight = cmark_node_get_list_tight(node) != 0
            let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
            let start = Int(cmark_node_get_list_start(node))
            let items = ReplyMarkup.children(node)
            let level = context.level + 1
            let digits = NSFont.monospacedDigitSystemFont(ofSize: ReplyMarkup.size, weight: .regular)
            let markers: [String] = items.enumerated().map { index, item in
                if ReplyMarkup.type(item) == "tasklist" {
                    return cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑" : "☐"
                }
                if ordered { return "\(start + index)." }
                return ["circle.fill", "circle", "square.fill"][min(level, 3) - 1]
            }
            var width = ReplyMarkup.size * 1.5
            if ordered {
                for marker in markers {
                    width = max(width, ceil((marker as NSString).size(withAttributes: [.font: digits]).width))
                }
            }
            var inner = context
            inner.tight = tight
            inner.level = level
            inner.indent = context.indent + width + ReplyMarkup.markerGap
            var previous: Margins?
            for (index, item) in items.enumerated() {
                let margins = ReplyMarkup.margins(item)
                if index > 0 { gap = ReplyMarkup.gap(top: margins.top, after: previous, tight: tight) }
                let indent = String(repeating: "  ", count: level - 1)
                let written = markers[index].hasPrefix("circle") || markers[index].hasPrefix("square") ? ["circle.fill": "•", "circle": "◦", "square.fill": "▪"][markers[index]]! : markers[index]
                marker = (markers[index], indent + written + " ", context.indent, width)
                let children = ReplyMarkup.children(item)
                if children.isEmpty || ReplyMarkup.type(children[0]) != "paragraph" || contains(children[0], "image") {
                    paragraph(inner, lineSpacing: 0) { _ in }
                }
                sequence(children, inner)
                marker = nil
                previous = margins
            }
        }

        /// One paragraph of text, after a line break when it isn't the block's first.
        private func paragraph(_ context: Context, lineSpacing: CGFloat, _ content: (NSMutableAttributedString) -> Void) {
            let text = NSMutableAttributedString()
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            // TextKit gives a paragraph's line spacing above its first line too, which SwiftUI
            // keeps between its lines.
            style.paragraphSpacingBefore = max(gap - lineSpacing, 0)
            style.headIndent = context.indent
            style.firstLineHeadIndent = context.indent
            if let marker {
                // The marker right-aligned in its column, as MarkdownUI's label draws it.
                style.firstLineHeadIndent = marker.at
                style.tabStops = [
                    NSTextTab(textAlignment: .right, location: marker.at + marker.width),
                    NSTextTab(textAlignment: .left, location: context.indent),
                ]
                let copy: [NSAttributedString.Key: Any] = [.foregroundColor: context.color, .replyMarker: marker.copy]
                let font = NSFont.monospacedDigitSystemFont(ofSize: ReplyMarkup.size, weight: .regular)
                if marker.text.first?.isNumber == true || marker.text.count == 1 {
                    text.append(NSAttributedString(string: "\t\(marker.text)\t", attributes: copy.merging([.font: font]) { $1 }))
                } else {
                    // MarkdownUI's bullet: the symbol at a third of the text's size, on the middle of its x-height.
                    text.append(NSAttributedString(string: "\t", attributes: copy.merging([.font: font]) { $1 }))
                    let bullet = NSMutableAttributedString(attachment: ReplyMarkup.bullet(marker.text, color: context.color))
                    bullet.addAttributes(copy.merging([.font: font]) { $1 }, range: NSRange(location: 0, length: bullet.length))
                    text.append(bullet)
                    text.append(NSAttributedString(string: "\t", attributes: copy.merging([.font: font]) { $1 }))
                }
                self.marker = nil
            }
            content(text)
            if text.length == 0 {
                text.append(NSAttributedString(string: "\u{200B}", attributes: attributes(Inline(color: context.color))))
            }
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            if out.length > 0 { out.append(ReplyMarkup.separator(after: out)) }
            out.append(text)
            gap = 0
        }

        /// A line held for a view laid over it.
        private func piece(source: String, copy: String, _ context: Context, estimate: CGFloat) {
            if marker != nil { paragraph(context, lineSpacing: 0) { _ in } }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = gap
            style.headIndent = context.indent
            style.firstLineHeadIndent = context.indent
            style.minimumLineHeight = estimate
            style.maximumLineHeight = estimate
            if out.length > 0 { out.append(ReplyMarkup.separator(after: out)) }
            pieces.append(Piece(source: source, copy: copy, indent: context.indent, offset: out.length, estimate: estimate, style: style))
            out.append(NSAttributedString(string: "\u{200B}", attributes: [
                .font: ReplyMarkup.font(size: ReplyMarkup.size, weight: .regular, italic: false, mono: false),
                .paragraphStyle: style, .replyPiece: pieces.count - 1,
            ]))
            gap = 0
        }

        private var skipSpace = false

        private func inlines(_ node: UnsafeMutablePointer<cmark_node>, _ style: Inline, into text: NSMutableAttributedString) {
            for child in ReplyMarkup.children(node) { inline(child, style, into: text) }
        }

        private func inline(_ node: UnsafeMutablePointer<cmark_node>, _ style: Inline, into text: NSMutableAttributedString) {
            let literal = { cmark_node_get_literal(node).map { String(cString: $0) } ?? "" }
            switch ReplyMarkup.type(node) {
            case "text":
                var string = literal()
                if skipSpace {
                    skipSpace = false
                    string = String(string.drop(while: \.isWhitespace))
                }
                text.append(NSAttributedString(string: string, attributes: attributes(style)))
            case "softbreak", "linebreak":
                text.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
            case "code":
                var attributes = attributes(style)
                attributes[.font] = ReplyMarkup.font(size: style.size * 0.9, weight: style.weight, italic: style.italic, mono: true)
                attributes[.backgroundColor] = ReplyMarkup.card
                text.append(NSAttributedString(string: literal(), attributes: attributes))
            case "html_inline":
                let html = literal()
                if html.range(of: #"^<\s*br\s*/?\s*>$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    text.append(NSAttributedString(string: "\u{2028}", attributes: attributes(style)))
                    skipSpace = true
                } else {
                    text.append(NSAttributedString(string: html, attributes: attributes(style)))
                }
            case "emph":
                var inner = style
                inner.italic = true
                inlines(node, inner, into: text)
            case "strong":
                var inner = style
                inner.weight = .semibold
                inlines(node, inner, into: text)
            case "strikethrough":
                var inner = style
                inner.strike = true
                inlines(node, inner, into: text)
            case "link":
                var inner = style
                inner.link = cmark_node_get_url(node).flatMap { URL(string: String(cString: $0)) }
                inner.color = ReplyMarkup.primary
                inlines(node, inner, into: text)
            default:
                break
            }
        }

        private func attributes(_ style: Inline) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: ReplyMarkup.font(size: style.size, weight: style.weight, italic: style.italic, mono: false),
                .foregroundColor: style.color,
            ]
            if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = style.link { attributes[.link] = link }
            return attributes
        }

        private func contains(_ node: UnsafeMutablePointer<cmark_node>, _ kind: String) -> Bool {
            ReplyMarkup.children(node).contains { ReplyMarkup.type($0) == kind || contains($0, kind) }
        }

        private func commonmark(_ node: UnsafeMutablePointer<cmark_node>) -> String {
            guard let rendered = cmark_render_commonmark(node, CMARK_OPT_DEFAULT, 0) else { return "" }
            defer { free(rendered) }
            return String(cString: rendered)
        }

        private func plain(_ node: UnsafeMutablePointer<cmark_node>) -> String {
            guard let rendered = cmark_render_plaintext(node, CMARK_OPT_DEFAULT, 0) else { return "" }
            defer { free(rendered) }
            var text = String(cString: rendered)
            while text.hasSuffix("\n") { text.removeLast() }
            return text
        }

        /// The words of inline content, as they read.
        private func words(_ node: UnsafeMutablePointer<cmark_node>) -> String {
            ReplyMarkup.children(node).map { child in
                switch ReplyMarkup.type(child) {
                case "text", "code", "html_inline": cmark_node_get_literal(child).map { String(cString: $0) } ?? ""
                case "softbreak", "linebreak": " "
                default: words(child)
                }
            }.joined()
        }

        private func fenced(_ code: String, info: String) -> String {
            var longest = 0
            var run = 0
            for character in code {
                run = character == "`" ? run + 1 : 0
                longest = max(longest, run)
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            return "\(fence)\(info)\n\(code)\n\(fence)\n"
        }

        /// A table's rows, its cells apart by tabs.
        private func table(_ node: UnsafeMutablePointer<cmark_node>) -> String {
            ReplyMarkup.children(node).map { row in
                ReplyMarkup.children(row).map { cell in words(cell) }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }
}
