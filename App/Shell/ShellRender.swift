import SwiftTerm
import SwiftUI

/// A terminal's buffer as the transcript shows it and Claude reads it: every line from the top of
/// the scrollback to the last one written, the lines the terminal wrapped joined again, so the
/// column wraps them at its own width.
enum ShellRender {
    /// The transcript draws the last this many lines of a block.
    static let shown = 400

    typealias Line = [(character: Character, attribute: Attribute)]

    static func lines(_ terminal: Terminal) -> [Line] {
        numbered(terminal).map(\.line)
    }

    /// The same lines, each with the row it starts on, counted from the terminal's first row with
    /// the ones the scrollback has let go of, so a line keeps its number as the scrollback trims.
    static func numbered(_ terminal: Terminal) -> [(row: Int, line: Line)] {
        var lines: [(row: Int, line: Line)] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1].line += cells(line, in: terminal)
            } else {
                lines.append((row, cells(line, in: terminal)))
            }
            row += 1
        }
        for index in lines.indices {
            while lines[index].line.last?.character == " " { lines[index].line.removeLast() }
        }
        while lines.last?.line.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// The last `shown` lines, as `lines` ends, read up from the end of the buffer so a full
    /// scrollback costs a running block's redraw no more than a short one, and the row the first
    /// of them starts on.
    static func tail(_ terminal: Terminal) -> (lines: [Line], row: Int) {
        let top = terminal.buffer.totalLinesTrimmed
        var row = end(of: terminal)
        var lines: [Line] = []
        var line: Line = []
        while lines.count < shown, row > top, let above = terminal.getScrollInvariantLine(row: row - 1) {
            row -= 1
            line.insert(contentsOf: cells(above, in: terminal), at: 0)
            // A wrapped row goes on the line above it, except at the top, where it starts one.
            guard !above.isWrapped || row == top else { continue }
            while line.last?.character == " " { line.removeLast() }
            if !line.isEmpty || !lines.isEmpty { lines.append(line) }
            line = []
        }
        return (lines.reversed(), row)
    }

    /// The row after the buffer's last, at most a screen below the one on show.
    private static func end(of terminal: Terminal) -> Int {
        var row = terminal.buffer.totalLinesTrimmed + terminal.buffer.yDisp
        while terminal.getScrollInvariantLine(row: row) != nil { row += 1 }
        return row
    }

    /// How many lines start above a row, as `lines` counts them, kept up as output comes: rows
    /// that have scrolled off the screen don't change, so each is read once, and forgotten as the
    /// scrollback lets go of it. A clear of the scrollback, a reset or a resize, which renumber
    /// or rewrite those rows, start the count again.
    struct LineCount {
        /// For each row from `top` that has left the screen, whether a line starts on it.
        private var starts: [Bool] = []
        private var top = 0
        /// The last row counted as it was then.
        private var last: (line: BufferLine, generation: UInt64)?
        private var buffer: ObjectIdentifier?
        private var columns = 0

        mutating func lines(above row: Int, in terminal: Terminal) -> Int {
            let top = terminal.buffer.totalLinesTrimmed
            let counted = self.top + starts.count
            let moved = last.map { terminal.getScrollInvariantLine(row: counted - 1) !== $0.line || $0.line.generation != $0.generation } ?? false
            if buffer != ObjectIdentifier(terminal.buffer) || columns != terminal.cols || top < self.top || top > counted || moved {
                self = LineCount()
                self.top = top
                buffer = ObjectIdentifier(terminal.buffer)
                columns = terminal.cols
            }
            starts.removeFirst(top - self.top)
            self.top = top
            let screen = end(of: terminal) - terminal.rows
            while self.top + starts.count < min(row, screen), let line = terminal.getScrollInvariantLine(row: self.top + starts.count) {
                starts.append(!line.isWrapped)
                last = (line, line.generation)
            }
            // The top row starts a line even when it's the rest of one the scrollback let go of.
            var count = starts.prefix(row - top).dropFirst().count { $0 } + (row > top ? 1 : 0)
            var below = max(self.top + starts.count, top + 1)
            while below < row {
                if terminal.getScrollInvariantLine(row: below)?.isWrapped == false { count += 1 }
                below += 1
            }
            return count
        }
    }

    private static func cells(_ line: BufferLine, in terminal: Terminal) -> Line {
        var cells: Line = []
        for column in 0..<line.count {
            let cell = line[column]
            // The second half of a wide character.
            guard cell.width > 0 else { continue }
            let character = terminal.getCharacter(for: cell)
            cells.append((character == "\0" ? " " : character, cell.attribute))
        }
        return cells
    }

    static func plain(_ lines: [Line]) -> String {
        lines.map(plain).joined(separator: "\n")
    }

    static func plain(_ line: Line) -> String {
        String(line.map(\.character))
    }

    /// In the terminal's colours, a run for each stretch of cells that look the same. The text is
    /// made whole first and only the stretches that don't look like the block's own ink are
    /// dressed after: put together a stretch at a time, 400 lines took a running block's redraw
    /// five milliseconds.
    static func attributed(_ lines: some Collection<Line>) -> AttributedString {
        var plain = ""
        var scalars = 0
        var dressed: [(from: Int, to: Int, look: AttributeContainer)] = []
        for (index, line) in lines.enumerated() {
            if index > 0 {
                plain.append("\n")
                scalars += 1
            }
            var start = line.startIndex
            while start < line.endIndex {
                let attribute = line[start].attribute
                let from = scalars
                var end = start
                while end < line.endIndex, line[end].attribute == attribute {
                    plain.append(line[end].character)
                    scalars += line[end].character.unicodeScalars.count
                    end += 1
                }
                if let look = look(attribute) { dressed.append((from, scalars, look)) }
                start = end
            }
        }
        // Counted in scalars, which a character joining the one before it doesn't change.
        var text = AttributedString(plain)
        var at = text.startIndex
        var offset = 0
        for run in dressed {
            let from = text.unicodeScalars.index(at, offsetBy: run.from - offset)
            let to = text.unicodeScalars.index(from, offsetBy: run.to - run.from)
            text[from..<to].mergeAttributes(run.look)
            at = to
            offset = run.to
        }
        return text
    }

    /// How cells with this attribute differ from the block's ink, or nil when they don't.
    private static func look(_ attribute: Attribute) -> AttributeContainer? {
        let style = attribute.style
        guard colour(attribute.fg) != nil || style.contains(.bold) || style.contains(.dim) || style.contains(.underline) else { return nil }
        var look = AttributeContainer()
        if let colour = colour(attribute.fg) { look.foregroundColor = colour }
        if style.contains(.bold) { look.inlinePresentationIntent = .stronglyEmphasized }
        if style.contains(.dim) { look.foregroundColor = (colour(attribute.fg) ?? Ink.primary).opacity(0.6) }
        if style.contains(.underline) { look.underlineStyle = .single }
        return look
    }

    /// A terminal's own colours through the palette the old terminal used, muted for the glass;
    /// the default is left to the block's ink.
    static func colour(_ colour: Attribute.Color) -> SwiftUI.Color? {
        switch colour {
        case .defaultColor, .defaultInvertedColor:
            return nil
        case .trueColor(let red, let green, let blue):
            return SwiftUI.Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
        case .ansi256(let code):
            if code < 16 { return rgb(TerminalPalette.rgb[Int(code)]) }
            if code >= 232 {
                let level = (Double(code) - 232) * 10 + 8
                return SwiftUI.Color(white: level / 255)
            }
            let cube = Int(code) - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return SwiftUI.Color(red: Double(steps[cube / 36]) / 255, green: Double(steps[cube / 6 % 6]) / 255, blue: Double(steps[cube % 6]) / 255)
        }
    }

    private static func rgb(_ value: Int) -> SwiftUI.Color {
        SwiftUI.Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    /// A terminal that has read what a block printed, for a block from an earlier launch.
    static func replay(_ output: Data, columns: Int = ShellBlock.columns) -> Terminal {
        let terminal = Terminal(delegate: Quiet.shared, options: TerminalOptions(cols: columns, rows: ShellBlock.rows, scrollback: ShellBlock.scrollback))
        terminal.feed(byteArray: [UInt8](output))
        return terminal
    }

    /// Nobody to answer a replayed terminal's questions.
    private final class Quiet: TerminalDelegate {
        nonisolated(unsafe) static let shared = Quiet()
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }
}
