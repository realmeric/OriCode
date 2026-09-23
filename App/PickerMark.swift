import SwiftUI

/// Candidate B: OriCode's mark is the control. The dot is the main head: it grows and heats as
/// Claude thinks harder, white at Low and Claude's orange at Max. At Ultracode the six rays light
/// around it, the heads it runs on every task. Drag across the mark, use the arrows, or pick one
/// of the dots under the level's name.
struct MarkPicker: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var page = Page.effort

    enum Page { case effort, models }

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
        .frame(width: 320, height: page == .effort ? 300 : CGFloat(model.models.count) * 42 + 16)
        .animation(Motion.glide, value: page)
    }
}

private struct MarkPage: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let openModels: () -> Void
    /// The stop under a drag across the mark, shown before it's written.
    @State private var held: Int?
    @State private var dragFrom: Int?
    /// The stop under the pointer in the row of dots.
    @State private var hovered: Int?
    @State private var lastShown: Int?
    @State private var previewingReset = false
    @State private var resetTurns = 0
    @State private var blockedNote = false
    /// For a few seconds after a change the rays turn at Ultracode, then rest upright.
    @State private var live = false
    @State private var calming: Task<Void, Never>?
    /// Bumped as a level lands, for the dot's pop.
    @State private var pops = 0
    @FocusState private var focused: Bool
    @Namespace private var glide

    /// How far a drag goes for each level.
    private static let step: CGFloat = 26
    /// The extra a drag has to push past Max to reach Ultracode.
    private static let gate: CGFloat = 22

    private var state: PickerState { PickerState(model: model, chat: chat) }

    var body: some View {
        let state = state
        let stops = state.option?.stops ?? []
        let index = state.level.flatMap(stops.firstIndex(of:))
        let shown = held ?? index
        let level = shown.map { stops[$0] }
        VStack(spacing: 0) {
            header(state)
                .frame(height: 30)
            HeadMark(level: stops.isEmpty ? nil : level, live: live, pops: pops)
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .contentShape(.rect)
                .gesture(scrub(stops, index: index, blocked: blocked(state)))
                .accessibilityRepresentation {
                    Slider(value: Binding(get: { Double(index ?? 0) }, set: { choose(Int($0.rounded()), stops) }),
                           in: 0...Double(max(stops.count - 1, 1)), step: 1) {
                        Text("Effort")
                    }
                    .accessibilityValue(level.map(ModelMenu.effortName) ?? "Default")
                }
                .padding(.top, 4)
            title(state, level: level, shown: shown, stops: stops)
                .frame(height: 26)
            line(state, level: level, stops: stops)
                .frame(height: 16)
                .padding(.top, 2)
            if stops.count > 1 {
                dots(stops, shown: shown, home: state.home.flatMap(stops.firstIndex(of:)), blocked: blocked(state))
                    .frame(height: 18)
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
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            guard let index else { return .ignored }
            let up = press.key == .rightArrow
            if press.modifiers.contains(.option) { return go(up ? maxIndex(stops) : 0, stops) }
            // A held key stops at Max: Ultracode takes a press of its own.
            if press.phase == .repeat, up, stops.indices.contains(index + 1), stops[index + 1] == Effort.ultracode { return .handled }
            return go(index + (up ? 1 : -1), stops)
        }
        .onKeyPress(.delete) {
            withAnimation(Motion.move) { model.setEffort(nil, for: chat) }
            return .handled
        }
        .onKeyPress(.return) {
            model.modelPickerShown = false
            return .handled
        }
        .onChange(of: shown, initial: true) { old, now in
            lastShown = old ?? now
        }
        .onChange(of: state.effort) { wake() }
        .onAppear {
            focused = true
            wake()
        }
        .onDisappear { calming?.cancel() }
    }

    private func header(_ state: PickerState) -> some View {
        HStack(spacing: 0) {
            Group {
                if state.option?.fast == true {
                    FastButton(asked: state.fastAsked, state: state.fastState, dimmed: previewingReset && !model.threadDefaults.fast) {
                        model.setFast(!state.fastAsked, for: chat)
                    }
                } else {
                    Color.clear
                }
            }
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
                        withAnimation(Motion.move) { model.resetToDefaults(for: chat) }
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

    /// What the level does, or what a hovered dot would do; the cost of Max and Ultracode in the
    /// colour the usage circle has for the session.
    private func line(_ state: PickerState, level: String?, stops: [String]) -> some View {
        let previewed = hovered.map { stops[$0] }
        let words: (String, String?)
        if blockedNote {
            words = ("Needs dynamic workflows, see /config in Claude Code", nil)
        } else if let problem = state.fastProblem, previewed == nil {
            words = (problem, nil)
        } else if let missing = state.ultracodeMissing, previewed == nil {
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

    /// One dot per level, the chosen one drawn long, Default's ringed and Ultracode as the rays.
    private func dots(_ stops: [String], shown: Int?, home: Int?, blocked: Bool) -> some View {
        HStack(spacing: 12) {
            ForEach(stops.indices, id: \.self) { stop in
                let current = stop == shown
                ZStack {
                    if current {
                        Capsule()
                            .fill(stops[stop] == Effort.ultracode || EffortScale.spendsFaster(stops[stop]) ? Ink.claude : Ink.primary)
                            .frame(width: 18, height: 6)
                            .matchedGeometryEffect(id: "level", in: glide)
                    }
                    if stops[stop] == Effort.ultracode {
                        RaysMark(lit: RaysMark.rays, litOpacity: 1, dotOpacity: 1)
                            .frame(width: 10, height: 10)
                            .opacity(current ? 0 : blocked ? 0.18 : 0.45)
                    } else if !current {
                        if stop == home {
                            Circle()
                                .strokeBorder(Color.white.opacity(hovered == stop ? 0.8 : 0.5), lineWidth: 1.5)
                                .frame(width: 8, height: 8)
                        } else {
                            Circle()
                                .fill(Color.white.opacity(hovered == stop ? 0.6 : 0.28))
                                .frame(width: 5, height: 5)
                        }
                    }
                }
                .frame(width: 18, height: 18)
                .contentShape(.rect)
                .onTapGesture { _ = go(stop, stops) }
                .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovered = inside ? stop : (hovered == stop ? nil : hovered) } }
                .accessibilityHidden(true)
            }
        }
        .animation(Motion.move, value: shown)
    }

    /// Dragging across the mark walks the levels, a detent on the trackpad at each; the level is
    /// written when the finger lets go. Ultracode sits past a gate the drag has to push through.
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
                let was = held ?? from
                guard target != was else { return }
                if target > was, EffortScale.spendsFaster(stops[target]) {
                    Haptics.threshold()
                } else {
                    Haptics.detent()
                }
                withAnimation(.spring(duration: 0.3, bounce: 0.3)) { held = target }
            }
            .onEnded { _ in
                if let held, held != index { choose(held, stops) }
                held = nil
                dragFrom = nil
            }
    }

    private func go(_ stop: Int, _ stops: [String]) -> KeyPress.Result {
        guard stops.indices.contains(stop) else { return .ignored }
        if blocked(state), stops[stop] == Effort.ultracode {
            blockedNote = true
            Task {
                try? await Task.sleep(for: .seconds(3))
                blockedNote = false
            }
            return .handled
        }
        choose(stop, stops)
        return .handled
    }

    /// Landing where Default does is Default: the thread sends no level.
    private func choose(_ stop: Int, _ stops: [String]) {
        guard stops.indices.contains(stop) else { return }
        let level = stops[stop]
        withAnimation(.spring(duration: 0.3, bounce: 0.3)) {
            model.setEffort(level == state.home ? nil : level, for: chat)
        }
        pops += 1
    }

    private func maxIndex(_ stops: [String]) -> Int {
        stops.lastIndex { $0 != Effort.ultracode } ?? 0
    }

    private func blocked(_ state: PickerState) -> Bool {
        state.option.map { $0.ultraBlocked != nil && !$0.ultra } ?? false
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
/// faint until Ultracode lights all six.
private struct HeadMark: View {
    let level: String?
    let live: Bool
    let pops: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ultra = level == Effort.ultracode
        let heat = Heat(level)
        ZStack {
            RaysMark(lit: ultra ? RaysMark.rays : 0, turning: live && ultra && !reduceMotion, restingOpacity: 0.13, litOpacity: 0.9,
                     dotOpacity: 0, color: .white, stagger: true, layered: true, settles: true)
                .frame(width: 88, height: 88)
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
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: level)
    }

    /// How big the dot is and how hot it burns at a level.
    private struct Heat {
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
