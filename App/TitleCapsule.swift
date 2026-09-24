import SwiftUI

/// The window's title made visible: project · branch · thread, level with the traffic lights.
/// Clicking it opens the command center, as ⌘K does. While there's an update, its circle hangs
/// off the pill's right end, however wide the pill is, without moving the pill.
struct TitleCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    @State private var hovering = false

    var body: some View {
        if let project = model.project {
            Button {
                model.toggleCommandCenter()
            } label: {
                HStack(spacing: 6) {
                    Text(project.name)
                        .foregroundStyle(Ink.secondary)
                    if let info = model.currentBranch {
                        Text("·").foregroundStyle(Ink.faint)
                        Text(info.branch)
                            .font(Type.mono)
                            .foregroundStyle(Ink.secondary)
                        if info.ahead > 0 {
                            Text("↑\(info.ahead)")
                                .font(Type.mono)
                                .foregroundStyle(Ink.faint)
                        }
                    }
                    if let chat = model.chat {
                        Text("·").foregroundStyle(Ink.faint)
                        Text(chat.title)
                            .foregroundStyle(Ink.primary)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                }
                .font(Type.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(hovering ? Surface.selected : Surface.drawer, in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Command center (⌘K)")
            .overlay(alignment: .trailing) {
                if updates.phase != .idle {
                    UpdateCircle()
                        .offset(x: UpdateCircle.side + 6)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(Motion.move, value: updates.phase != .idle)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
        } else if updates.phase != .idle {
            UpdateCircle()
        }
    }
}
