import SwiftUI

/// The brief's palette. Every surface and ink in the app comes from here.
enum Surface {
    static let composer = Color.white.opacity(0.12)
    static let composerEdge = Color.white.opacity(0.12)
    /// The composer with something held over it to drop.
    static let dropTarget = Color.white.opacity(0.16)
    static let userMessage = Color.white.opacity(0.07)
    static let card = Color.white.opacity(0.05)
    static let drawer = Color.white.opacity(0.06)
    static let hover = Color.white.opacity(0.07)
    static let selected = Color.white.opacity(0.10)
}

enum Ink {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.30)
    static let added = Color(red: 0.55, green: 0.85, blue: 0.60)
    static let deleted = Color(red: 0.95, green: 0.55, blue: 0.55)
    /// Claude's orange, #D97757, on Claude's mark beside the model's name and nowhere else.
    static let claude = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
}

enum Type {
    static let body = Font.system(size: 14)
    static let secondary = Font.system(size: 12.5)
    static let mono = Font.system(size: 12.5, design: .monospaced)
}

enum Motion {
    static let move = Animation.spring(duration: 0.28, bounce: 0.12)
    static let fade = Animation.easeOut(duration: 0.18)
    /// kullanym-notch's glide, for things that travel a long way: the composer leaving the
    /// middle of the window, the usage card.
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// kullanym-notch's reading spring: a ring that snaps to a new value reads as a glitch.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)
}

enum Glass {
    /// The black layer over the material: how light or dark the glass is.
    static let key = "glass"
    static let defaultTint = 0.30
    static let range = 0.15...0.60
    /// How far the material fades so the desktop shows through sharp, 0 to 1.
    static let transparencyKey = "transparency"
    static let defaultTransparency = 0.0
    /// The least of the material the window keeps, at full transparency.
    static let clearest = 0.25

    static func materialOpacity(_ transparency: Double) -> Double {
        1 - min(max(transparency, 0), 1) * (1 - clearest)
    }
}
