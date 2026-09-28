import AppKit
import SwiftUI

/// Candidate B: OriCode's mark over the slider. The dot is the main head: it grows and heats as
/// the agent thinks harder, white at Low and in the agent's colour at Max. At Ultracode the six rays light
/// around it, the heads it runs on every task. The slider underneath sets the level, and a drag
/// across the mark walks it too.
struct MarkPicker: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    /// The window's room for the card; a page taller than this scrolls.
    var room: CGFloat = .infinity
    @State private var page = Page.effort

    enum Page { case effort, models }

    static let effortHeight: CGFloat = 308

    var body: some View {
        ZStack {
            switch page {
            case .effort:
                MarkPage(chat: chat) {
                    // The agent of the model in use opens with the page, the rest folded.
                    model.modelsOpen = [model.providerID(for: chat)]
                    page = .models
                }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: -24)).animation(Motion.fade)))
            case .models:
                ModelsPage(chat: chat) { page = .effort }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: 24)).animation(Motion.fade)))
            }
        }
        .frame(width: 320, height: height)
        .animation(Motion.glide, value: page)
        .animation(Motion.glide, value: model.raysShown)
        .onAppear {
            // The picker opens on the effort page, whatever it last showed.
            model.raysShown = false
            model.readAgentModels()
            // Asked now, so the Fast button already knows Claude Code's answer when it's clicked.
            if let option = model.option(for: chat), option.fast, model.fastReading(for: chat) == nil {
                model.checkFast(model: option.id, on: model.providerID(for: chat))
            }
        }
    }

    /// The effort page's height, or with its rays shown the mark's part of it and the list under
    /// it, scrolling past 470 or past the window's room, with the mark and a row or two kept.
    private var height: CGFloat {
        switch page {
        case .effort where model.raysShown:
            min(Self.raysTop + RayList.height(model, chat: chat), 470, max(room, Self.effortHeight))
        case .effort: Self.effortHeight
        case .models: ModelsPage.height(for: model.modelGroups(for: chat, open: model.modelsOpen))
        }
    }

    /// The rays' page above its list: the header, the mark and the title under it.
    static let raysTop: CGFloat = 12 + 30 + 96 + 44 + 6
}

private struct MarkPage: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let openModels: () -> Void
    /// The level under the slider's thumb while it's held, and the stop under the pointer.
    @State private var held: String?
    @State private var hovered: String?
    /// Where a drag across the mark started, in stops.
    @State private var dragFrom: Int?
    @State private var lastShown: Int?
    @State private var previewingReset = false
    @State private var markHovered = false
    @State private var resetTurns = 0
    @State private var blockedNote = false
    /// For a few seconds after a change the rays turn at Ultracode, then rest upright.
    @State private var live = false
    @State private var calming: Task<Void, Never>?
    /// Bumped as a level lands, for the dot's pop.
    @State private var pops = 0

    /// How far a drag across the mark goes for each level.
    private static let step: CGFloat = 26
    /// The extra a drag has to push past Max to reach Ultracode.
    private static let gate: CGFloat = 22

    private var state: PickerState { PickerState(model: model, chat: chat) }

    var body: some View {
        let state = state
        let stops = state.option?.stops ?? []
        let level = held ?? state.level
        let shown = level.flatMap(stops.firstIndex(of:))
        let ink = MarkPalette.ink(for: model.providerID(for: chat))
        let heads = model.offersWorkers(chat)
        let raysShown = heads && model.raysShown
        VStack(spacing: 0) {
            ZStack {
                if raysShown {
                    raysHeader
                        .transition(Self.swap)
                } else {
                    header(state)
                        .transition(Self.swap)
                }
            }
            .frame(height: 30)
            // One mark for both pages, so it stays where it is as the page turns: the dot turns
            // from the level's heat to the head's colour, and the rays stay lit on their arcs.
            HeadMark(level: stops.isEmpty ? nil : level, ink: ink, fast: state.fastAsked && !raysShown, live: live, pops: pops,
                     rays: heads ? model.rayColors(for: chat) : [:], head: raysShown ? MarkPalette.color(for: model.providerID(for: chat)) : nil,
                     inviting: heads && markHovered && !raysShown)
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .contentShape(.rect)
                .onHover { markHovered = $0 }
                .onTapGesture { if heads { showRays(!raysShown) } }
                .gesture(scrub(stops, index: state.level.flatMap(stops.firstIndex(of:)), blocked: blocked(state)), including: raysShown ? .none : .all)
                .help(heads ? raysShown ? "Back to the effort" : "Rays: the models \(ModelMenu.shortName(state.option?.name ?? "the head")) sends work to" : "")
                // The level is the slider's to say; the mark says the pair and turns the page.
                .accessibilityElement()
                .accessibilityLabel(model.pairLine(for: chat))
                .accessibilityHint(raysShown ? "Goes back to the effort" : "Shows the rays")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { showRays(!raysShown) }
                .accessibilityHidden(!heads)
                .padding(.top, 4)
            ZStack(alignment: .top) {
                if raysShown {
                    VStack(spacing: 0) {
                        RaysTitle(chat: chat)
                            .padding(.bottom, 6)
                        DeferredRayList(chat: chat) { showRays(false) }
                            .padding(.horizontal, -16)
                            .padding(.bottom, -12)
                    }
                    .transition(Self.turn)
                } else {
                    effortControls(state, level: level, shown: shown, stops: stops, ink: ink)
                        .transition(Self.turn)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        // The rail takes left and right, so up goes to the mark above it and its rays.
        .onKeyPress(.upArrow) {
            guard heads, !raysShown else { return .ignored }
            showRays(true)
            return .handled
        }
        .onChange(of: shown, initial: true) { old, now in
            lastShown = old ?? now
        }
        .onChange(of: state.effort) {
            pops += 1
            wake()
        }
        // The dot pops as the head takes a ray on or lets one go.
        .onChange(of: model.rays(for: chat).count) { pops += 1 }
        // Switching fast wakes the mark, so the bubbles swirl as they come and the rays race.
        .onChange(of: state.fastAsked) { wake() }
        .onAppear { wake() }
        .onDisappear { calming?.cancel() }
    }

    /// What's under the mark as the page turns: the old part goes in 0.1s and the new one rises in
    /// after it, so the two never show over each other.
    private static let turn = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .offset(y: 12)).animation(Motion.move.delay(0.1)),
        removal: .opacity.animation(.easeOut(duration: 0.1)))
    /// The header's, which stays in place.
    private static let swap = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.fade.delay(0.1)),
        removal: .opacity.animation(.easeOut(duration: 0.1)))

    private func showRays(_ shown: Bool) {
        withAnimation(Motion.move) { model.showRays(shown, for: chat) }
    }

    /// The rays' page's header: back to the effort at the left, the head in the middle, and No Rays
    /// at the right while there are any.
    private var raysHeader: some View {
        HStack(spacing: 0) {
            CircleButton(symbol: "chevron.left", help: "Back to the effort") { showRays(false) }
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                AgentMark(agent: model.providerID(for: chat))
                    .frame(width: 12, height: 12)
                Text(model.option(for: chat)?.name ?? "Model")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            Group {
                if model.rays(for: chat).isEmpty {
                    Color.clear
                } else {
                    CircleButton(symbol: "arrow.counterclockwise", help: "No rays") {
                        withAnimation(Motion.move) { model.setRays([], for: chat) }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.6)).animation(Motion.move))
                }
            }
            .frame(width: 30, height: 30)
        }
    }

    private func effortControls(_ state: PickerState, level: String?, shown: Int?, stops: [String], ink: AgentInk) -> some View {
        VStack(spacing: 0) {
            title(state, level: level, shown: shown, stops: stops)
                .frame(height: 26)
            line(state, level: level, stops: stops)
                .frame(height: 16)
                .padding(.top, 2)
            if let option = state.option, !option.efforts.isEmpty {
                EffortRail(stops: option.stops, home: state.home, blocked: blocked(state), ink: ink,
                           effort: Binding(get: { state.effort }, set: { model.setEffort($0, for: chat) }),
                           held: $held, hovered: $hovered, fast: state.fastAsked, compact: true,
                           ghost: previewingReset ? resetTarget(state) : nil,
                           onBlocked: showBlocked, onReturn: { model.modelPickerShown = false })
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            if !state.modes.isEmpty {
                ModeTiles(modes: state.modes, mode: Binding(get: { state.mode.rawValue }, set: { model.setPermissionMode($0, for: chat) }),
                          preview: previewingReset ? PermissionModeOption(rawValue: model.threadDefaults.permissionMode) : nil,
                          compact: state.unsupervised)
            }
            if state.unsupervised {
                // Where the tiles' line would be, since it says the same kind of thing. Claude's
                // words for a mode, "Edits and commands wait for you", would be wrong here.
                Text("\(state.agent.agent) runs unsupervised · nothing waits for you")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(1)
                    .frame(height: 16)
                    .padding(.top, state.modes.isEmpty ? 0 : 6)
            }
        }
    }

    /// Fast mode at the left, where every model shows it, dimmed on one that can't go fast; the
    /// model in the middle; Back to Defaults at the right when there's anything to go back from.
    private func header(_ state: PickerState) -> some View {
        HStack(spacing: 0) {
            FastButton(on: state.fastAsked, dimmed: previewingReset && !model.threadDefaults.fast) {
                model.setFast(!state.fastAsked, for: chat)
            }
            .disabled(state.option?.fast != true)
            .opacity(state.option?.fast == true ? 1 : 0.35)
            .help(state.option?.fast == true ? "Fast mode: faster output from the same model" : "This model can't run fast")
            .frame(width: 30, height: 30)
            Spacer(minLength: 6)
            let back = model.defaultModel(for: chat)
            ModelLine(option: state.option, agent: previewingReset ? back.provider : model.providerID(for: chat),
                      preview: previewingReset ? model.option(back) : nil, action: openModels)
            Spacer(minLength: 6)
            Group {
                if !model.atDefaults(chat) {
                    ResetButton(turns: resetTurns, previewing: $previewingReset) {
                        resetTurns += 1
                        previewingReset = false
                        var wave = Transaction(animation: Motion.move)
                        wave[ResetWave.self] = true
                        withTransaction(wave) { model.resetToDefaults(for: chat) }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.6)).animation(Motion.move))
                } else {
                    Color.clear
                }
            }
            .frame(width: 30, height: 30)
        }
    }

    private func title(_ state: PickerState, level: String?, shown: Int?, stops: [String]) -> some View {
        let name = stops.isEmpty ? "Standard" : level.map(ModelMenu.effortName) ?? "Default"
        let rising = (shown ?? 0) >= (lastShown ?? shown ?? 0)
        return HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .id(name)
                .transition(.asymmetric(insertion: AnyTransition(.blurReplace).combined(with: .offset(y: rising ? 6 : -6)),
                                        removal: AnyTransition(.blurReplace)))
            if level == Effort.ultracode {
                Tag(text: "This thread")
                    .transition(.opacity.animation(Motion.fade))
            } else if level != nil, held == nil ? state.effort == nil : level == state.home {
                Tag(text: "Default")
                    .transition(.opacity.animation(Motion.fade))
            }
        }
        .animation(Motion.move, value: name)
    }

    /// What the level does, or what a hovered stop would do; the cost of Max and Ultracode in the
    /// session's usage band.
    private func line(_ state: PickerState, level: String?, stops: [String]) -> some View {
        let previewed = held == nil ? hovered : nil
        let words: (String, String?)
        if blockedNote || (previewed == Effort.ultracode && blocked(state)) {
            words = ("Needs dynamic workflows, see /config in \(state.agent.name)", nil)
        } else if let problem = state.fastProblem, previewed == nil, held == nil {
            words = (problem, nil)
        } else if let missing = state.ultracodeMissing, previewed == nil, held == nil {
            words = (missing, nil)
        } else if stops.isEmpty {
            words = ("\(ModelMenu.shortName(state.option?.name ?? "This model")) has one reasoning level", nil)
        } else if let shown = previewed ?? level {
            words = EffortScale.line(shown, on: state.option, agent: state.agent.id)
        } else {
            words = ("Runs at the model's default level", nil)
        }
        return Group {
            if let cost = words.1 {
                let band = model.usage?.headline?.used.map { Band.of($0).color } ?? Ink.secondary
                Text("\(words.0) · \(Text(cost).foregroundStyle(band))")
            } else {
                Text(words.0)
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .lineLimit(1)
        .id(words.0)
        .transition(.opacity.animation(Motion.fade))
    }

    /// Dragging across the mark walks the levels too, a detent on the trackpad at each, and the
    /// slider follows as each one lands. Ultracode sits past a gate the drag has to push through.
    private func scrub(_ stops: [String], index: Int?, blocked: Bool) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                guard !stops.isEmpty else { return }
                let from = dragFrom ?? index ?? 0
                if dragFrom == nil { dragFrom = from }
                var target = min(max(from + Int((drag.translation.width / Self.step).rounded()), 0), stops.count - 1)
                if stops[target] == Effort.ultracode, from != target,
                   blocked || drag.translation.width < CGFloat(target - from) * Self.step + Self.gate {
                    target -= 1
                }
                let was = state.level.flatMap(stops.firstIndex(of:)) ?? from
                guard target != was else { return }
                if target > was, EffortScale.spendsFaster(stops[target]) {
                    Haptics.threshold()
                } else {
                    Haptics.detent()
                }
                let level = stops[target]
                withAnimation(Motion.move) { model.setEffort(level == state.home ? nil : level, for: chat) }
            }
            .onEnded { _ in dragFrom = nil }
    }

    /// Where the thumb lands after Back to Defaults, when the model stays the same.
    private func resetTarget(_ state: PickerState) -> String? {
        let back = model.defaultModel(for: chat)
        guard back.provider == model.providerID(for: chat), back.id == state.option?.id else { return nil }
        return model.threadDefaults.effort ?? state.home
    }

    private func blocked(_ state: PickerState) -> Bool {
        state.option.map { $0.ultraBlocked != nil && !$0.ultra } ?? false
    }

    private func showBlocked() {
        blockedNote = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            blockedNote = false
        }
    }

    private func wake() {
        calming?.cancel()
        live = true
        calming = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { live = false }
        }
    }
}

/// OriCode's mark, large. The dot is the main head, and how hard it thinks is how big and how hot
/// it is: a small white point at Low, its agent's colour burning at Max. The rays are heads, idle
/// and faint until Ultracode lights all six. In fast mode bubbles swirl inside the head at every
/// level, and at Ultracode the rays race round in half a second with a trail behind each.
private struct HeadMark: View {
    let level: String?
    let ink: AgentInk
    let fast: Bool
    let live: Bool
    let pops: Int
    /// The head's rays, lit on their arcs in their agents' colours; at Ultracode the arcs left over
    /// light white around them.
    var rays: [Int: Color] = [:]
    /// On the rays' page, the head's colour, which the dot takes in place of the level's heat.
    var head: Color?
    /// The pointer is on a mark that opens the rays, so its arcs at rest come up.
    var inviting = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ultra = level == Effort.ultracode && head == nil
        let heat = head.map(Heat.init(head:)) ?? Heat(level, in: ink)
        // With rays picked, the arcs at rest step back and the lit ones glow in their colour, so a
        // white ray still reads as lit beside white arcs at rest.
        let resting = rays.isEmpty ? (inviting ? 0.3 : 0.13) : (inviting ? 0.2 : 0.07)
        ZStack {
            RaysMark(slots: ultra ? Set(0..<RaysMark.rays) : Set(rays.keys), turning: live && ultra && !reduceMotion,
                     restingOpacity: resting, litOpacity: rays.isEmpty ? 0.9 : 1, dotOpacity: 0, color: .white, colors: rays,
                     stagger: true, layered: true, settles: true, fast: fast, glow: !rays.isEmpty)
                .frame(width: 88, height: 88)
            ZStack {
                dot(heat)
                    .shadow(color: heat.glow, radius: heat.reach)
                if fast {
                    FastBubbles(size: heat.size, tint: NSColor(heat.bubble), spinning: live && !reduceMotion)
                        .frame(width: FastBubbles.side, height: FastBubbles.side)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pops) { dot, scale in
                dot.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.16, duration: 0.1)
                SpringKeyframe(1, duration: 0.45, spring: .bouncy)
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: level)
        .animation(Motion.move, value: fast)
        .animation(Motion.move, value: head)
    }

    private func dot(_ heat: Heat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [heat.core, heat.rim], center: UnitPoint(x: 0.45, y: 0.38), startRadius: 0, endRadius: heat.size * 0.62))
            .frame(width: heat.size, height: heat.size)
    }

    /// How big the dot is and how hot it burns at a level.
    fileprivate struct Heat {
        let size: CGFloat
        let core: Color
        let rim: Color
        let glow: Color
        let reach: CGFloat
        /// Fast mode's bubbles: the agent's colour on the white heads, white-hot, the way the
        /// slider's sparks are born, on the coloured ones.
        let bubble: Color

        init(_ level: String?, in ink: AgentInk) {
            let white = Color.white.opacity(0.95)
            let tinted = ink.color.opacity(0.6)
            let whiteHot = ink.whiteHotColor.opacity(0.95)
            let base = ink.color
            let ember = ink.emberColor
            switch level {
            case "low": self.init(16, white, .white.opacity(0.8), .white.opacity(0.12), 4, tinted)
            case "medium": self.init(20, white, .white.opacity(0.85), .white.opacity(0.16), 6, tinted)
            case "high": self.init(24, white, ember, ember.opacity(0.28), 8, base.opacity(0.65))
            case "xhigh": self.init(28, ember, base.mix(with: ember, by: 0.45, in: .device), base.opacity(0.35), 11, whiteHot)
            case "max": self.init(32, ember, base, base.opacity(0.7), 16, whiteHot)
            case Effort.ultracode: self.init(28, ember, base, base.opacity(0.6), 14, whiteHot)
            default: self.init(20, white, .white.opacity(0.85), .white.opacity(0.14), 6, tinted)
            }
        }

        /// The head itself on the rays' page: its agent's colour, lit from the upper left.
        init(head color: Color) {
            self.init(26, color.mix(with: .white, by: 0.35, in: .device), color, color.opacity(0.5), 10, color)
        }

        private init(_ size: CGFloat, _ core: Color, _ rim: Color, _ glow: Color, _ reach: CGFloat, _ bubble: Color) {
            self.size = size
            self.core = core
            self.rim = rim
            self.glow = glow
            self.reach = reach
            self.bubble = bubble
        }
    }
}

/// Fast mode's bubbles, swirling inside the head: ring bubbles on three orbits, the inner ones
/// quicker, like a whirlpool, clipped to the head and grown with it. They swirl while the mark is
/// live, then coast still and stay drawn, so fast still reads as on with nothing moving: a moving
/// picker makes the window server redraw its blur.
private struct FastBubbles: NSViewRepresentable {
    /// Drawn at Max's size and scaled down to the level's.
    static let side: CGFloat = 32

    let size: CGFloat
    let tint: NSColor
    let spinning: Bool

    func makeNSView(context: Context) -> BubblesView { BubblesView() }

    func updateNSView(_ view: BubblesView, context: Context) {
        view.want(size: size, tint: tint, spinning: spinning)
    }

    static func dismantleNSView(_ view: BubblesView, coordinator: ()) {
        view.stop()
    }

    final class BubblesView: NSView {
        private struct Orbit {
            let radius: CGFloat
            /// Where each bubble starts, in degrees, and how wide it is, in the disc's 32pt.
            let bubbles: [(angle: CGFloat, diameter: CGFloat)]
            let period: CFTimeInterval
            let fizz: CFTimeInterval
        }

        private static let orbits = [
            Orbit(radius: 3.2, bubbles: [(110, 5.1)], period: 0.6, fizz: 0.45),
            Orbit(radius: 9, bubbles: [(20, 7), (200, 7)], period: 0.9, fizz: 0.6),
            Orbit(radius: 11.8, bubbles: [(70, 4.2), (190, 4.2), (310, 4.2)], period: 1.4, fizz: 0.75),
        ]

        /// The head's disc, which clips the bubbles and scales with the level.
        private let disc = CALayer()
        private var orbits: [CALayer] = []
        private var bubbles: [(layer: CAShapeLayer, fizz: CFTimeInterval)] = []
        private var size: CGFloat = 0
        private var tint: NSColor?
        private var spinning = false
        private var occlusion: NSObjectProtocol?
        private var displayOptions: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            let side = FastBubbles.side
            disc.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            disc.cornerRadius = side / 2
            disc.masksToBounds = true
            for orbit in Self.orbits {
                let ring = CALayer()
                ring.frame = disc.bounds
                for bubble in orbit.bubbles {
                    let angle = bubble.angle * .pi / 180
                    let shape = CAShapeLayer()
                    shape.bounds = CGRect(x: 0, y: 0, width: bubble.diameter, height: bubble.diameter)
                    shape.position = CGPoint(x: side / 2 + orbit.radius * cos(angle), y: side / 2 + orbit.radius * sin(angle))
                    shape.path = CGPath(ellipseIn: shape.bounds, transform: nil)
                    shape.lineWidth = 1.6
                    ring.addSublayer(shape)
                    bubbles.append((shape, orbit.fizz))
                }
                disc.addSublayer(ring)
                orbits.append(ring)
            }
            layer?.addSublayer(disc)
        }

        required init?(coder: NSCoder) { nil }

        // The mark's scrub gesture is under it.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            forget()
            guard let window else {
                stop()
                return
            }
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                }
            apply()
        }

        func want(size: CGFloat, tint: NSColor, spinning: Bool) {
            if tint != self.tint {
                CATransaction.begin()
                CATransaction.setAnimationDuration(self.tint == nil ? 0 : 0.35)
                for bubble in bubbles {
                    bubble.layer.strokeColor = tint.cgColor
                    bubble.layer.fillColor = tint.withAlphaComponent(tint.alphaComponent * 0.22).cgColor
                }
                CATransaction.commit()
                self.tint = tint
            }
            if size != self.size {
                let scale = size / FastBubbles.side
                let from = disc.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? scale
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                disc.setValue(scale, forKeyPath: "transform.scale")
                CATransaction.commit()
                if self.size > 0 {
                    // The head's own spring, so the clip keeps to the dot as the level changes.
                    let grow = CASpringAnimation(perceptualDuration: 0.35, bounce: 0.3)
                    grow.keyPath = "transform.scale"
                    grow.fromValue = from
                    grow.toValue = scale
                    disc.add(grow, forKey: "grow")
                }
                self.size = size
            }
            self.spinning = spinning
            apply()
        }

        private var visible: Bool {
            guard let window else { return false }
            return window.occlusionState.contains(.visible) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        private func apply() {
            guard window != nil else { return }
            if !visible {
                halt()
            } else if spinning {
                swirl()
            } else {
                coast()
            }
        }

        /// Clockwise, which for a layer drawn upward is the negative way, and the inner orbits first.
        private func swirl() {
            for (ring, orbit) in zip(orbits, Self.orbits) where ring.animation(forKey: "orbit") == nil {
                let from = angle(of: ring)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ring.removeAnimation(forKey: "coast")
                ring.setValue(from, forKeyPath: "transform.rotation.z")
                CATransaction.commit()
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = from
                spin.toValue = from - 2 * .pi
                spin.duration = orbit.period
                spin.repeatCount = .infinity
                ring.add(spin, forKey: "orbit")
            }
            for (index, bubble) in bubbles.enumerated() where bubble.layer.animation(forKey: "fizz") == nil {
                let fizz = CABasicAnimation(keyPath: "transform.scale")
                fizz.fromValue = 0.8
                fizz.toValue = 1.12
                fizz.duration = bubble.fizz
                fizz.autoreverses = true
                fizz.repeatCount = .infinity
                fizz.timeOffset = Double(index) * 0.13
                fizz.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                bubble.layer.removeAnimation(forKey: "settle")
                bubble.layer.add(fizz, forKey: "fizz")
            }
        }

        /// Leaves at each orbit's own speed and eases to a stop, then the bubbles rest where they are.
        private func coast() {
            for (ring, orbit) in zip(orbits, Self.orbits) where ring.animation(forKey: "orbit") != nil {
                let from = angle(of: ring)
                let to = from - 2 * .pi / orbit.period * 0.8 / 2.5
                let coast = CABasicAnimation(keyPath: "transform.rotation.z")
                coast.fromValue = from
                coast.toValue = to
                coast.duration = 0.8
                coast.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.5, 0.4, 1)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                ring.setValue(to, forKeyPath: "transform.rotation.z")
                ring.removeAnimation(forKey: "orbit")
                ring.add(coast, forKey: "coast")
                CATransaction.commit()
            }
            settle()
        }

        /// Stops everything on the spot: the window was covered, or Reduce Motion came on.
        private func halt() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for ring in orbits {
                ring.setValue(angle(of: ring), forKeyPath: "transform.rotation.z")
                ring.removeAllAnimations()
            }
            for bubble in bubbles { bubble.layer.removeAllAnimations() }
            CATransaction.commit()
        }

        private func settle() {
            for bubble in bubbles where bubble.layer.animation(forKey: "fizz") != nil {
                let scale = bubble.layer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat ?? 1
                let settle = CABasicAnimation(keyPath: "transform.scale")
                settle.fromValue = scale
                settle.toValue = 1
                settle.duration = 0.2
                settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bubble.layer.removeAnimation(forKey: "fizz")
                bubble.layer.add(settle, forKey: "settle")
            }
        }

        private func angle(of ring: CALayer) -> Double {
            let moving = ring.animation(forKey: "orbit") != nil || ring.animation(forKey: "coast") != nil
            return (moving ? ring.presentation() ?? ring : ring).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        }

        func stop() {
            forget()
            halt()
        }

        private func forget() {
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
            occlusion = nil
            displayOptions = nil
        }
    }
}
