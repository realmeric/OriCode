import SwiftUI

/// An agent's reply in SwiftUI's own Text, block by block: paragraphs, headings, lists, quotes,
/// tables and code. A reply is read line by line, which leaves a stream's unclosed fence as code
/// so far, and each block's words are parsed once, so a reply growing parses its last block alone.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(MarkdownBlock.blocks(of: text).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum MarkdownBlock: Hashable {
    struct Item: Hashable {
        let level: Int
        let marker: String
        let text: String
    }

    case paragraph(String)
    case heading(Int, String)
    case list([Item])
    case quote(String)
    case code(String)
    case table([[String]])
    case rule

    static func blocks(of text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        var items: [Item] = []
        var quote: [Substring] = []
        var rows: [[String]] = []
        var fence: (marker: String, lines: [Substring])?

        func close() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !items.isEmpty { blocks.append(.list(items)) }
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
            if !rows.isEmpty { blocks.append(.table(rows)) }
            paragraph = []
            items = []
            quote = []
            rows = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let flat = line.drop { $0 == " " || $0 == "\t" }
            if let open = fence {
                if flat.hasPrefix(open.marker), flat.drop(while: { $0 == "`" || $0 == "~" }).allSatisfy(\.isWhitespace) {
                    blocks.append(.code(open.lines.joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.lines.append(line)
                }
            } else if flat.hasPrefix("```") || flat.hasPrefix("~~~") {
                close()
                fence = (String(flat.prefix(3)), [])
            } else if flat.isEmpty {
                close()
            } else if isRule(flat) {
                close()
                blocks.append(.rule)
            } else if let heading = heading(flat) {
                close()
                blocks.append(heading)
            } else if flat.hasPrefix(">") {
                if !quote.isEmpty { quote.append(flat.dropFirst().drop { $0 == " " }) } else {
                    close()
                    quote = [flat.dropFirst().drop { $0 == " " }]
                }
            } else if flat.hasPrefix("|") {
                if rows.isEmpty { close() }
                if !isDivider(flat) { rows.append(cells(flat)) }
            } else if let item = item(line, flat) {
                if items.isEmpty { close() }
                items.append(item)
            } else if !items.isEmpty, let last = items.last {
                // A line under an item goes on that item.
                items[items.count - 1] = Item(level: last.level, marker: last.marker, text: last.text + " " + flat)
            } else {
                paragraph.append(flat)
            }
        }
        close()
        if let fence { blocks.append(.code(fence.lines.joined(separator: "\n"))) }
        return blocks
    }

    private static func heading(_ line: Substring) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func isRule(_ line: Substring) -> Bool {
        let marks = line.filter { $0 != " " }
        return marks.count >= 3 && ["-", "*", "_"].contains { mark in marks.allSatisfy { String($0) == mark } }
    }

    private static func isDivider(_ line: Substring) -> Bool {
        line.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(_ line: Substring) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func item(_ line: Substring, _ flat: Substring) -> Item? {
        let level = (line.count - flat.count) / 2
        if let mark = flat.first, "-*+".contains(mark), flat.dropFirst().first == " " {
            return Item(level: level, marker: "•", text: String(flat.dropFirst(2)))
        }
        let digits = flat.prefix { $0.isNumber }
        let rest = flat.dropFirst(digits.count)
        guard !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return Item(level: level, marker: "\(digits).", text: String(rest.dropFirst(2)))
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(Inline.text(text))
                .font(.body)
                .foregroundStyle(Ink.primary)
        case .heading(let level, let text):
            Text(Inline.text(text))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .foregroundStyle(Ink.primary)
                .padding(.top, 4)
        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker)
                            .foregroundStyle(Ink.secondary)
                            .monospacedDigit()
                        Text(Inline.text(item.text))
                            .foregroundStyle(Ink.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.body)
                    .padding(.leading, CGFloat(item.level) * 18)
                }
            }
        case .quote(let text):
            Text(Inline.text(text))
                .font(.body)
                .foregroundStyle(Ink.secondary)
                .padding(.leading, 12)
                .background(alignment: .leading) {
                    Capsule().fill(Ink.faint).frame(width: 3)
                }
        case .code(let code):
            SideScroll {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                    .padding(12)
            }
        case .table(let rows):
            SideScroll {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(Inline.text(cell))
                                    .font(index == 0 ? .footnote.weight(.semibold) : .footnote)
                                    .foregroundStyle(index == 0 ? Ink.secondary : Ink.primary)
                                    .frame(maxWidth: 220, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(12)
            }
        case .rule:
            Rectangle()
                .fill(Ink.card)
                .frame(height: 1)
        }
    }
}

/// What's wider than the phone, on a card, moved sideways by hand. The thread's anchors and margins
/// stop here: they are the environment's, so they reach a scroll view inside a row too, and
/// changing under it as the thread scrolled kept the lazy stack from ever finishing its layout,
/// which hung the app for good.
private struct SideScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal) {
            content.fixedSize()
        }
        .defaultScrollAnchor(.leading)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollIndicators(.never)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.card, in: .rect(cornerRadius: 10, style: .continuous))
    }
}

/// A block's words with their emphasis, code and links, kept by their source: a body drawn again
/// doesn't parse again, and neither does a block a stream has moved past.
@MainActor
private enum Inline {
    private final class Parsed {
        let text: AttributedString

        init(_ text: AttributedString) {
            self.text = text
        }
    }

    private static let parsed = NSCache<NSString, Parsed>()

    static func text(_ source: String) -> AttributedString {
        if let kept = parsed.object(forKey: source as NSString) { return kept.text }
        var text = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        for run in text.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                text[run.range].font = .system(.callout, design: .monospaced)
                text[run.range].backgroundColor = Color.white.opacity(0.08)
            }
            if run.link != nil { text[run.range].underlineStyle = .single }
        }
        parsed.setObject(Parsed(text), forKey: source as NSString)
        return text
    }
}
