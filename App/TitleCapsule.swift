import SwiftUI

/// The window's title made visible: project · branch · thread, level with the traffic lights.
/// Clicking it opens the command center, as ⌘K does. While there's an update, its circle hangs
/// off the pill's right end, however wide the pill is, without moving the pill. Its glass is the
/// island's, which the surfaces grow out of.
struct TitleCapsule: View {
    @Environment(AppModel.self) private var model
    @Environment(Updates.self) private var updates
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let island: Namespace.ID
    let ring: Namespace.ID
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
                        // One title a thread, as with its mark: the keyboard crossing brings the
                        // title up from its column's capsule, whole, over the copy there fading
                        // with that capsule, and sends this one down to its own, fading, so it's
                        // drawn for the one down there to start from. A thread opened any other
                        // way changes the title at once, with nothing to animate it.
                        Text(chat.title)
                            .foregroundStyle(Ink.primary)
                            .truncationMode(.tail)
                            .titleTravels(chat.id, in: ring, unless: reduceMotion)
                            .layoutPriority(-1)
                            .id(chat.id)
                            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
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
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.capsuleFrame = $0 }
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Command center (\(model.shortcuts.label(.commandCenter)))")
            // While the thread works, its mark at the capsule's left end, which opens its heads.
            // One mark a thread, so the keyboard crossing to the thread beside brings that
            // thread's mark in from its column's capsule, and sends this one back to its own.
            .overlay(alignment: .leading) {
                ZStack {
                    if working, let conversation = model.currentConversation {
                        mark(conversation)
                    }
                }
                .animation(reduceMotion ? Motion.fade : Motion.cross, value: model.chat?.id)
            }
            .animation(reduceMotion ? Motion.fade : Motion.cross, value: model.keyboardSide)
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
                .travels(conversation.chat.id, in: ring, unless: reduceMotion)
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
        .transition(.opacity)
    }
}

extension View {
    /// A thread's mark that glides to wherever the same thread's mark is drawn next, rather than
    /// going out in one place and coming in at another; with Reduce Motion it only fades.
    @ViewBuilder
    func travels(_ thread: UUID, in ring: Namespace.ID, unless still: Bool) -> some View {
        if still {
            self
        } else {
            matchedGeometryEffect(id: thread, in: ring)
        }
    }

    /// A thread's title that glides between the window's capsule and the capsule over its column,
    /// as its mark does; with Reduce Motion it only fades. Only its place travels: the text keeps
    /// the width it has where it's going, so it doesn't truncate differently on the way.
    @ViewBuilder
    func titleTravels(_ thread: UUID, in ring: Namespace.ID, unless still: Bool) -> some View {
        if still {
            self
        } else {
            matchedGeometryEffect(id: TravellingTitle(thread: thread), in: ring, properties: .position)
        }
    }
}

/// A thread's title in the ring, apart from its mark, which is keyed by the thread's id alone.
private struct TravellingTitle: Hashable {
    let thread: UUID
}

/// The keyboard crossing between two threads, drawn as the capsules' tint running like a liquid:
/// the other column's capsule rises into the window's and runs into it, and the one being left
/// comes out of it as a drop and falls into the other column's place. Each capsule is blurred and
/// the blur cut at half, as metaballs are drawn, so two that near each other draw a neck between
/// them and one that leaves draws one out. The real capsules' tint stands aside while it's out,
/// and the titles and marks ride over it on the same curve. With Reduce Motion there's no goo,
/// and the crossing ends as it begins.
struct CrossingGoo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let crossing: AppModel.Crossing
    @State private var progress = 0.0

    var body: some View {
        GeometryReader { area in
            if !reduceMotion {
                Goo(progress: progress, from: (crossing.capsule, crossing.beside),
                    to: (model.capsuleFrame, model.besideCapsuleFrame), origin: area.frame(in: .global).origin)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            guard !reduceMotion else {
                model.crossing = nil
                return
            }
            withAnimation(Motion.cross) { progress = 1 } completion: {
                if model.crossing == crossing { model.crossing = nil }
            }
        }
    }
}

private struct Goo: View, Animatable {
    nonisolated var progress: Double
    let from: (capsule: CGRect, beside: CGRect)
    /// Read as the goo is drawn, since the capsules take their new places a layout after the
    /// crossing begins.
    let to: (capsule: CGRect, beside: CGRect)
    let origin: CGPoint

    /// Wide enough that two capsules a few points apart run together, and narrower than the gap
    /// between the window's capsule and the column's at rest, which stay apart.
    private static let blur: CGFloat = 8

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: Surface.drawer))
            context.addFilter(.blur(radius: Self.blur))
            context.drawLayer { layer in
                for drop in drops {
                    layer.fill(Capsule().path(in: drop.offsetBy(dx: -origin.x, dy: -origin.y)), with: .color(.white))
                }
            }
        }
    }

    /// The window's capsule taking its new title's width, the column's rising into it, and the
    /// one being left falling out of it. The two in flight draw in toward a drop halfway, so they
    /// read as liquid rather than as bars sliding.
    private var drops: [CGRect] {
        let squeeze = sin(min(max(progress, 0), 1) * .pi) * 0.6
        return [
            Self.between(from.capsule, to.capsule, progress),
            Self.drop(Self.between(from.beside, to.capsule, progress), squeeze),
            Self.drop(Self.between(from.capsule, to.beside, progress), squeeze),
        ]
    }

    private static func between(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// A capsule drawn in toward a round drop of its own height by `squeeze`, about its middle.
    private static func drop(_ rect: CGRect, _ squeeze: Double) -> CGRect {
        let width = rect.width - (rect.width - rect.height) * squeeze
        return CGRect(x: rect.midX - width / 2, y: rect.minY, width: width, height: rect.height)
    }
}
