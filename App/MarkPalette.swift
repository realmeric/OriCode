import SwiftUI

/// Each agent's colour, drawn on a thread's mark and nowhere else: the dot while the head works on
/// it, and each worker's ray while it's lit. Claude's is Claude's orange in every palette. Three
/// candidates stay in the app until Meriç picks one, behind a hidden default:
/// `defaults write <bundle id> markPalette brand|soft|quiet`.
enum MarkPalette: String, CaseIterable {
    /// Each maker's own colour as its mark has it on a dark background.
    case brand
    /// The same hues at one lightness and chroma, a little lighter than Claude's orange, since
    /// blues and purples read darker on the glass than orange does.
    case soft
    /// White tinted toward each maker's hue, so Claude's orange is the one colour on the mark.
    case quiet

    static let key = "markPalette"
    static let standard = MarkPalette.soft

    /// Brand, soft and quiet, as sRGB hex. An agent whose maker's mark is black or white is white
    /// in all three, and Codex takes its app icon's blue rather than OpenAI's black; an agent
    /// missing here is white too.
    private static let table: [String: (brand: UInt32, soft: UInt32, quiet: UInt32)] = [
        "codex": (0x7A9DFF, 0x87A7FD, 0xD2DEFA),
        "copilot": (0x8534F3, 0xB299F3, 0xE0D9F6),
        "devin": (0x21C19A, 0x39C59F, 0xC5E7DA),
        "antigravity": (0x3186FF, 0x76ACFC, 0xCEDFF9),
        "zai": (0x1F63EC, 0x7DAAFD, 0xD0DFF9),
        "deepseek": (0x4D6BFE, 0x8AA6FD, 0xD3DDFA),
        "openrouter": (0xC8FF00, 0x9AB857, 0xD8E3C6),
        "meta": (0x0668E1, 0x77ACFC, 0xCEDFF9),
        "commandcode": (0x8C4EDD, 0xB797F1, 0xE2D9F5),
    ]

    func color(for agent: String) -> Color {
        if agent == ProviderInfo.claudeID { return Ink.claude }
        guard let entry = Self.table[agent] else { return .white }
        let hex = switch self {
        case .brand: entry.brand
        case .soft: entry.soft
        case .quiet: entry.quiet
        }
        return Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// The colour of each lit ray, from the agent that holds it.
    func colors(_ agents: [Int: String]) -> [Int: Color] {
        agents.mapValues(color(for:))
    }

    /// The rays one head holds, in its agent's colour.
    @MainActor
    func colors(of head: Head) -> [Int: Color] {
        let color = color(for: head.agent)
        return Dictionary(uniqueKeysWithValues: head.rays.map { ($0, color) })
    }
}
