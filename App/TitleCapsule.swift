import SwiftUI

/// The window's title made visible: project · branch · thread, level with the traffic lights.
/// Clicking it opens the command center, as ⌘K does. While there's an update, its circle hangs
/// off the pill's right end, however wide the pill is, without moving the pill. Its glass is the
/// island's, which the surfaces grow out of.
struct TitleCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    let island: Namespace.ID
    @Binding var hovering: Bool
    /// Its own tint, for when the island's glass isn't there to be it: with Reduce Motion.
    let glass: Bool

    static let height: CGFloat = 24
    /// The thread's mark, the size the drawer's rows draw it.
    static let mark: CGFloat = 14

    var body: some View {
        if let project = model.project {
            let working = model.currentConversation?.working == true
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
                .padding(.leading, working ? Self.mark + 6 : 0)
                .frame(height: Self.height)
                .background(glass ? hovering ? Surface.selected : Surface.drawer : .clear, in: .capsule)
                .contentShape(.capsule)
                .matchedGeometryEffect(id: Island.Piece.capsule, in: island, isSource: true)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Command center (⌘K)")
            // While the thread works, its mark at the capsule's left end, which opens its heads.
            .overlay(alignment: .leading) {
                if working, let conversation = model.currentConversation {
                    Button {
                        model.toggleHeads()
                    } label: {
                        ThreadMark(conversation: conversation)
                            .frame(width: Self.mark, height: Self.mark)
                            .matchedGeometryEffect(id: HeadsSurface.mark, in: island)
                            .padding(.leading, 10)
                            .frame(height: Self.height)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("What each head is doing (⌘I)")
                    .transition(.opacity)
                }
            }
            .animation(Motion.move, value: working)
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
