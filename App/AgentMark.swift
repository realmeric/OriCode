import AppKit
import SwiftUI

/// An agent's mark beside its models: Claude's own in its orange, and every other agent's in
/// white, as a template image OriCode draws itself rather than its maker's logo: an SF Symbol
/// where one fits the agent, and otherwise its initial in the system font.
struct AgentMark: View {
    let agent: String

    var body: some View {
        if agent == ProviderInfo.claudeID {
            ClaudeMark()
        } else {
            Image(nsImage: Self.glyph(agent))
                .resizable()
                .scaledToFit()
                .foregroundStyle(Ink.primary)
                .accessibilityHidden(true)
        }
    }

    /// Cursor's pointer, Command Code's ⌘ and Meta's loop.
    private static let symbols = ["cursor": "cursorarrow", "commandcode": "command", "meta": "infinity"]
    /// Pi's name is its letter.
    private static let initials = ["pi": "π"]
    private static var drawn: [String: NSImage] = [:]

    static func glyph(_ agent: String) -> NSImage {
        if let image = drawn[agent] { return image }
        let image = symbols[agent].flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            ?? letter(initials[agent] ?? agent.prefix(1).uppercased())
        image.isTemplate = true
        drawn[agent] = image
        return image
    }

    private static func letter(_ text: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            let size = string.size()
            string.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
    }
}
