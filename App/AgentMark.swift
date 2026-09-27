import AppKit
import SwiftUI

/// An agent's mark beside its models, in the agent's colour: its maker's logo, a template image
/// in the asset catalog named by the agent's id, from the maker's own site or press kit, or Simple
/// Icons' drawing where the maker has none to take. An agent with no logo gets its initial.
struct AgentMark: View {
    let agent: String

    var body: some View {
        Group {
            if Self.hasLogo(agent) {
                Image(agent).resizable()
            } else {
                Image(nsImage: Self.letter(agent.prefix(1).uppercased())).resizable()
            }
        }
        .scaledToFit()
        .foregroundStyle(MarkPalette.color(for: agent))
        .accessibilityHidden(true)
    }

    private static var logos: [String: Bool] = [:]

    static func hasLogo(_ agent: String) -> Bool {
        if let known = logos[agent] { return known }
        let found = NSImage(named: agent) != nil
        logos[agent] = found
        return found
    }

    private static func letter(_ text: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)])
            let size = string.size()
            string.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }
}
