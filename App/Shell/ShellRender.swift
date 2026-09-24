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
        var lines: [Line] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            var cells: Line = []
            for column in 0..<line.count {
                let cell = line[column]
                // The second half of a wide character.
                guard cell.width > 0 else { continue }
                let character = terminal.getCharacter(for: cell)
                cells.append((character == "\0" ? " " : character, cell.attribute))
            }
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += cells
            } else {
                lines.append(cells)
            }
            row += 1
        }
        lines = lines.map { line in
            var line = line
            while line.last?.character == " " { line.removeLast() }
            return line
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    static func plain(_ lines: [Line]) -> String {
        lines.map { String($0.map(\.character)) }.joined(separator: "\n")
    }

    /// In the terminal's colours, a run for each stretch of cells that look the same.
    static func attributed(_ lines: some Collection<Line>) -> AttributedString {
        var text = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { text.append(AttributedString("\n")) }
            var start = line.startIndex
            while start < line.endIndex {
                let attribute = line[start].attribute
                var end = start
                while end < line.endIndex, line[end].attribute == attribute { end += 1 }
                var run = AttributedString(String(line[start..<end].map(\.character)))
                if let colour = colour(attribute.fg) { run.foregroundColor = colour }
                if attribute.style.contains(.bold) { run.inlinePresentationIntent = .stronglyEmphasized }
                if attribute.style.contains(.dim) { run.foregroundColor = (colour(attribute.fg) ?? Ink.primary).opacity(0.6) }
                if attribute.style.contains(.underline) { run.underlineStyle = .single }
                text.append(run)
                start = end
            }
        }
        return text
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
