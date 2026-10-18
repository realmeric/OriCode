import cmark_gfm
import cmark_gfm_extensions
import MarkdownUI
import SwiftUI

/// Claude's text as a Markdown view for each of its top-level blocks. One Markdown for the whole
/// reply coloured all its code in the frame the reply settled; now a code block takes its colours
/// on its own, once its fence closes or the reply moves past it, and a settle redraws only the
/// last block. The blocks are spaced as MarkdownUI spaces them inside one Markdown, from the
/// margins the theme gives them.
struct Reply: View {
    let id: UUID
    let text: String
    /// Still streaming, so its last block is still growing.
    let live: Bool
    @State private var margins: [Int: ReplyMargin.Value] = [:]

    /// The last split of each reply, which a body run again for anything but a delta reads.
    private static let splits = NSCache<NSUUID, Split>()

    private final class Split {
        let text: String
        let blocks: [String]

        init(text: String, blocks: [String]) {
            self.text = text
            self.blocks = blocks
        }
    }

    var body: some View {
        let blocks = blocks
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks.indices, id: \.self) { index in
                ReplyBlock(source: blocks[index], open: live && index == blocks.count - 1)
                    .equatable()
                    .onPreferenceChange(ReplyMargin.self) { margins[index] = $0 }
                    .padding(.top, index == 0 ? 0 : spacing(before: index))
            }
        }
        .markdownTheme(.glass)
        .markdownSoftBreakMode(.lineBreak)
        .environment(\.softBreaksAreLines, true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [String] { Self.blocks(of: id, text: text) }

    /// The reply's text cut into its blocks, kept for its next body: a stream asks how many
    /// there are as it shows a delta, and the body that follows finds them cut.
    static func blocks(of id: UUID, text: String) -> [String] {
        let key = id as NSUUID
        if let split = splits.object(forKey: key), split.text == text { return split.blocks }
        let blocks = split(text)
        splits.setObject(Split(text: text, blocks: blocks), forKey: key)
        return blocks
    }

    /// MarkdownUI's rule: the larger of the block's top margin and the bottom margin of the one
    /// before, and the system's spacing when neither has one.
    private func spacing(before index: Int) -> CGFloat? {
        [margins[index]?.top, margins[index - 1]?.bottom].compactMap { $0 }.max()
    }

    /// The text cut where each top-level block starts, as cmark finds them for MarkdownUI, tables
    /// included.
    static func split(_ text: String) -> [String] {
        var text = text
        // Where each line starts, in bytes, and whether one starts with a bracket after three
        // spaces at most, as a link definition does.
        var lines = [0]
        var bracketed = false
        text.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while let newline = memchr(base + start, Int32(UInt8(ascii: "\n")), bytes.count - start) {
                start = base.distance(to: newline.assumingMemoryBound(to: UInt8.self)) + 1
                lines.append(start)
            }
            bracketed = lines.contains { start in
                var offset = start
                while offset < min(start + 3, bytes.count), bytes[offset] == UInt8(ascii: " ") { offset += 1 }
                return offset < bytes.count && bytes[offset] == UInt8(ascii: "[")
            }
        }
        // A link defined in one block resolves only in the whole, so text that defines one stays whole.
        if bracketed, text.contains(/(?m)^ {0,3}\[[^\]]+\]:/) { return [text] }
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return [text] }
        defer { cmark_parser_free(parser) }
        if let table = cmark_find_syntax_extension("table") {
            cmark_parser_attach_syntax_extension(parser, table)
        }
        cmark_parser_feed(parser, text, text.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return [text] }
        defer { cmark_node_free(document) }
        // Lines count from 1. A table's header row can be the last line of a paragraph, and then
        // cmark-gfm gives the table the paragraph's first line and what's left of the paragraph
        // none: the paragraph starts there, and the table as many lines before its last as it has
        // rows, its delimiter row being the one more.
        var numbers: [Int] = []
        var node = cmark_node_first_child(document)
        while let block = node {
            var number = Int(cmark_node_get_start_line(block))
            if number == 0, let table = cmark_node_next(block) {
                number = Int(cmark_node_get_start_line(table))
            } else if String(cString: cmark_node_get_type_string(block)) == "table" {
                var rows = 0
                var row = cmark_node_first_child(block)
                while let next = row {
                    rows += 1
                    row = cmark_node_next(next)
                }
                number = Int(cmark_node_get_end_line(block)) - rows
            }
            // Anything out of order stays with the block before it.
            if (1...lines.count).contains(number), number > numbers.last ?? 0 { numbers.append(number) }
            node = cmark_node_next(block)
        }
        let utf8 = text.utf8
        let starts = numbers.map { utf8.index(utf8.startIndex, offsetBy: lines[$0 - 1]) }
        return starts.indices.map { i in
            String(text[starts[i]..<(i + 1 < starts.count ? starts[i + 1] : text.endIndex)])
        }
    }

    /// How long the last block of a reply still streaming goes without a word before it's taken
    /// as stopped. Longer than the gaps inside a sentence, so a block isn't made twice for one.
    static let pause = Duration.milliseconds(500)

    /// Whether the block is fenced code whose closing fence has come, after which it has nothing
    /// left to gain.
    static func fenced(_ source: String) -> Bool {
        var rest = source[...]
        while rest.last?.isWhitespace == true { rest = rest.dropLast() }
        guard let newline = rest.lastIndex(of: "\n") else { return false }
        let opening = rest.drop { $0 == " " }
        let closing = rest[rest.index(after: newline)...].drop { $0 == " " }
        return ["```", "~~~"].contains { opening.hasPrefix($0) && closing.hasPrefix($0) }
    }

    /// The last code block in a block and its fence's word, as MarkdownUI hands them to the
    /// highlighter: the code without its last newline.
    static func code(in source: String) -> (text: String, language: String?)? {
        guard source.contains("```") || source.contains("~~~") || source.contains("    ") || source.contains("\t"),
              let document = cmark_parse_document(source, source.utf8.count, CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_node_free(document) }
        guard let walk = cmark_iter_new(document) else { return nil }
        defer { cmark_iter_free(walk) }
        var found: (String, String?)?
        while cmark_iter_next(walk) != CMARK_EVENT_DONE {
            guard let node = cmark_iter_get_node(walk), cmark_node_get_type(node) == CMARK_NODE_CODE_BLOCK else { continue }
            let text = cmark_node_get_literal(node).map(String.init(cString:)) ?? ""
            found = (text.hasSuffix("\n") ? String(text.dropLast()) : text, cmark_node_get_fence_info(node).map(String.init(cString:)))
        }
        return found
    }
}

/// One top-level block of a reply. Equatable, so a block that hasn't changed isn't parsed or laid
/// out again when the reply grows.
private struct ReplyBlock: View, Equatable {
    let source: String
    /// The block still growing, whose code shows plain.
    let open: Bool
    /// Whether it has been made with its text selectable, as a stored reply's block is from the
    /// start and a live reply's last block is once it has stopped growing.
    @State private var made: Bool

    init(source: String, open: Bool) {
        self.source = source
        self.open = open
        _made = State(initialValue: !open)
    }

    nonisolated static func == (a: ReplyBlock, b: ReplyBlock) -> Bool {
        a.source == b.source && a.open == b.open
    }

    var body: some View {
        // An `svg` block is its drawing once its fence has closed, and says one is coming while it
        // streams; one the reply ended inside stays code.
        if let drawing = Drawing.source(of: source), drawing.closed || open {
            DrawingBlock(svg: drawing.svg, closed: drawing.closed) { code }
                .id(drawing.closed ? drawing.svg : "")
        } else {
            code
        }
    }

    /// Selection is laid out again over a block with every word it gains, a third of what a long
    /// code block cost to stream, so the block still growing has none. `textSelection` takes a
    /// type and can't be turned on in place: the block is made again, once, after it has stopped.
    /// In place, with no fade as a tool call's row comes in under it.
    @ViewBuilder private var code: some View {
        if made {
            Markdown(source)
                .markdownCodeSyntaxHighlighter(open ? StreamingCodeHighlighter(text: source) as CodeSyntaxHighlighter : TranscriptCodeHighlighter.shared)
                // A block with no link in it does nothing about pointers.
                .environment(\.linkPointers, .of(source))
                .textSelection(.enabled)
                .transition(.identity)
                // A block that had paused and has a word more is growing again.
                .onChange(of: source) { if open, !Reply.fenced(source) { made = false } }
        } else {
            let fenced = Reply.fenced(source)
            let growing = open && !fenced
            let awaited = !growing && awaited
            Markdown(source)
                // Code that waits for its colours stays plain, or it would take them here first.
                .markdownCodeSyntaxHighlighter(fenced ? .plainText as CodeSyntaxHighlighter : StreamingCodeHighlighter(text: source))
                // A block still growing does nothing about pointers: it's laid out again with
                // every word.
                .environment(\.linkPointers, .of(source, open: true))
                // Text that can't be selected opens its own links, which a growing block never did.
                .environment(\.openURL, OpenURLAction { _ in .discarded })
                .transition(.identity)
                // Not in the frame it stops in, which has the next block or a tool call's row to
                // make, and not before its code's colours are in hand: made at once it cost that
                // frame 10 ms after a paragraph, and code was laid out twice, plain and coloured.
                // The reply's last block has stopped when no word has come for `pause`, though
                // the turn runs on: Claude writes a tool's input for tens of seconds after its
                // last sentence, which reads as finished and is. Then in a frame the clock has
                // room in: 40 lines of code made again cost 13 ms, and beside another stream or
                // a block starting it was two frames.
                .task(id: Stop(length: growing ? source.utf8.count : nil, awaited: awaited)) {
                    guard !awaited else { return }
                    try? await Task.sleep(for: growing ? Reply.pause : Conversation.frame)
                    guard !Task.isCancelled else { return }
                    await StreamClock.shared.frameToMake()
                    if !Task.isCancelled { made = true }
                }
        }
    }

    /// What the wait to be made again starts over for: a word more, the block closing, its
    /// colours coming.
    private struct Stop: Equatable {
        let length: Int?
        let awaited: Bool
    }

    /// Whether the block's code is still being coloured.
    private var awaited: Bool {
        guard let code = Reply.code(in: source) else { return false }
        return TranscriptCodeHighlighter.shared.colours(code.text, language: code.language) == nil
    }
}
