import SwiftUI

/// The window's title made visible, level with the traffic lights: the thread's title, or with
/// no thread begun the project's name, and the project and branch on its hover. Clicking it opens
/// the command center, as ⌘K does. While there's an update, its circle hangs
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
                // A draft's "New thread" says nothing the project's name doesn't.
                let titled = model.chat.flatMap { $0.started || $0.title != Chat.untitled ? $0 : nil }
                Text(titled?.title ?? project.name)
                    .foregroundStyle(titled == nil ? Ink.secondary : Ink.primary)
                    .truncationMode(.tail)
                    .modifier(Swap(key: titled.map { "\($0.id) \($0.title)" } ?? project.name))
                .font(Type.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.leading, working ? Self.mark + 6 : 0)
                .frame(height: Self.height)
                .background(glass ? hovering ? Surface.selected : Surface.drawer : .clear, in: .capsule)
                .contentShape(.capsule)
                .matchedGeometryEffect(id: Island.Piece.capsule, in: island, isSource: true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.capsuleFrame = $0 }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(([project.name, model.currentBranch.map { $0.ahead > 0 ? "\($0.branch) ↑\($0.ahead)" : $0.branch }].compactMap(\.self).joined(separator: " · "))
                + "\nCommand center (\(model.shortcuts.label(.commandCenter)))")
            // While the thread works, its mark at the capsule's left end, which opens its heads.
            .overlay(alignment: .leading) {
                ZStack {
                    if working, let conversation = model.currentConversation {
                        mark(conversation)
                    }
                }
                .animation(Motion.fade, value: model.chat?.id)
            }
            .animation(Motion.fade, value: model.keyboardSide)
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

    private func mark(_ conversation: Conversation) -> some View {
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
        .help("What each head is doing (\(model.shortcuts.label(.heads)))")
        // An agent that reports no heads still shows it's working, with nothing to open.
        .allowsHitTesting(model.showsHeads(model.chat))
        .id(conversation.chat.id)
        // In once the capsule has made room for it, never over the title's first letters.
        .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.22)), removal: .opacity.animation(.easeOut(duration: 0.1))))
    }
}

/// Words that change in place: the old ones go at once and the new come up in their place as the
/// glass takes their width, so two titles are never drawn over each other and the glass is never
/// empty. One view whatever the words, so none is left
/// behind half faded when the thread changes again, or in the frame the capsule comes back in.
struct Swap: ViewModifier {
    let key: String

    func body(content: Content) -> some View {
        // The old words go at once: an animation in the same transaction would otherwise blend
        // the two texts into each other.
        content.contentTransition(.identity).keyframeAnimator(initialValue: 1.0, trigger: key) { words, opacity in
            words.opacity(opacity)
        } keyframes: { _ in
            MoveKeyframe(0)
            CubicKeyframe(1, duration: 0.12)
        }
    }
}
