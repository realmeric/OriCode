import SwiftUI

/// The window's title made visible: project · branch · thread, level with the traffic lights.
/// Clicking it opens the command center, as ⌘K does.
struct TitleCapsule: View {
    @Environment(AppModel.self) private var model
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
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
