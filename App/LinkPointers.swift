import AppKit
import cmark_gfm
import cmark_gfm_extensions
import MarkdownUI
import SwiftUI

/// Where the links are in the text MarkdownUI draws for one paragraph, heading or table cell.
/// MarkdownUI hands SwiftUI an attributed string, and SwiftUI's Text sets no pointer over a link
/// run and tells nobody which of its runs are links, so the text is written here the way
/// MarkdownUI's inline renderer writes it, and the layout SwiftUI made of that text says where
/// each link's characters are.
struct LinkSpans: Equatable {
    struct Link: Equatable {
        /// Which of the text's lines it's in, and where in that line, in UTF-16 units: how a
        /// Text's layout counts, starting again after each break.
        let line: Int
        let range: Range<Int>
        let url: URL
    }

    /// The drawn text, cut where it breaks the line itself. A layout has to be of this text
    /// before it's trusted.
    let text: [String]
    /// A link whose text has a break in it is here once for each side.
    let links: [Link]

    /// The links of a block written as `markdown`, or nil when it has none or its text can't be
    /// known: an inline image is a character once it loads and nothing before.
    static func of(_ markdown: String, softBreaksAreLines: Bool) -> LinkSpans? {
        guard scan(markdown).marked else { return nil }
        // Raw HTML is drawn as it's written, an address in it as plain words, and is handed on
        // as a paragraph that starts with an escaped `<`. Only text that starts with one is
        // written so, and a paragraph of such words goes without its pointers too.
        guard !markdown.drop(while: { $0 == " " }).hasPrefix("\\<") else { return nil }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        // The extensions MarkdownUI parses with.
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let found = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, found) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        guard let block = cmark_node_first_child(document), cmark_node_next(block) == nil,
              ["paragraph", "heading"].contains(type(of: block)) else { return nil }
        var writer = Writer(softBreaksAreLines: softBreaksAreLines)
        guard writer.write(block), !writer.links.isEmpty else { return nil }
        return LinkSpans(text: writer.text, links: writer.links)
    }

    /// Whether a block written as `source` can have a link in it whose place can be known, from a
    /// pass over its bytes and no parse: a block that can't asks for nothing more. An escape
    /// counts against it. MarkdownUI hands a block's text on with its escapes already read, so
    /// `www\.example.com`, written to be no link, would come back from `of` as one.
    static func canHold(_ source: String) -> Bool {
        let found = scan(source)
        return found.marked && !found.escaped
    }

    /// Whether the text has one of the marks every link cmark-gfm makes has in it, `](`, `]:`,
    /// `://`, `www.`, `@` or `<`, and whether it has a backslash or a character reference.
    fileprivate static func scan(_ markdown: String) -> (marked: Bool, escaped: Bool) {
        var markdown = markdown
        return markdown.withUTF8 { bytes in
            var marked = false
            var escaped = false
            func at(_ index: Int, _ character: Unicode.Scalar) -> Bool {
                index < bytes.count && bytes[index] == UInt8(ascii: character)
            }
            for index in bytes.indices {
                switch bytes[index] {
                case UInt8(ascii: "@"), UInt8(ascii: "<"):
                    marked = true
                case UInt8(ascii: "]"):
                    if at(index + 1, "(") || at(index + 1, ":") { marked = true }
                case UInt8(ascii: ":"):
                    if at(index + 1, "/"), at(index + 2, "/") { marked = true }
                case UInt8(ascii: "w"):
                    if at(index + 1, "w"), at(index + 2, "w"), at(index + 3, ".") { marked = true }
                case UInt8(ascii: "\\"):
                    escaped = true
                case UInt8(ascii: "&"):
                    // `&#58;`, or a name and its semicolon, `&colon;`.
                    var end = index + 1
                    while end < bytes.count, Unicode.Scalar(bytes[end]).properties.isAlphabetic || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) { end += 1 }
                    if at(index + 1, "#") || (end > index + 1 && at(end, ";")) { escaped = true }
                default:
                    break
                }
            }
            return (marked, escaped)
        }
    }

    /// The rectangles each link's text takes in the rows a layout wrapped the text into, one for
    /// each row it's on, in the layout's own space. Nil when the layout isn't of the text the
    /// links were found in. A layout's indices say only how far apart they are, so a character
    /// is counted from the lowest index of its line's first row.
    func rects<Index: Strideable>(in rows: [[Piece<Index>]]) -> [Rect]? where Index.Stride == Int {
        // A break with nothing after it is no row.
        let lines = text.indices.filter { !text[$0].isEmpty }
        var rects: [Rect] = []
        // Where each line starts, and the last character seen of it.
        var seen: [(start: Index, end: Index)] = []
        for (row, pieces) in rows.enumerated() {
            guard let low = pieces.map(\.character).min(), let high = pieces.map(\.character).max() else { continue }
            // A row that doesn't go on from the one before starts the next line.
            if let last = seen.last, last.end < low {
                seen[seen.count - 1].end = high
            } else {
                seen.append((low, high))
            }
            guard seen.count <= lines.count else { return nil }
            let line = lines[seen.count - 1]
            let start = seen[seen.count - 1].start
            for piece in pieces {
                let character = start.distance(to: piece.character)
                guard let link = links.firstIndex(where: { $0.line == line && $0.range.contains(character) }) else { continue }
                if let last = rects.indices.last, rects[last].link == link, rects[last].row == row {
                    rects[last].frame = rects[last].frame.union(piece.frame)
                } else {
                    rects.append(Rect(link: link, row: row, frame: piece.frame, url: links[link].url))
                }
            }
        }
        // Text that isn't the text written here, an image that loaded or a character MarkdownUI
        // writes some other way, would put the pointer over the wrong words: better none. Each
        // line has to end in its own last character, whose one glyph can stand for several units.
        guard seen.count == lines.count else { return nil }
        for (found, line) in zip(seen, lines) {
            let line = text[line]
            let end = found.start.distance(to: found.end)
            guard let last = line.indices.last, end < line.utf16.count,
                  end >= line.utf16.distance(from: line.startIndex, to: last) else { return nil }
        }
        return rects
    }

    /// One glyph of a layout: the character it draws and where.
    struct Piece<Index> {
        let character: Index
        let frame: CGRect
    }

    struct Rect: Equatable, Identifiable {
        let link: Int
        /// The row of the layout it's on.
        let row: Int
        var frame: CGRect
        let url: URL

        var id: [Int] { [link, row] }
    }

    private static func type(of node: UnsafeMutablePointer<cmark_node>) -> String {
        String(cString: cmark_node_get_type_string(node))
    }

    /// MarkdownUI's TextInlineRenderer and the AttributedStringInlineRenderer under it. The first
    /// renders a block's own inlines and hands anything but text and breaks to a new one of the
    /// second, each with its own memory of a break just written.
    private struct Writer {
        let softBreaksAreLines: Bool
        var text = [""]
        var links: [Link] = []

        mutating func write(_ block: UnsafeMutablePointer<cmark_node>) -> Bool {
            var skip = false
            var child = cmark_node_first_child(block)
            while let node = child {
                switch LinkSpans.type(of: node) {
                case "text":
                    guard write(Self.literal(node), skip: &skip) else { return false }
                case "softbreak":
                    if softBreaksAreLines {
                        skip = true
                        text.append("")
                    } else if skip {
                        skip = false
                    } else {
                        text[text.count - 1] += " "
                    }
                case "html_inline":
                    if Self.breaks(node) {
                        text.append("")
                        skip = true
                    } else {
                        var none = false
                        guard write(Self.literal(node), skip: &none) else { return false }
                    }
                case "image":
                    return false
                default:
                    var inner = false
                    guard nested(node, skip: &inner) else { return false }
                }
                child = cmark_node_next(node)
            }
            return true
        }

        private mutating func nested(_ node: UnsafeMutablePointer<cmark_node>, skip: inout Bool) -> Bool {
            switch LinkSpans.type(of: node) {
            case "text":
                return write(Self.literal(node), skip: &skip)
            case "softbreak":
                if softBreaksAreLines {
                    text.append("")
                } else if skip {
                    skip = false
                } else {
                    text[text.count - 1] += " "
                }
            case "linebreak":
                text.append("")
            case "code":
                var none = false
                return write(Self.literal(node), skip: &none)
            case "html_inline":
                if Self.breaks(node) {
                    text.append("")
                    skip = true
                } else {
                    return write(Self.literal(node), skip: &skip)
                }
            case "emph", "strong", "strikethrough", "link":
                let start = (line: text.count - 1, offset: text[text.count - 1].utf16.count)
                var child = cmark_node_first_child(node)
                while let inline = child {
                    guard nested(inline, skip: &skip) else { return false }
                    child = cmark_node_next(inline)
                }
                // A destination that's no URL is underlined and opens nothing.
                if LinkSpans.type(of: node) == "link", let url = cmark_node_get_url(node).flatMap({ URL(string: String(cString: $0)) }) {
                    for line in start.line..<text.count {
                        let range = (line == start.line ? start.offset : 0)..<text[line].utf16.count
                        if !range.isEmpty { links.append(Link(line: line, range: range, url: url)) }
                    }
                }
            default:
                // An image is nothing in an attributed string, but a paragraph that's only linked
                // images is drawn as views, and one with text around them isn't worth knowing.
                return false
            }
            return true
        }

        /// False for text that breaks the line by itself, where a layout starts counting again.
        private mutating func write(_ literal: String, skip: inout Bool) -> Bool {
            var literal = literal
            if skip {
                skip = false
                literal = literal.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
            }
            guard !literal.unicodeScalars.contains(where: {
                $0.properties.isWhitespace && $0.properties.generalCategory != .spaceSeparator && $0 != "\t"
            }) else { return false }
            text[text.count - 1] += literal
            return true
        }

        private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
            cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
        }

        /// Whether the tag is a `<br>`, found as MarkdownUI finds a tag's name.
        private static func breaks(_ node: UnsafeMutablePointer<cmark_node>) -> Bool {
            literal(node).firstMatch(of: /<\/?([a-zA-Z0-9]+)[^>]*>/)?.1.lowercased() == "br"
        }
    }
}

extension LinkSpans {
    /// The link rectangles in a layout SwiftUI made.
    func rects(in layout: Text.Layout) -> [Rect]? {
        rects(in: layout.map { line in
            line.flatMap { run in
                zip(run.characterIndices, run).map { index, glyph in
                    Piece(character: index, frame: glyph.typographicBounds.rect)
                }
            }
        })
    }
}

/// What a block does about the pointer over its links.
enum LinkPointing {
    /// Nothing: no link can be in it.
    case none
    /// Nothing yet. The block is still being written, and its every word would have its links
    /// found and its layout read again.
    case waiting
    case wanted

    /// For Markdown written as `source`, from `LinkSpans.canHold`. A block still being written
    /// waits from its first mark on, whatever is written after: an escape that came later would
    /// take it back to nothing, and each change of mind makes the block's text again.
    static func of(_ source: String, open: Bool = false) -> LinkPointing {
        let found = LinkSpans.scan(source)
        guard found.marked else { return .none }
        if open { return .waiting }
        return found.escaped ? .none : .wanted
    }
}

extension View {
    /// The link pointer over each link in the block MarkdownUI drew from `content`, and nowhere
    /// else in it. Where no link can be, nothing is rendered or read and no view is added.
    func linkPointers(_ content: MarkdownContent) -> some View {
        modifier(LinkPointers(content: content))
    }
}

private struct LinkPointers: ViewModifier {
    let content: MarkdownContent
    @Environment(\.softBreaksAreLines) private var softBreaksAreLines
    @Environment(\.linkPointers) private var pointing

    func body(content label: Content) -> some View {
        if pointing == .none {
            label
        } else {
            // The same view while the block waits as once it's whole, so a reply that ends
            // doesn't make its last block's text again.
            let spans = pointing == .wanted ? LinkSpans.of(content.renderMarkdown(), softBreaksAreLines: softBreaksAreLines) : nil
            // SwiftUI asks for these again when the text is laid out again, at a new width or
            // with new words, and not when the pointer moves or the transcript scrolls.
            label.overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                if let spans, layouts.count == 1, let rects = spans.rects(in: layouts[0].layout), !rects.isEmpty {
                    GeometryReader { proxy in
                        let origin = proxy[layouts[0].origin]
                        ForEach(rects) { rect in
                            LinkArea(url: rect.url)
                                .frame(width: rect.frame.width, height: rect.frame.height)
                                .offset(x: origin.x + rect.frame.minX, y: origin.y + rect.frame.minY)
                        }
                    }
                }
            }
        }
    }
}

/// A link's rectangle, clear, with the system's link pointer over it. SwiftUI gives a pointer
/// style to the view that takes the pointer's clicks, so this one takes them, and does with them
/// what a link does: a click opens it, a right-click offers to open or copy it. Nothing runs
/// while the pointer moves, and a panel drawn over the transcript hides it as it hides the words.
///
/// What it costs is that the words under it are no longer the text's to select from: a selection
/// can pass over a link, started anywhere else, but can't start on its words, nor can a
/// double-click pick one of them. A link is for opening before it's for selecting, and Copy Link
/// is in its menu.
struct LinkArea: View {
    let url: URL
    @Environment(\.openURL) private var openURL
    /// When it was last clicked, as the system counts uptime.
    @State private var tapped: TimeInterval?

    var body: some View {
        Color.clear
            .contentShape(.rect)
            .pointerStyle(.link)
            // A tap is no tap once the pointer has moved, so a press that turns into a drag
            // opens nothing.
            .onTapGesture {
                // A double-click is two taps, and opens the link once.
                let now = ProcessInfo.processInfo.systemUptime
                let again = tapped.map { now - $0 < NSEvent.doubleClickInterval } ?? false
                tapped = now
                if !again { openURL(url) }
            }
            .contextMenu {
                Button("Open Link") { openURL(url) }
                Button("Copy Link") { Self.copy(url) }
            }
            // The text's own link is the one read out.
            .accessibilityHidden(true)
    }

    /// The link as it was written: an address whole, a file's path as the reply gave it,
    /// `App/Foo.swift`.
    static func copy(_ url: URL, to board: NSPasteboard = .general) {
        board.clearContents()
        board.setString(url.absoluteString, forType: .string)
    }
}

extension EnvironmentValues {
    /// Whether the Markdown here breaks the line where its source does, which MarkdownUI keeps to
    /// itself and which changes what it writes after a break.
    @Entry var softBreaksAreLines = false
    /// Set where Markdown is drawn from a source that can hold a link.
    @Entry var linkPointers = LinkPointing.none
}
