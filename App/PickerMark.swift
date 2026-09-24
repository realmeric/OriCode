import AppKit
import SwiftUI

/// Candidate B: OriCode's mark over the slider. The dot is the main head: it grows and heats as
/// Claude thinks harder, white at Low and Claude's orange at Max. At Ultracode the six rays light
/// around it, the heads it runs on every task. The slider underneath sets the level, and a drag
/// across the mark walks it too.
struct MarkPicker: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var page = Page.effort

    enum Page { case effort, models }

    static let effortHeight: CGFloat = 308

    var body: some View {
        ZStack {
            switch page {
            case .effort:
                MarkPage(chat: chat) { page = .models }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: -24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: -24)).animation(Motion.fade)))
            case .models:
                ModelsPage(chat: chat) { page = .effort }
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)).animation(Motion.move),
                                            removal: .opacity.combined(with: .offset(x: 24)).animation(Motion.fade)))
            }
        }
        .frame(width: 320, height: page == .effort ? Self.effortHeight : ModelsPage.height(for: model.modelGroups))
        .animation(Motion.glide, value: page)
        .onAppear {
            // Asked now, so the Fast button already knows Claude Code's answer when it's clicked.
            if let option = model.option(for: chat), option.fast, model.fastReadings[option.id] == nil {
                model.checkFast(model: option.id)
            }
        }
    }
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
        VStack(spacing: 0) {
            header(state)
                .frame(height: 30)
            HeadMark(level: stops.isEmpty ? nil : level, fast: state.fastAsked, live: live, pops: pops)
                .frame(maxWidth: .infinity)
                .frame(height: 92)
                .contentShape(.rect)
                .gesture(scrub(stops, index: state.level.flatMap(stops.firstIndex(of:)), blocked: blocked(state)))
                // VoiceOver meets the slider underneath, which says the same.
                .accessibilityHidden(true)
                .padding(.top, 4)
            title(state, level: level, shown: shown, stops: stops)
                .frame(height: 26)
            line(state, level: level, stops: stops)
                .frame(height: 16)
                .padding(.top, 2)
            if let option = state.option, !option.efforts.isEmpty {
                EffortRail(stops: option.stops, home: state.home, blocked: blocked(state),
                           effort: Binding(get: { state.effort }, set: { model.setEffort($0, for: chat) }),
                           held: $held, hovered: $hovered, fast: state.fastAsked, compact: true,
                           ghost: previewingReset ? resetTarget(state) : nil,
                           onBlocked: showBlocked, onReturn: { model.modelPickerShown = false })
                    .padding(.top, 10)
            }
            Spacer(minLength: 0)
            ModeTiles(mode: Binding(get: { state.mode.rawValue }, set: { model.setPermissionMode($0, for: chat) }),
                      preview: previewingReset ? PermissionModeOption(rawValue: model.threadDefaults.permissionMode) : nil,
                      compact: false)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .onChange(of: shown, initial: true) { old, now in
            lastShown = old ?? now
        }
        .onChange(of: state.effort) {
            pops += 1
            wake()
        }
        // Switching fast wakes the mark, so the bubbles swirl as they come and the rays race.
        .onChange(of: state.fastAsked) { wake() }
        .onAppear { wake() }
        .onDisappear { calming?.cancel() }
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
            ModelLine(option: state.option, preview: previewingReset ? model.models.first { $0.id == model.threadDefaults.model } : nil,
                      action: openModels)
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
            words = ("Needs dynamic workflows, see /config in Claude Code", nil)
        } else if let problem = state.fastProblem, previewed == nil, held == nil {
            words = (problem, nil)
        } else if let missing = state.ultracodeMissing, previewed == nil, held == nil {
            words = (missing, nil)
        } else if stops.isEmpty {
            words = ("\(ModelMenu.shortName(state.option?.name ?? "This model")) has one reasoning level", nil)
        } else if let shown = previewed ?? level {
            words = EffortScale.line(shown)
        } else {
            words = ("Claude Code picks the level for this model", nil)
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
        let target = model.threadDefaults
        guard target.model == state.option?.id else { return nil }
        return target.effort ?? state.home
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
/// it is: a small white point at Low, Claude's orange burning at Max. The rays are heads, idle and
/// faint until Ultracode lights all six. In fast mode bubbles swirl inside the head at every level,
/// and at Ultracode the rays race round in half a second with a trail behind each.
private struct HeadMark: View {
    let level: String?
    let fast: Bool
    let live: Bool
    let pops: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ultra = level == Effort.ultracode
        let heat = Heat(level)
        ZStack {
            RaysMark(lit: ultra ? RaysMark.rays : 0, turning: live && ultra && !reduceMotion, restingOpacity: 0.13, litOpacity: 0.9,
                     dotOpacity: 0, color: .white, stagger: true, layered: true, settles: true, fast: fast)
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
        /// Fast mode's bubbles: Claude's orange on the white heads, white-hot, the way the
        /// slider's sparks are born, on the orange ones.
        let bubble: Color

        init(_ level: String?) {
            let white = Color.white.opacity(0.95)
            let orange = Ink.claude.opacity(0.6)
            let whiteHot = Color(red: 1, green: 0.97, blue: 0.92).opacity(0.95)
            switch level {
            case "low": self.init(16, white, .white.opacity(0.8), .white.opacity(0.12), 4, orange)
            case "medium": self.init(20, white, .white.opacity(0.85), .white.opacity(0.16), 6, orange)
            case "high": self.init(24, white, Ink.ember, Ink.ember.opacity(0.28), 8, Ink.claude.opacity(0.65))
            case "xhigh": self.init(28, Ink.ember, Ink.claude.mix(with: Ink.ember, by: 0.45, in: .device), Ink.claude.opacity(0.35), 11, whiteHot)
            case "max": self.init(32, Ink.ember, Ink.claude, Ink.claude.opacity(0.7), 16, whiteHot)
            case Effort.ultracode: self.init(28, Ink.ember, Ink.claude, Ink.claude.opacity(0.6), 14, whiteHot)
            default: self.init(20, white, .white.opacity(0.85), .white.opacity(0.14), 6, orange)
            }
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
