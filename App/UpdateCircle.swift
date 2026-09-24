import SwiftUI

/// Right of the title capsule, only while there's an update: a circle of the capsule's own tint
/// with the update arrow in it. It fills from the bottom as the download goes and turns into a
/// restart arrow once the update is ready; each click moves it on.
struct UpdateCircle: View {
    @Environment(Updates.self) private var updates
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    static let side: CGFloat = 24

    var body: some View {
        Button {
            updates.proceed()
        } label: {
            UpdateFace(phase: updates.phase, hovering: hovering && clickable)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .disabled(!clickable)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var clickable: Bool {
        updates.phase == .available || updates.phase == .ready
    }

    private var help: String {
        let name = "OriCode \(updates.version)"
        switch updates.phase {
        case .idle:
            return ""
        case .available:
            let notes = updates.notes.isEmpty ? "" : "\n\n" + updates.notes
            return "\(name) is out. Click to download it.\(notes)"
        case .downloading(let done):
            return done < 1 ? "Downloading \(name): \(Int(done * 100))%" : "Unpacking \(name)…"
        case .ready:
            let working = model.conversations.values.contains { $0.running }
            return "Click to restart into \(name)." + (working ? " A thread is working, and restarting stops it." : "")
        }
    }
}

/// The drawing alone, apart from Sparkle, so it renders on its own: the arrow light on the tint
/// where the circle is empty, and dark on white where the level has risen over it.
struct UpdateFace: View {
    let phase: Updates.Phase
    let hovering: Bool

    private let rim: CGFloat = 2

    var body: some View {
        let side = UpdateCircle.side
        let inner = side - rim * 2
        let level: Double = switch phase {
        case .downloading(let done): done
        case .ready: 1
        case .idle, .available: 0
        }
        let symbol = phase == .ready ? "arrow.clockwise" : "arrow.down"
        ZStack {
            Circle().fill(hovering ? Surface.selected : Surface.drawer)
            icon(symbol).foregroundStyle(Ink.primary)
            ZStack {
                Rectangle().fill(Ink.primary)
                icon(symbol).foregroundStyle(Color.black.opacity(0.85))
            }
            .frame(width: inner, height: inner)
            .mask(alignment: .bottom) {
                // A sliver at least once it's going, so the first percent shows.
                Rectangle().frame(height: level > 0 ? max(1.5, inner * level) : 0)
            }
            .clipShape(.circle)
        }
        .frame(width: side, height: side)
        .animation(Motion.reading, value: level)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 11, weight: .semibold))
    }
}
