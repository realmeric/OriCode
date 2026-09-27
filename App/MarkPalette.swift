import SwiftUI

/// What a thread on an agent heats through: its base, then ember, at the rail's hot end and on its
/// lamps, and white-hot, what a spark is born as. The effort rail, its sparks and the picker's head
/// draw in these. As sRGB components, so SwiftUI and Core Animation draw the same colour.
struct AgentInk: Equatable {
    let base: SIMD3<Double>
    let ember: SIMD3<Double>
    let whiteHot: SIMD3<Double>

    /// Claude's orange, #D97757, and the ember and white-hot the rail was first drawn in.
    static let claude = AgentInk(base: [0xD9 / 255, 0x77 / 255, 0x57 / 255], ember: [1, 0.86, 0.78], whiteHot: [1, 0.97, 0.92])
    /// An agent whose maker draws its mark in white. White can't pale any further, so its heat runs
    /// from a cool silver, #8CA1B7, through ice, #EBF3FC, to white.
    static let silver = AgentInk(base: [0x8C / 255, 0xA1 / 255, 0xB7 / 255], ember: [0xEB / 255, 0xF3 / 255, 0xFC / 255], whiteHot: [1, 1, 1])

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

/// Each agent in its maker's colour, the one the maker draws its mark in on a dark background.
/// Two agents may share a colour, as their makers do; the mark tells them apart.
enum MarkPalette {
    /// Each maker's colour, from its brand page or its own site's logo. A maker whose mark is black
    /// or white draws in white, as its own app does in dark mode. An agent missing here is white.
    static let makers: [String: UInt32] = [
        ProviderInfo.claudeID: 0xD97757,
        "codex": 0xFFFFFF, "cursor": 0xFFFFFF, "opencode": 0xFFFFFF, "grok": 0xFFFFFF, "devin": 0xFFFFFF, "zai": 0xFFFFFF,
        "commandcode": 0xFFFFFF,
        "copilot": 0x8534F3,
        // Pi's mark is three blocks, coral, blue and yellow; coral is its top.
        "pi": 0xF09082,
        "antigravity": 0x3186FF,
        "deepseek": 0x4D6BFE,
        // Volt, the glyph OpenRouter offers for dark backgrounds, as it is: its brand page asks
        // that its marks not be recoloured.
        "openrouter": 0xC8FF00,
        "meta": 0x0064E0,
    ]

    /// Ember and white-hot for each maker with a colour: its hue at the lightness and chroma of
    /// Claude's. Volt is lighter than Claude's ember already, so its own are paler still.
    private static let heat: [String: (ember: UInt32, whiteHot: UInt32)] = [
        "copilot": (0xE5DEFE, 0xF8F7FF),
        "pi": (0xFFDAD3, 0xFFF6F4),
        "antigravity": (0xD3E5FF, 0xF4F8FE),
        "deepseek": (0xD9E3FF, 0xF6F8FE),
        "openrouter": (0xE8FDC2, 0xF9FEF0),
        "meta": (0xD4E5FF, 0xF4F8FE),
    ]

    static func ink(for agent: String) -> AgentInk {
        if agent == ProviderInfo.claudeID { return .claude }
        guard let mark = makers[agent], let heat = heat[agent] else { return .silver }
        return AgentInk(base: rgb(mark), ember: rgb(heat.ember), whiteHot: rgb(heat.whiteHot))
    }

    /// The agent's logo, its dot while it works and a worker's ray.
    static func color(for agent: String) -> Color {
        Color(rgb(makers[agent] ?? 0xFFFFFF))
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
