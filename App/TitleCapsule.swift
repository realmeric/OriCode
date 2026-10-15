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
                            .id(chat.id)
                            .transition(CrossingGoo.arrival(crossing: model.crossing != nil))
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
        .transition(CrossingGoo.arrival(crossing: model.crossing != nil))
    }
}


/// The keyboard crossing between two threads, as two drops of the capsules' tint: the capsule
/// clicked draws itself into a drop where it stands, the drop runs up into the window's capsule
/// and the two flow together, the window's swelling as it takes it in; and the thread being left
/// comes out of the window's capsule as a drop of its own, falls to the other column and spreads
/// into that column's capsule. Each shape is blurred and the blur cut at half, as metaballs are
/// drawn, so a drop nearing the capsule draws a neck to it and one leaving draws one out. The
/// blur is all but none at either end, so the goo starts and ends as the capsules it stands in
/// for. Their tint, titles and marks stand aside while it's out, and the titles fade in where
/// the drops have landed. With Reduce Motion there's no goo, and the crossing ends as it begins.
struct CrossingGoo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let crossing: AppModel.Crossing
    @State private var progress = 0.0

    static let duration = 0.9
    /// How far into the crossing the drop has flowed into the window's capsule, which is when
    /// the title arriving there shows.
    static let merged = 0.72

    /// A title or mark as the crossing changes it: out at once, and in once its drop has landed.
    /// Anything else changes it at once.
    static func arrival(crossing: Bool) -> AnyTransition {
        guard crossing else { return .identity }
        return .asymmetric(insertion: .opacity.animation(Motion.fade.delay(duration * merged)), removal: .opacity.animation(Motion.fade))
    }

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
            withAnimation(.linear(duration: Self.duration)) { progress = 1 } completion: {
                if model.crossing == crossing { model.crossing = nil }
            }
        }
    }
}

/// The crossing's shapes at one moment of it, `progress` running evenly from 0 to 1 and each
/// stage easing within its own part of that.
private struct Goo: View, Animatable {
    nonisolated var progress: Double
    let from: (capsule: CGRect, beside: CGRect)
    /// Read as the goo is drawn, since the capsules take their new places a layout after the
    /// crossing begins.
    let to: (capsule: CGRect, beside: CGRect)
    let origin: CGPoint

    /// A drop's width, over the capsule's height, since the blur takes a few points off a round
    /// shape and the drop should read as the capsule's own water, not a dot.
    private static let drop: CGFloat = 32

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        // Widest mid-flight, where the necks are drawn, and next to none at either end.
        let blur = 1 + 8 * sin(min(max(progress, 0), 1) * .pi)
        Canvas { context, _ in
            context.addFilter(.alphaThreshold(min: 0.5, color: Surface.drawer))
            context.addFilter(.blur(radius: blur))
            context.drawLayer { layer in
                for shape in shapes {
                    layer.fill(Capsule().path(in: shape.offsetBy(dx: -origin.x, dy: -origin.y)), with: .color(.white))
                }
            }
        }
    }

    private var shapes: [CGRect] {
        let p = progress
        let round = CGSize(width: Self.drop, height: Self.drop)
        // The capsule clicked: drawn into a drop where it stands, then up into the window's.
        let rounding = Self.ease(Self.stage(p, 0, 0.3))
        let rising = Self.ease(Self.stage(p, 0.18, 0.78))
        let arriving = Self.rect(center: Self.mix(from.beside.center, to.capsule.center, rising),
                                 size: Self.mix(from.beside.size, round, rounding))
        // The thread being left: out of the window's capsule as a drop, down, and spread wide.
        let falling = Self.ease(Self.stage(p, 0.12, 0.7))
        let spreading = Self.ease(Self.stage(p, 0.66, 1))
        let leaving = Self.rect(center: Self.mix(from.capsule.center, to.beside.center, falling),
                                size: Self.mix(round, to.beside.size, spreading))
        // The window's capsule, taking its new title's width, swelling a little as a drop leaves
        // it and more as the other flows in.
        let width = Self.ease(Self.stage(p, 0.25, 0.85))
        let swell = 3 * Self.bump(p, at: 0.24, over: 0.14) + 5 * Self.bump(p, at: CrossingGoo.merged, over: 0.18)
        let size = Self.mix(from.capsule.size, to.capsule.size, width)
        let capsule = Self.rect(center: Self.mix(from.capsule.center, to.capsule.center, width),
                                size: CGSize(width: size.width + swell * 2, height: size.height + swell))
        return [capsule, arriving, leaving]
    }

    /// How far through a stage running from `start` to `end` of the crossing it is, 0 to 1.
    private static func stage(_ p: Double, _ start: Double, _ end: Double) -> Double {
        min(max((p - start) / (end - start), 0), 1)
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// 1 at `at`, falling smoothly to 0 `over` either side of it.
    private static func bump(_ p: Double, at center: Double, over width: Double) -> Double {
        let d = (p - center) / width
        return d * d < 1 ? pow(1 - d * d, 2) : 0
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    private static func mix(_ a: CGSize, _ b: CGSize, _ t: Double) -> CGSize {
        CGSize(width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    private static func rect(center: CGPoint, size: CGSize) -> CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
