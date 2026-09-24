import SwiftUI

/// The title capsule and what it opens into. ⌘K's command center, ⌘P's file finder and ⌘⇧D's
/// review each stretch down out of the capsule, the way the Dynamic Island grows into what it's
/// showing, and fold back up into it as they go: one at a time, in the capsule's lane, with its
/// top where the capsule's is. The glass is one piece that follows whichever of them is up. With
/// Reduce Motion each has glass of its own, and they fade in and out instead.
struct Island: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var island
    @State private var capsuleHovered = false

    enum Piece: Hashable {
        case capsule, command, files, review
    }

    /// Where the capsule's top sits in the toolbar's row, and every surface's with it.
    static let top = (TitleBar.height - TitleCapsule.height) / 2
    /// The lane's margin on either side, clear of the traffic lights and the sidebar button on the
    /// left and the review's button on the right.
    static let side: CGFloat = 130
    static let corner: CGFloat = 14

    var body: some View {
        GeometryReader { area in
            let shown = shown
            ZStack(alignment: .top) {
                if reduceMotion {
                    if shown != .capsule {
                        piece(shown, room: area.size)
                    }
                } else {
                    // A surface is seen only through the glass as it grows and shrinks, so none of
                    // it spills past the glass on the way.
                    ZStack(alignment: .top) {
                        if model.project != nil || shown != .capsule {
                            glass(open: shown != .capsule)
                                .matchedGeometryEffect(id: shown, in: island, isSource: false)
                                .transition(.opacity)
                        }
                        if shown != .capsule {
                            piece(shown, room: area.size)
                        }
                    }
                    .mask(alignment: .top) {
                        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
                            .matchedGeometryEffect(id: shown, in: island, isSource: false)
                    }
                }
                // Outside the mask, which would cut off the update circle hanging off its end.
                if shown == .capsule {
                    piece(.capsule, room: area.size)
                }
            }
            .padding(.top, Self.top)
            .frame(width: area.size.width)
        }
    }

    private var shown: Piece {
        if model.commandCenterShown { return .command }
        if model.fileFinderShown { return .files }
        if model.reviewShown { return .review }
        return .capsule
    }

    @ViewBuilder
    private func piece(_ piece: Piece, room: CGSize) -> some View {
        switch piece {
        case .capsule:
            TitleCapsule(island: island, hovering: $capsuleHovered, glass: reduceMotion)
                .transition(arrival)
        case .command:
            CommandCenter()
                .frame(width: min(CommandCenter.width, room.width))
                .surface(.command, in: island, glass: reduceMotion)
                .transition(arrival)
        case .files:
            FileFinder()
                .frame(width: min(FileFinder.width, room.width))
                .surface(.files, in: island, glass: reduceMotion)
                .transition(arrival)
        case .review:
            ReviewPanel()
                .frame(width: min(ReviewPanel.width, room.width), height: reviewHeight(room))
                .surface(.review, in: island, glass: reduceMotion)
                .transition(arrival)
        }
    }

    /// Down to 12pt above the composer, however tall it has grown; in a thread with nothing in it
    /// yet, whose composer waits in the middle of the window, the whole height.
    private func reviewHeight(_ room: CGSize) -> CGFloat {
        let low = !(model.currentConversation?.items.isEmpty ?? true)
        let bottom = low ? model.composerTop - 12 : room.height - 20
        return max(160, bottom - Self.top)
    }

    /// What a piece shows comes in once the glass is on its way, and goes before the glass does.
    private var arrival: AnyTransition {
        reduceMotion
            ? .opacity.animation(Motion.fade)
            : .asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.08)), removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    /// The capsule's tint, and a surface's material under it; a capsule 24pt tall draws the
    /// surface's corners as its round ends.
    private func glass(open: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        return shape
            .fill(.ultraThinMaterial)
            .opacity(open ? 1 : 0)
            .background(open ? Surface.drawer : capsuleHovered ? Surface.selected : Surface.drawer, in: shape)
    }
}

extension View {
    /// A surface in the island: the frame the glass follows, or with Reduce Motion, its own glass.
    func surface(_ piece: Island.Piece, in island: Namespace.ID, glass: Bool) -> some View {
        matchedGeometryEffect(id: piece, in: island, isSource: true)
            .background {
                if glass {
                    let shape = RoundedRectangle(cornerRadius: Island.corner, style: .continuous)
                    shape.fill(.ultraThinMaterial).background(Surface.drawer, in: shape)
                }
            }
    }
}

extension AppModel {
    /// The capsule opens into one surface at a time, so whatever it was showing folds away as
    /// the next comes out of it.
    func openInIsland(_ piece: Island.Piece) {
        commandCenterShown = piece == .command
        fileFinderShown = piece == .files
        if piece != .review { review.noting = nil }
        reviewShown = piece == .review
    }
}
