import SwiftUI

/// An agent's colour and the two it pales toward as it heats: ember, at the rail's hot end and on
/// its lamps, and white-hot, what a spark is born as. A thread on the agent draws its logo, its
/// mark's dot and rays, the effort rail and the picker's head in these. As sRGB components, so
/// SwiftUI and Core Animation draw the same colour.
struct AgentInk: Equatable {
    let base: SIMD3<Double>
    let ember: SIMD3<Double>
    let whiteHot: SIMD3<Double>

    /// Claude's orange, #D97757, and the ember and white-hot the rail was first drawn in.
    static let claude = AgentInk(base: [0xD9 / 255, 0x77 / 255, 0x57 / 255], ember: [1, 0.86, 0.78], whiteHot: [1, 0.97, 0.92])
    static let white = AgentInk(base: [1, 1, 1], ember: [1, 1, 1], whiteHot: [1, 1, 1])

    var color: Color { Color(base) }
    var emberColor: Color { Color(ember) }
    var whiteHotColor: Color { Color(whiteHot) }
}

extension Color {
    init(_ rgb: SIMD3<Double>) {
        self.init(red: rgb.x, green: rgb.y, blue: rgb.z)
    }
}

extension CGColor {
    static func of(_ rgb: SIMD3<Double>, alpha: CGFloat = 1) -> CGColor {
        CGColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: alpha)
    }
}

/// Each agent's colour, one apart from every other on the glass. Claude keeps its orange; each
/// other agent starts from its maker's brand and takes the nearest free place on OKLCH's hue
/// circle, 14 places about 26° apart, at a lightness between 0.68 and 0.86 where its hue reads
/// best; a maker whose mark is black or white gets a place no other maker here owns. Ember and
/// white-hot are the agent's hue at the lightness and chroma of Claude's.
enum MarkPalette {
    /// Base, ember and white-hot, as sRGB hex. An agent missing here is white.
    private static let table: [String: (base: UInt32, ember: UInt32, whiteHot: UInt32)] = [
        "grok": (0xEE6478, 0xFED9DB, 0xFFF6F6),
        "cursor": (0xFEA845, 0xFADEC2, 0xFFF7EF),
        "antigravity": (0xF1C530, 0xEFE3C0, 0xFDF8EB),
        "openrouter": (0xC3D842, 0xE1E8C4, 0xF7FAED),
        "opencode": (0x6ED26A, 0xD1ECCF, 0xF1FCF0),
        "devin": (0x01C89B, 0xC5EEDE, 0xEDFCF6),
        "zai": (0x4AEBEA, 0xBFEEED, 0xEBFCFC),
        "codex": (0x00BAE1, 0xC1ECFA, 0xEEFBFF),
        "meta": (0x299FF4, 0xCDE7FF, 0xF3F9FF),
        "deepseek": (0x738EFF, 0xD9E3FF, 0xF6F8FE),
        "copilot": (0xAC82FF, 0xE6DEFF, 0xF9F7FF),
        "commandcode": (0xD67CE1, 0xF4D9F6, 0xFEF5FF),
        "pi": (0xEF80BA, 0xFDD7E9, 0xFFF5F9),
    ]

    static func ink(for agent: String) -> AgentInk {
        if agent == ProviderInfo.claudeID { return .claude }
        guard let entry = table[agent] else { return .white }
        return AgentInk(base: rgb(entry.base), ember: rgb(entry.ember), whiteHot: rgb(entry.whiteHot))
    }

    static func color(for agent: String) -> Color {
        ink(for: agent).color
    }

    /// The colour of each lit ray, from the agent that holds it.
    static func colors(_ agents: [Int: String]) -> [Int: Color] {
        agents.mapValues(color(for:))
    }

    /// The rays one head holds, in its agent's colour.
    @MainActor
    static func colors(of head: Head) -> [Int: Color] {
        let color = color(for: head.agent)
        return Dictionary(uniqueKeysWithValues: head.rays.map { ($0, color) })
    }

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        [Double(hex >> 16 & 0xFF) / 255, Double(hex >> 8 & 0xFF) / 255, Double(hex & 0xFF) / 255]
    }
}
