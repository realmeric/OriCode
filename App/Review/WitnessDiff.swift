import SwiftUI

/// An edit as the transcript shows it while Witness is the review: the lines it changed, each
/// drawn as the review draws it, with each later hunk's place where Legacy's card has a bare
/// gap. It has no scroll view of its own, so the wheel goes on scrolling the transcript over it.
struct WitnessDiff: View, Equatable {
    let diff: Diff
    /// How many rows it shows before saying how many more there are. An ask's has no limit,
    /// draws every removal and wraps a line longer than it is wide, since nothing else shows an
    /// edit that hasn't been made yet.
    var rows: Int? = WitnessDiff.shown
    /// The characters an ask's line holds before it wraps, from the ask's width.
    @State private var columns = 80

    nonisolated static func == (a: WitnessDiff, b: WitnessDiff) -> Bool {
        a.diff == b.diff && a.rows == b.rows
    }

    static let shown = 12
    /// The bytes of line a card pairs to find the words that changed, which it does in the frame
    /// that scrolls it into view: some thirty pairs of lines, and the first run of removed and
    /// added lines that would take it past that goes without, with everything after it.
    static let paired = 6000
    /// More characters than the widest card holds. A line is set no further than this.
    static let widest = 240

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

    /// A line as a card sets it, one row whatever it holds: cut where no card reaches, so a
    /// minified file's line isn't typeset whole to show its start, and with a space for any
    /// character inside it that would break the row and put every edge below it a row out.
    static func row(_ line: ReviewLine) -> ReviewLine {
        let bytes = line.text.utf8
        if bytes.count <= widest, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F || $0 == 9 }) { return line }
        var text = line.text
        if text.utf8.last == 13 { text.unicodeScalars.removeLast() }
        text = String(text.prefix(widest).map { $0.isNewline ? " " : $0 })
        var row = ReviewLine(kind: line.kind, text: text, old: line.old, new: line.new)
        row.noNewline = line.noNewline
        return row
    }

    /// The card as one text, a line a row, and the rows with an edge. A view for each hunk
    /// and each of its pieces cost a card scrolled into view half as much again.
    private static func drawn(_ laid: Laid) -> (text: AttributedString, added: [Range<Int>], deleted: [Range<Int>]) {
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
            if let place = hunk.place { line(WitnessHunk.margin(laid.digits) + aside(place, Ink.faint)) }
            for piece in hunk.pieces {
                switch piece {
                case .lines(let range, _):
                    for index in range {
                        if hunk.lines[index].kind == .added { edge(&added) }
                        if hunk.lines[index].kind == .deleted { edge(&deleted) }
                        line(WitnessHunk.code([Self.row(hunk.lines[index])], words: hunk.words[index].map { [0: $0] } ?? [:], 0..<1, numbered: laid.digits))
                    }
                case .removal(let range):
                    edge(&deleted)
                    let name = WitnessHunk.naming(hunk.lines[range])
                    var removal = WitnessHunk.margin(laid.digits) + aside("\(range.count) lines removed", Ink.deleted)
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
        if laid.more > 0 { line(WitnessHunk.margin(laid.digits) + aside("\(laid.more) more \(laid.more == 1 ? "line" : "lines")", Ink.faint)) }
        return (text, added, deleted)
    }

    var body: some View {
        if rows == nil { whole } else { card }
    }

    private var card: some View {
        let laid = Self.lay(diff, rows: rows)
        let drawn = Self.drawn(laid)
        // As wide as its longest line and in a frame as wide as the card: a line past the
        // card's edge is cut there, where the review, which has the width for it, wraps it.
        return Text(drawn.text)
            .fixedSize()
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.leading, WitnessHunk.inset(laid.digits))
            .font(Type.mono)
            .lineHeight(.exact(points: WitnessHunk.lineHeight))
            .background(alignment: .topLeading) {
                Edges(rows: drawn.added, fill: false).fill(Ink.added)
                Edges(rows: drawn.deleted, fill: false).fill(Ink.deleted)
            }
            .clipped()
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
