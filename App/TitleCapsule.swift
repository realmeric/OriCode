import SwiftUI

/// The window's title made visible: project · branch · thread, level with the traffic lights.
struct TitleCapsule: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let project = model.project {
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
            .background(Surface.drawer, in: .capsule)
            .frame(maxWidth: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
