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
    /// Words that change in the capsule: the old fade quickly and the new come in just behind
    /// them, so the capsule is never an empty pill and the two are never both at full ink.
    static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.04)), removal: .opacity.animation(.easeOut(duration: 0.08)))
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
                ZStack {
                    Text(titled?.title ?? project.name)
                        .foregroundStyle(titled == nil ? Ink.secondary : Ink.primary)
                        .truncationMode(.tail)
                        .id(titled.map { "\($0.id) \($0.title)" } ?? project.name)
                        .transition(model.crossing != nil ? CrossingGoo.arrival(crossing: true) : Self.swap)
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
        .transition(model.crossing != nil ? CrossingGoo.arrival(crossing: true)
            : .asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.22)), removal: .opacity.animation(.easeOut(duration: 0.1))))
    }
}


/// The keyboard crossing between two threads, as drops of the capsules' tint joining and parting
/// the way water does. The capsule clicked draws itself into a drop where it stands, runs up to
/// the window capsule's end facing it until the two touch, and flows in, the end reaching out to
/// take it. The thread being left buds out of the other end, stretches it, pinches off, falls to
/// its column and spreads into that column's capsule. Each shape is blurred and the blur cut at
/// half, as metaballs are drawn, which is what draws the necks between them; the blur is all but
/// none at either end, so the goo starts and ends as the capsules it stands in for. Their tint,
/// titles and marks stand aside while it's out, and the titles fade in where the drops have
/// landed. With Reduce Motion there's no goo, and the crossing ends as it begins.
struct CrossingGoo: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let crossing: AppModel.Crossing
    @State private var progress = 0.0

    static let duration = 1.0
    /// How far into the crossing the drop has flowed into the window's capsule, which is when
    /// the title arriving there shows.
    static let merged = 0.82

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
        // Wide for all but the ends, where the necks are drawn, and next to none at either end.
        let blur = 1 + 8 * min(1, 2.5 * sin(min(max(progress, 0), 1) * .pi))
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
        // The window's capsule, taking its new title's width in the middle of it all.
        let widening = Self.ease(Self.stage(p, 0.35, 0.75))
        let body = Self.rect(center: Self.mix(from.capsule.center, to.capsule.center, widening),
                             size: Self.mix(from.capsule.size, to.capsule.size, widening))
        // Which end of it each drop meets: the one facing the column it comes from or goes to.
        let inSide: CGFloat = from.beside.midX > to.capsule.midX ? 1 : -1
        let outSide: CGFloat = to.beside.midX > from.capsule.midX ? 1 : -1
        func end(_ side: CGFloat) -> CGFloat { side > 0 ? body.maxX : body.minX }

        // The thread being left buds out of the end facing its column, the bud stretching the
        // capsule's end after it, then pinches off, falls and spreads into its column's capsule.
        let budding = Self.ease(Self.stage(p, 0.04, 0.3))
        let pinching = Self.ease(Self.stage(p, 0.3, 0.42))
        let falling = Self.ease(Self.stage(p, 0.38, 0.8))
        let spreading = Self.ease(Self.stage(p, 0.76, 1))
        let tip = end(outSide) + outSide * Self.drop * (0.5 * budding + 0.6 * pinching) - outSide * body.height / 2 * (1 - budding)
        let budded = CGPoint(x: tip, y: body.midY)
        let leaving = Self.rect(center: Self.mix(budded, to.beside.center, falling),
                                size: Self.mix(Self.mix(CGSize(width: body.height, height: body.height), round, budding), to.beside.size, spreading))

        // The capsule clicked draws itself into a drop where it stands, runs up to the end facing
        // it until the two touch, and flows in, the drop going into the end as the end reaches out
        // to take it, as two drops join.
        let rounding = Self.ease(Self.stage(p, 0, 0.25))
        let rising = Self.ease(Self.stage(p, 0.12, 0.6))
        let joining = Self.ease(Self.stage(p, 0.6, 0.88))
        let docked = CGPoint(x: end(inSide) + inSide * Self.drop * 0.45, y: body.midY)
        let inside = CGPoint(x: end(inSide) - inSide * body.height / 2, y: body.midY)
        let arriving = Self.rect(center: Self.mix(Self.mix(from.beside.center, docked, rising), inside, joining),
                                 size: Self.mix(Self.mix(from.beside.size, round, rounding), CGSize(width: body.height, height: body.height), joining))

        // Each end reaching after its drop, and the capsule filling out a little as the drop
        // that joins it settles.
        var capsule = body
        let reachOut = 14 * Self.bump(p, at: 0.24, over: 0.16)
        let reachIn = 12 * Self.bump(p, at: 0.7, over: 0.14)
        for (side, reach) in [(outSide, reachOut), (inSide, reachIn)] {
            if side > 0 { capsule.size.width += reach } else { capsule.origin.x -= reach; capsule.size.width += reach }
        }
        let fill = 3 * Self.bump(p, at: CrossingGoo.merged, over: 0.12)
        capsule = capsule.insetBy(dx: 0, dy: -fill / 2)
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
