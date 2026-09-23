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
    /// Bumped as a level lands, for the dot's pop, and as fast mode comes on, for its zip.
    @State private var pops = 0
    @State private var zips = 0

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
            HeadMark(level: stops.isEmpty ? nil : level, fast: state.fastAsked, live: live, pops: pops, zips: zips)
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
        .onChange(of: state.fastAsked) { _, on in
            if on { zips += 1 }
            wake()
        }
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
    /// colour the usage circle has for the session.
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
/// faint until Ultracode lights all six. In fast mode the head trails speed lines, zips forward as
/// fast comes on, and streaks run through the mark for the few seconds after.
private struct HeadMark: View {
    let level: String?
    let fast: Bool
    let live: Bool
    let pops: Int
    let zips: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ultra = level == Effort.ultracode
        let heat = Heat(level)
        ZStack {
            if fast, live, !reduceMotion {
                FastWind()
                    .frame(width: 150, height: 80)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(Motion.fade))
            }
            RaysMark(lit: ultra ? RaysMark.rays : 0, turning: live && ultra && !reduceMotion, restingOpacity: 0.13, litOpacity: 0.9,
                     dotOpacity: 0, color: .white, stagger: true, layered: true, settles: true)
                .frame(width: 88, height: 88)
            if fast {
                speedLines(behind: heat.size)
                    .transition(.opacity.combined(with: .offset(x: 10)).animation(Motion.move))
            }
            Circle()
                .fill(RadialGradient(colors: [heat.core, heat.rim], center: UnitPoint(x: 0.45, y: 0.38), startRadius: 0, endRadius: heat.size * 0.62))
                .frame(width: heat.size, height: heat.size)
                .shadow(color: heat.glow, radius: heat.reach)
                .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : pops) { dot, scale in
                    dot.scaleEffect(scale)
                } keyframes: { _ in
                    CubicKeyframe(1.16, duration: 0.1)
                    SpringKeyframe(1, duration: 0.45, spring: .bouncy)
                }
                // Fast mode coming on: the head darts forward, stretched, and springs back.
                .keyframeAnimator(initialValue: Zip(), trigger: reduceMotion ? 0 : zips) { dot, zip in
                    dot.scaleEffect(x: zip.stretch, y: 1 / zip.stretch).offset(x: zip.shift)
                } keyframes: { _ in
                    KeyframeTrack(\.shift) {
                        CubicKeyframe(8, duration: 0.12)
                        SpringKeyframe(0, duration: 0.5, spring: .bouncy)
                    }
                    KeyframeTrack(\.stretch) {
                        CubicKeyframe(1.35, duration: 0.12)
                        SpringKeyframe(1, duration: 0.5, spring: .bouncy)
                    }
                }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: level)
        .animation(Motion.move, value: fast)
    }

    private struct Zip {
        var shift: CGFloat = 0
        var stretch: CGFloat = 1
    }

    /// Three lines trailing the head, the way a thing drawn moving has them, ending just short of it.
    private func speedLines(behind size: CGFloat) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach([(10.0, 0.35), (16.0, 0.75), (10.0, 0.35)], id: \.0.self) { line in
                Capsule()
                    .fill(Ink.ember.opacity(line.1))
                    .frame(width: line.0, height: 2)
            }
        }
        .frame(width: 16, alignment: .trailing)
        .offset(x: -(size / 2 + 12))
    }

    /// How big the dot is and how hot it burns at a level.
    fileprivate struct Heat {
        let size: CGFloat
        let core: Color
        let rim: Color
        let glow: Color
        let reach: CGFloat

        init(_ level: String?) {
            let white = Color.white.opacity(0.95)
            switch level {
            case "low": self.init(16, white, .white.opacity(0.8), .white.opacity(0.12), 4)
            case "medium": self.init(20, white, .white.opacity(0.85), .white.opacity(0.16), 6)
            case "high": self.init(24, white, Ink.ember, Ink.ember.opacity(0.28), 8)
            case "xhigh": self.init(28, Ink.ember, Ink.claude.mix(with: Ink.ember, by: 0.45, in: .device), Ink.claude.opacity(0.35), 11)
            case "max": self.init(32, Ink.ember, Ink.claude, Ink.claude.opacity(0.7), 16)
            case Effort.ultracode: self.init(28, Ink.ember, Ink.claude, Ink.claude.opacity(0.6), 14)
            default: self.init(20, white, .white.opacity(0.85), .white.opacity(0.14), 6)
            }
        }

        private init(_ size: CGFloat, _ core: Color, _ rim: Color, _ glow: Color, _ reach: CGFloat) {
            self.size = size
            self.core = core
            self.rim = rim
            self.glow = glow
            self.reach = reach
        }
    }
}

/// Fast mode's streaks running through the mark, the way they run back along the slider, for the
/// few seconds after it comes on: Core Animation, so nothing is drawn per frame by the app.
private struct FastWind: NSViewRepresentable {
    func makeNSView(context: Context) -> WindView { WindView() }

    func updateNSView(_ view: WindView, context: Context) {}

    final class WindView: NSView {
        private let emitter = CAEmitterLayer()
        private let fade = CAGradientLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .surface
            emitter.renderMode = .additive
            emitter.emitterCells = [Self.streak]
            emitter.beginTime = CACurrentMediaTime() - 0.6
            layer?.addSublayer(emitter)
            // They come out of the glass and go back into it rather than starting and stopping at an edge.
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, 0.3, 0.7, 1]
            layer?.mask = fade
        }

        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emitter.frame = bounds
            fade.frame = bounds
            emitter.emitterPosition = CGPoint(x: bounds.maxX, y: bounds.midY)
            emitter.emitterSize = CGSize(width: 1, height: bounds.height * 0.7)
            CATransaction.commit()
        }

        private static var streak: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = EffortEffects.EffectsView.streak
            cell.contentsScale = 2
            cell.birthRate = 14
            cell.lifetime = 1
            cell.lifetimeRange = 0.3
            cell.velocity = 170
            cell.velocityRange = 50
            cell.emissionLongitude = .pi
            cell.scale = 0.9
            cell.scaleRange = 0.4
            cell.color = EffortEffects.EffectsView.ember.copy(alpha: 0.5)
            cell.alphaRange = 0.2
            cell.alphaSpeed = -0.5
            return cell
        }
    }
}
