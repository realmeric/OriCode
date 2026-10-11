import AppKit
import SwiftUI

/// How Witness draws a hunk: one number column, the code in ink with no band behind it, an
/// edge beside what changed, the old line above a replaced one, and a long removal as one row.
enum WitnessHunk {
    /// The edge beside a changed line. If it reads too faint over a wallpaper, this goes to 5
    /// before anything else changes.
    static let edge: CGFloat = 3
    static let lineHeight: CGFloat = 17
    /// A removal of this many lines or fewer is drawn; a longer one is a row until it's opened.
    static let shortRemoval = 6
    /// Past this many lines a hunk shows its start until asked, as Legacy's does.
    static let long = 400
    static let shownOfLong = 200
    /// Left of the numbers, where the edge is, and between the numbers and the code.
    static let lead: CGFloat = 14
    static let gap: CGFloat = 14
    static let advance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    static func numbers(_ digits: Int) -> CGFloat { lead + (CGFloat(digits) * advance).rounded(.up) }
    /// Where code starts, from the hunk's left edge: the same for every hunk on a page.
    static func codeX(_ digits: Int) -> CGFloat { numbers(digits) + gap }

    /// What a hunk is laid out as: lines that each fit the width, drawn as one text; a line
    /// that may wrap, on its own so the numbers after it stay beside their lines; and a long
    /// removal folded to a row.
    enum Piece: Hashable {
        case lines(Range<Int>, wraps: Bool)
        case removal(Range<Int>)
    }

    /// The removals long enough to fold: in a run of removed lines, the ones after its last
    /// line that was edited into a new one, when there are more than six. An old line whose
    /// words went is always drawn, above the line it became.
    static func removals(in lines: [ReviewLine], words: [Int: [Range<Int>]]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .deleted else {
                index += 1
                continue
            }
            let end = lines[index...].firstIndex { $0.kind != .deleted } ?? lines.count
            let start = (index..<end).last { words[$0] != nil }.map { $0 + 1 } ?? index
            if end - start > shortRemoval { found.append(start..<end) }
            index = end
        }
        return found
    }

    static func pieces(_ lines: [ReviewLine], words: [Int: [Range<Int>]], opened: Bool, whole: Bool, columns: Int) -> [Piece] {
        let shown = whole || lines.count <= long ? lines.count : shownOfLong
        let folded = opened ? [:] : Dictionary(removals(in: lines, words: words).map { ($0.lowerBound, $0) }) { first, _ in first }
        var pieces: [Piece] = []
        var block: Range<Int>?
        func flush() {
            if let block { pieces.append(.lines(block, wraps: false)) }
            block = nil
        }
        var index = 0
        while index < shown {
            if let range = folded[index] {
                flush()
                // Whole, past where the hunk is cut too: the row says how many lines went.
                pieces.append(.removal(range))
                index = range.upperBound
            } else if fits(lines[index], columns: columns) {
                block = (block?.lowerBound ?? index)..<(index + 1)
                index += 1
            } else {
                flush()
                pieces.append(.lines(index..<(index + 1), wraps: true))
                index += 1
            }
        }
        flush()
        return pieces
    }

    /// Whether a line is sure to stay on one line as it's drawn: characters the code's font
    /// draws one advance wide, and no more of them than the width holds. Anything else, an
    /// emoji or a Chinese character, comes from another font and is taken to wrap.
    static func fits(_ line: ReviewLine, columns: Int) -> Bool {
        fits(drawn(line.text), columns: line.noNewline ? columns - noNewlineColumns : columns)
    }

    static func fits(_ text: String, columns: Int) -> Bool {
        let bytes = text.utf8
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) { return bytes.count <= columns }
        let scalars = text.unicodeScalars
        return scalars.count <= columns && scalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F || narrow.contains($0) }
    }

    /// The letters past ASCII the code's font has at its one advance: accented Latin, Greek
    /// and Cyrillic. A tab-indented file or one with ş in a string is as cheap to draw as any.
    static let narrow: Set<Unicode.Scalar> = {
        let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular) as CTFont
        let units = (0xA0...0x4FF).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        var advances = [CGSize](repeating: .zero, count: units.count)
        // False when some have no glyph; those stay 0 and are left out below.
        _ = CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var found = Set<Unicode.Scalar>()
        for (index, unit) in units.enumerated() where glyphs[index] != 0 && abs(advances[index].width - advance) < 0.01 {
            if let scalar = Unicode.Scalar(unit) { found.insert(scalar) }
        }
        return found
    }()

    /// A tab is drawn as spaces to the next column that four divides.
    static let tab = 4
    /// The room the mark after a file's last line without a newline is given.
    static let noNewlineColumns = 4

    /// A line as it's drawn: without the \r a CRLF file ends its lines in, which would break
    /// the line again, and with each tab as spaces, so every character is one advance wide.
    static func drawn(_ text: String) -> String {
        var text = text
        if text.utf8.last == 13 { text.unicodeScalars.removeLast() }
        guard text.utf8.contains(9) else { return text }
        var drawn = ""
        var column = 0
        for character in text {
            let width = character == "\t" ? tab - column % tab : 1
            if character == "\t" { drawn += String(repeating: " ", count: width) } else { drawn.append(character) }
            column += width
        }
        return drawn
    }

    /// Where a line's character ranges fall once its tabs are spaces.
    static func drawn(_ ranges: [Range<Int>], of text: String) -> [Range<Int>] {
        guard text.utf8.contains(9) else { return ranges }
        var at = [0]
        for character in text {
            at.append(at[at.count - 1] + (character == "\t" ? tab - at[at.count - 1] % tab : 1))
        }
        return ranges.filter { $0.upperBound < at.count }.map { at[$0.lowerBound]..<at[$0.upperBound] }
    }

    /// A line's ink. Unchanged code is secondary, and so is an added line seen at an earlier
    /// mark or moved here. A removed line is red however quiet it is, since it isn't in the
    /// file and must never read as code that is.
    static func ink(_ line: ReviewLine) -> Color {
        switch line.kind {
        case .context: Ink.secondary
        case .added: line.seen || line.moved ? Ink.secondary : Ink.primary
        case .deleted: line.seen || line.moved ? Ink.deleted.opacity(0.6) : Ink.deleted
        }
    }

    /// A line's number: the change's colour until the change is marked reviewed, and fainter
    /// on a line seen at an earlier mark, which has no edge to say it changed.
    static func numberInk(_ line: ReviewLine, reviewed: Bool) -> Color {
        guard !reviewed, line.kind != .context else { return Ink.secondary }
        let ink = line.kind == .added ? Ink.added : Ink.deleted
        return line.seen ? ink.opacity(0.6) : ink
    }

    /// What a folded removal is named by: its first line that doesn't start a comment.
    static func naming(_ lines: ArraySlice<ReviewLine>) -> String {
        let texts = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let comment = { (text: String) in
            ["//", "/*", "*", "<!--", "--", "# ", "#!", "\"\"\""].contains { text.hasPrefix($0) } || text == "#"
        }
        let name = texts.first { !comment($0) } ?? texts.first ?? ""
        return name.count > 72 ? String(name.prefix(71)) + "…" : name
    }

    /// The line O opens a change's file at: the first one it wrote, or where its removal was.
    static func line(of unit: ReviewUnit) -> Int? {
        unit.lines.first { $0.kind == .added }?.new ?? unit.hunk?.newStart
    }
}

/// One change on Witness's page: the hunk, your notes on it, and the keyboard's tint when it's
/// there. A click selects it, a click in its number column marks it, and a right-click offers
/// what the keys do.
struct WitnessUnit: View {
    @Environment(AppModel.self) private var model
    let unit: ReviewUnit
    let digits: Int
    let columns: Int
    /// The labels its file's line, or the quiet line it opened from, has said for it already.
    var said: [String] = []

    var body: some View {
        let review = model.review
        let selected = review.selected == unit.id
        VStack(alignment: .leading, spacing: 0) {
            WitnessLines(
                unit: unit, digits: digits, columns: columns, opened: review.unfolded.contains(unit.id),
                whole: review.expanded.contains(unit.id), said: said)
                .equatable()
            ForEach(review.notes.filter { $0.unit == unit.id }) { note in
                NoteCard(note: note).padding(.top, 6)
            }
            if review.noting == unit.id {
                NoteEditor(unit: unit).padding(.top, 6)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture {
            review.selected = unit.id
            review.focusTick += 1
        }
        .contextMenu { WitnessActions(unit: unit) }
    }
}

/// The hunk's own lines. It reads nothing that moves with the keyboard, so walking the page
/// lays none of it out again.
struct WitnessLines: View, Equatable {
    @Environment(AppModel.self) private var model
    let unit: ReviewUnit
    let digits: Int
    let columns: Int
    let opened: Bool
    let whole: Bool
    let said: [String]

    nonisolated static func == (a: WitnessLines, b: WitnessLines) -> Bool {
        a.digits == b.digits && a.columns == b.columns && a.opened == b.opened && a.whole == b.whole && a.said == b.said && a.unit == b.unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption
            if unit.hunk == nil {
                Text(UnitView.whole(unit.file))
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .padding(.leading, WitnessHunk.codeX(digits))
            } else {
                lines
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        let context = unit.hunk?.context.trimmingCharacters(in: .whitespaces) ?? ""
        let labels = unit.labels.filter { !said.contains($0) }
        if !context.isEmpty || unit.changedSince || !labels.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !context.isEmpty {
                    Text(context).font(Type.mono).foregroundStyle(Ink.faint).lineLimit(1)
                }
                if unit.changedSince {
                    Text("changed since you reviewed it").foregroundStyle(Ink.secondary)
                }
                ForEach(labels, id: \.self) { label in
                    Text(label)
                        .foregroundStyle(UnitView.warning(label) || label.hasSuffix("changed on the way") ? Ink.primary : Ink.secondary)
                        .help(UnitView.warning(label) ? "Worth a closer look: an agent can make a failing test pass by changing what it checks." : "")
                }
            }
            .font(Type.secondary)
            .lineLimit(1)
            .padding(.leading, WitnessHunk.codeX(digits))
            .padding(.trailing, 12)
            .padding(.bottom, 3)
        }
    }

    private var lines: some View {
        let pieces = WitnessHunk.pieces(unit.lines, words: unit.words, opened: opened, whole: whole, columns: columns)
        let cut = !whole && unit.lines.count > WitnessHunk.long
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(pieces, id: \.self) { piece in
                switch piece {
                case .lines(let range, let wraps):
                    block(range, wraps: wraps)
                case .removal(let range):
                    removal(range)
                }
            }
            if cut {
                Button("Show all \(unit.lines.count) lines") {
                    _ = model.review.expanded.insert(unit.id)
                }
                .buttonStyle(.plain)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .padding(.leading, WitnessHunk.codeX(digits))
                .padding(.vertical, 6)
            }
        }
        // The number column is the mark: a click anywhere in it marks the change, or unmarks it.
        .overlay(alignment: .leading) {
            Button {
                model.markByClick(unit)
            } label: {
                Color.clear.frame(width: WitnessHunk.numbers(digits)).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(unit.reviewed ? "Mark not reviewed (Space)" : "Mark reviewed (Space)")
            .accessibilityLabel(unit.reviewed ? "Mark not reviewed" : "Mark reviewed")
        }
    }

    private func block(_ range: Range<Int>, wraps: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(numbers(range))
                .multilineTextAlignment(.trailing)
                .frame(width: WitnessHunk.numbers(digits), alignment: .trailing)
            // Not selectable: a selectable text answers a right-click with its own menu, and the
            // change's menu, which copies it, is the one a right-click is for.
            Text(code(range))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, WitnessHunk.gap)
                .padding(.trailing, 12)
        }
        .font(Type.mono)
        .lineHeight(.exact(points: WitnessHunk.lineHeight))
        .background(alignment: .topLeading) {
            if !unit.reviewed {
                edge(range, .added, fill: wraps)
                edge(range, .deleted, fill: wraps)
                edge(range, .added, moved: true, fill: wraps)
                edge(range, .deleted, moved: true, fill: wraps)
            }
        }
    }

    /// The edge of one kind beside a piece, and no view at all where it has none.
    @ViewBuilder
    private func edge(_ range: Range<Int>, _ kind: ReviewLine.Kind, moved: Bool = false, fill: Bool) -> some View {
        let rows = edges(range, kind, moved: moved)
        if !rows.isEmpty {
            let ink = kind == .added ? Ink.added : Ink.deleted
            Edges(rows: rows, fill: fill).fill(moved ? ink.opacity(0.35) : ink)
        }
    }

    private func removal(_ range: Range<Int>) -> some View {
        Button {
            model.review.selected = unit.id
            model.review.unfolded.insert(unit.id)
            model.review.focusTick += 1
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("\(range.count) lines removed")
                let name = WitnessHunk.naming(unit.lines[range])
                if !name.isEmpty {
                    Text(" · ").foregroundStyle(Ink.secondary)
                    Text(name).font(Type.mono).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.deleted)
            .padding(.leading, WitnessHunk.codeX(digits))
            .padding(.trailing, 12)
            .frame(height: WitnessHunk.lineHeight + 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(alignment: .topLeading) {
            if !unit.reviewed { Edges(rows: [0..<1], fill: true).fill(Ink.deleted) }
        }
        .help("Show the lines (→)")
    }

    /// Which rows of a piece have an edge of a kind, as runs, so neighbours draw as one.
    private func edges(_ range: Range<Int>, _ kind: ReviewLine.Kind, moved: Bool = false) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        for index in range {
            let line = unit.lines[index]
            guard line.kind == kind, line.moved == moved, !line.seen else { continue }
            let row = index - range.lowerBound
            if let last = runs.last, last.upperBound == row {
                runs[runs.count - 1] = last.lowerBound..<(row + 1)
            } else {
                runs.append(row..<(row + 1))
            }
        }
        return runs
    }

    private func numbers(_ range: Range<Int>) -> AttributedString {
        var text = AttributedString()
        for index in range {
            let line = unit.lines[index]
            var part = AttributedString((line.kind == .deleted ? line.old : line.new).map(String.init) ?? " ")
            part.foregroundColor = WitnessHunk.numberInk(line, reviewed: unit.reviewed)
            text.append(part)
            if index != range.upperBound - 1 { text.append(AttributedString("\n")) }
        }
        return text
    }

    private func code(_ range: Range<Int>) -> AttributedString {
        var text = AttributedString()
        for index in range {
            let line = unit.lines[index]
            // An empty line keeps its height as a space.
            let plain = WitnessHunk.drawn(line.text)
            var part = AttributedString(plain.isEmpty ? " " : plain)
            part.foregroundColor = WitnessHunk.ink(line)
            // A line seen at an earlier mark or moved has no wash: its words aren't news.
            if let words = unit.words[index], !line.seen, !line.moved, !plain.isEmpty {
                let wash = (line.kind == .added ? Ink.added : Ink.deleted).opacity(0.25)
                let count = part.characters.count
                for range in WitnessHunk.drawn(words, of: line.text) where range.upperBound <= count {
                    let start = part.characters.index(part.startIndex, offsetBy: range.lowerBound)
                    let end = part.characters.index(part.startIndex, offsetBy: range.upperBound)
                    part[start..<end].backgroundColor = wash
                }
            }
            text.append(part)
            if line.noNewline { text.append(AttributedString(" ⏎̸", attributes: AttributeContainer().foregroundColor(Ink.faint))) }
            if index != range.upperBound - 1 { text.append(AttributedString("\n")) }
        }
        return text
    }
}

/// The edges beside a piece's changed rows: each run one bar, or the piece's whole height for
/// a line that wraps.
private struct Edges: Shape {
    let rows: [Range<Int>]
    let fill: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = (WitnessHunk.lead - WitnessHunk.edge) / 2
        for run in rows {
            let top = CGFloat(run.lowerBound) * WitnessHunk.lineHeight
            let height = fill ? rect.height : CGFloat(run.count) * WitnessHunk.lineHeight
            path.addRect(CGRect(x: x, y: top, width: WitnessHunk.edge, height: height))
        }
        return path
    }
}
