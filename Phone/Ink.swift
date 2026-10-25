import Link
import SwiftUI

/// The Mac's whites, and colour only where it means what it means on the Mac: a project's badge,
/// an agent's mark.
enum Ink {
    static let primary = Color.white.opacity(0.92)
    static let secondary = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.30)
    /// A card, as the Mac's: white at 5%, 7% while it asks, 3.5% done.
    static let card = Color.white.opacity(0.05)
    static let asking = Color.white.opacity(0.07)
    static let red = Color(red: 1, green: 0.42, blue: 0.4)
}

/// ProjectBadge's eight colours and MarkPalette's makers, as the Mac has them (App/ProjectBadge.swift,
/// App/MarkPalette.swift).
enum Palette {
    static let projects: [UInt32] = [0x6F9CF6, 0xA78BFA, 0xF07AB6, 0x3FC4BE, 0xA6CF5B, 0xD8B26E, 0xD57FEA, 0x9AA8C7]
    static let makers: [String: UInt32] = [
        "claude": 0xD97757, "copilot": 0x8534F3, "pi": 0xF09082, "antigravity": 0x3186FF,
        "deepseek": 0x4D6BFE, "openrouter": 0xC8FF00, "meta": 0x0064E0,
    ]

    static func project(_ project: ProjectInfo?) -> Color {
        guard let index = project?.color else { return Ink.secondary }
        return color(projects[index % projects.count])
    }

    /// Every other agent draws in white, as its maker's own app does on dark.
    static func agent(_ id: String) -> Color {
        color(makers[id] ?? 0xFFFFFF)
    }

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// A project's two letters on its colour, or No folder's laptop, as the Mac draws it.
struct Badge: View {
    let project: ProjectInfo?

    var body: some View {
        let color = Palette.project(project)
        Group {
            if let project, project.color != nil {
                Text(project.initials)
            } else {
                Image(systemName: "laptopcomputer")
            }
        }
        .font(.system(size: 10.5, weight: .bold, design: .rounded))
        .foregroundStyle(color)
        .frame(width: 24, height: 17)
        .background(color.opacity(0.18), in: .rect(cornerRadius: 5, style: .continuous))
        .accessibilityLabel(project?.name ?? "")
    }
}

/// A thread's mark: its agents' rays lit while it works, turning, its dot pulsing while it asks,
/// all at rest while the Mac is away.
struct ThreadMark: View {
    let thread: ThreadInfo
    var awake = true

    var body: some View {
        let working = awake && (thread.status == .working || thread.status == .asking)
        Mark(
            lit: working ? thread.rays.mapValues(Palette.agent) : [:],
            turning: working && !thread.rays.isEmpty,
            asking: awake && thread.status == .asking,
            dot: working ? Palette.agent(thread.agent) : .white,
            dotOpacity: working ? 0.92 : 0.28,
            restingOpacity: 0.28)
    }
}
