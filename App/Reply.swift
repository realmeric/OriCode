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
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [String] {
        let key = id as NSUUID
        if let split = Self.splits.object(forKey: key), split.text == text { return split.blocks }
        let blocks = Self.split(text)
        Self.splits.setObject(Split(text: text, blocks: blocks), forKey: key)
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
}

/// One top-level block of a reply. Equatable, so a block that hasn't changed isn't parsed or laid
/// out again when the reply grows.
private struct ReplyBlock: View, Equatable {
    let source: String
    /// The block still growing, whose code shows plain.
    let open: Bool

    var body: some View {
        Markdown(source)
            .markdownCodeSyntaxHighlighter(open ? StreamingCodeHighlighter(text: source) as CodeSyntaxHighlighter : TranscriptCodeHighlighter.shared)
    }
}
