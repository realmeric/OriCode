import SwiftUI

/// An edit as the transcript shows it while Witness is the review: the lines it changed, each
/// drawn as the review draws it, with each later hunk's place where Legacy's card has a bare
/// gap. It has no scroll view of its own, so the wheel goes on scrolling the transcript over it,
/// and a line longer than the card is wide wraps under itself, its later rows marked.
struct WitnessDiff: View, Equatable {
    let diff: Diff
    /// How many rows it shows before saying how many more there are. An ask's has no limit,
    /// draws every removal and wraps a line longer than it is wide, since nothing else shows an
    /// edit that hasn't been made yet.
    var rows: Int? = WitnessDiff.shown
    /// The characters a line holds before it wraps, from the card's width.
    @State private var columns = 80

    nonisolated static func == (a: WitnessDiff, b: WitnessDiff) -> Bool {
        a.diff == b.diff && a.rows == b.rows
    }

    static let shown = 12
    /// The bytes of line a card pairs to find the words that changed, which it does in the frame
    /// that scrolls it into view: some thirty pairs of lines, and the first run of removed and
    /// added lines that would take it past that goes without, with everything after it.
    static let paired = 6000
    /// The characters of a line a card sets, wrapped to its width. Past them, a minified
    /// file's line, the card ends it in an ellipsis and the review has the rest.
    static let widest = 2000
    /// A card whose lines are all this short or shorter never wraps, and never measures itself.
    static let shortest = 40
    /// What marks a wrapped line's rows after its first, in the number column. SF Mono draws
    /// it one advance wide.
    static let wrapMark = "⤷"

    struct Hunk: Hashable {
        /// Where it is in the file, for every hunk after the first, or the gap's mark when the
        /// edit has no line numbers.
        var place: String?
        let lines: [ReviewLine]
        let words: [Int: [Range<Int>]]
        let pieces: [WitnessHunk.Piece]
    }

    struct Laid: Hashable {
        var digits = 0
        var hunks: [Hunk] = []
        /// The changed and unchanged lines it has past the ones drawn.
        var more = 0
    }

    /// The card's lines. One line past the rows asked for is drawn, where saying "1 more line"
    /// would take its row.
    static func lay(_ diff: Diff, rows: Int?, columns: Int = .max) -> Laid {
        let laid = cut(diff, rows: rows, columns: columns)
        guard let rows, laid.more == 1 else { return laid }
        return cut(diff, rows: rows + 1, columns: columns)
    }

    private static func cut(_ diff: Diff, rows: Int?, columns: Int) -> Laid {
        var laid = Laid()
        // As wide as the edit's own last number: a card isn't a page, and one from an edit
        // that hasn't reported its hunks has no numbers and no column for them.
        laid.digits = diff.lines.map { max($0.old ?? 0, $0.new ?? 0) }.max().flatMap { $0 > 0 ? String($0).count : nil } ?? 0
        var left = rows ?? .max
        var budget = rows == nil ? Int.max : paired
        var drawn = 0
        let hunks = diff.hunks
        for (index, lines) in hunks.enumerated() where left > 0 {
            let (words, known) = WordDiff.ranges(in: lines, spending: &budget)
            // Past a run it couldn't pair a card pairs nothing, so its washes stop at a line
            // and not here and there below it.
            if known < lines.count { budget = 0 }
            let pieces = WitnessHunk.pieces(lines, words: words, opened: rows == nil, whole: true, columns: columns, rows: left, known: known)
            for piece in pieces {
                left -= 1
                switch piece {
                case .lines(let range, _):
                    left -= range.count - 1
                    drawn += range.count
                case .removal(let range):
                    drawn += range.count
                }
            }
            laid.hunks.append(Hunk(place: index == 0 ? nil : UnitView.range(of: lines) ?? "⋯", lines: lines, words: words, pieces: pieces))
        }
        laid.more = hunks.reduce(0) { $0 + $1.count } - drawn
        return laid
    }

    /// A line as a card sets it before wrapping it: cut at `widest`, so a minified file's line
    /// isn't typeset whole to show its start, and with a space for any character inside it
    /// that would break the row and put every edge below it a row out.
    static func row(_ line: ReviewLine) -> ReviewLine {
        let bytes = line.text.utf8
        if bytes.count <= widest, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F || $0 == 9 }) { return line }
        var text = line.text
        if text.utf8.last == 13 { text.unicodeScalars.removeLast() }
        let cut = text.count > widest
        text = String(text.prefix(widest).map { $0.isNewline ? " " : $0 })
        if cut { text += "…" }
        var row = ReviewLine(kind: line.kind, text: text, old: line.old, new: line.new)
        row.noNewline = line.noNewline
        return row
    }

    /// A line's code cut into rows of at most `columns` characters, each row after the first
    /// with the wrap's mark where its number would be. `code` begins with the number column's
    /// `digits` characters. A line with anything the code's font doesn't draw one advance wide
    /// is cut at half the columns, which an emoji or a Chinese character, two advances or
    /// less, still fits in.
    static func wrapped(_ code: AttributedString, _ line: ReviewLine, digits: Int, columns: Int) -> [AttributedString] {
        let characters = code.characters
        let width = max(1, WitnessHunk.fits(WitnessHunk.drawn(line.text), columns: .max) ? columns : columns / 2)
        guard characters.count - digits > width else { return [code] }
        var mark = AttributedString(String(repeating: " ", count: max(0, digits - 1)) + wrapMark)
        mark.foregroundColor = Ink.faint
        mark[mark.characters.index(before: mark.endIndex)..<mark.endIndex].kern = WitnessHunk.gap
        var rows: [AttributedString] = []
        var start = characters.startIndex
        var take = digits + width
        while start < characters.endIndex {
            let end = characters.index(start, offsetBy: take, limitedBy: characters.endIndex) ?? characters.endIndex
            rows.append(rows.isEmpty ? AttributedString(code[start..<end]) : mark + AttributedString(code[start..<end]))
            start = end
            take = width
        }
        return rows
    }

    /// The card as one text, a line a row or a wrapped line's rows, and the rows with an edge.
    /// A view for each hunk and each of its pieces cost a card scrolled into view half as much
    /// again. `digits` is at least 1 when a line may wrap, for the mark's column.
    static func drawn(_ laid: Laid, digits: Int, columns: Int = .max) -> (text: AttributedString, added: [Range<Int>], deleted: [Range<Int>]) {
        var text = AttributedString()
        var added: [Range<Int>] = [], deleted: [Range<Int>] = []
        var row = 0
        func line(_ words: AttributedString) {
            if row > 0 { text.append(AttributedString("\n")) }
            text.append(words)
            row += 1
        }
        func aside(_ words: String, _ ink: Color) -> AttributedString {
            var aside = AttributedString(words)
            aside.font = Type.secondary
            aside.foregroundColor = ink
            return aside
        }
        func edge(_ runs: inout [Range<Int>]) {
            if let last = runs.last, last.upperBound == row { runs[runs.count - 1] = last.lowerBound..<(row + 1) } else { runs.append(row..<(row + 1)) }
        }
        for hunk in laid.hunks {
            if let place = hunk.place { line(WitnessHunk.margin(digits) + aside(place, Ink.faint)) }
            for piece in hunk.pieces {
                switch piece {
                case .lines(let range, _):
                    for index in range {
                        let source = hunk.lines[index]
                        let code = WitnessHunk.code([Self.row(source)], words: hunk.words[index].map { [0: $0] } ?? [:], 0..<1, numbered: digits)
                        for part in columns == .max ? [code] : wrapped(code, source, digits: digits, columns: columns) {
                            if source.kind == .added { edge(&added) }
                            if source.kind == .deleted { edge(&deleted) }
                            line(part)
                        }
                    }
                case .removal(let range):
                    edge(&deleted)
                    let name = WitnessHunk.naming(hunk.lines[range])
                    var removal = WitnessHunk.margin(digits) + aside("\(range.count) lines removed", Ink.deleted)
                    if !name.isEmpty {
                        removal += aside(" · ", Ink.secondary)
                        var named = AttributedString(name)
                        named.foregroundColor = Ink.deleted
                        removal += named
                    }
                    line(removal)
                }
            }
        }
        if laid.more > 0 { line(WitnessHunk.margin(digits) + aside("\(laid.more) more \(laid.more == 1 ? "line" : "lines")", Ink.faint)) }
        return (text, added, deleted)
    }

    var body: some View {
        if rows == nil { whole } else { card }
    }

    private var card: some View {
        let laid = Self.lay(diff, rows: rows)
        // Wrapped rather than scrolled sideways: the card is one text with its numbers in it
        // and no scroll view of its own, and rows it cuts itself keep every edge in step.
        let long = laid.hunks.contains { $0.lines.contains { $0.text.utf8.count > Self.shortest } }
        let digits = long ? max(laid.digits, 1) : laid.digits
        let drawn = Self.drawn(laid, digits: digits, columns: long ? columns : .max)
        // Rows no wider than the card, in a frame as wide as it; the clip is for a glyph
        // wider than two advances.
        return Text(drawn.text)
            .fixedSize()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, WitnessHunk.inset(digits))
            .font(Type.mono)
            .lineHeight(.exact(points: WitnessHunk.lineHeight))
            .background(alignment: .topLeading) {
                Edges(rows: drawn.added, fill: false).fill(Ink.added)
                Edges(rows: drawn.deleted, fill: false).fill(Ink.deleted)
            }
            .clipped()
            .onGeometryChange(for: Int.self) { geometry in
                Int((geometry.size.width - WitnessHunk.codeX(digits) - 12) / WitnessHunk.advance) - 1
            } action: { if long { columns = max(20, $0) } }
    }

    /// An ask's edit, laid out as the review lays a hunk: the lines that fit as one text, and a
    /// longer one wrapped under itself, so what is being allowed is all there to read.
    private var whole: some View {
        let laid = Self.lay(diff, rows: nil, columns: columns)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(laid.hunks.enumerated()), id: \.offset) { _, hunk in
                if let place = hunk.place {
                    Text(place)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.leading, WitnessHunk.codeX(laid.digits))
                        .frame(height: WitnessHunk.lineHeight)
                }
                ForEach(hunk.pieces, id: \.self) { piece in
                    // Nothing folds in an ask, so every piece is lines.
                    if case .lines(let range, let wraps) = piece {
                        WitnessHunk.block(hunk.lines, words: hunk.words, range: range, wraps: wraps, digits: laid.digits, reviewed: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Int.self) { geometry in
            Int((geometry.size.width - WitnessHunk.codeX(laid.digits) - 12) / WitnessHunk.advance) - 1
        } action: { columns = max(20, $0) }
    }
}
