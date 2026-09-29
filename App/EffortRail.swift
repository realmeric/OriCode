import SwiftUI

/// What each effort level says about itself, and how hot its part of the rail burns.
enum EffortScale {
    /// One line each, from Claude Code's own /effort wording. The clause after the dot under Max
    /// is what it costs, drawn in the session's usage band.
    static func line(_ level: String) -> (words: String, cost: String?) {
        switch level {
        case "none", "off": ("No reasoning, straight to the answer", nil)
        case "minimal": ("Barely any reasoning", nil)
        case "low": ("Quick, simple work", nil)
        case "medium": ("Balanced, with standard testing", nil)
        case "high": ("Thorough, with extensive testing", nil)
        case "xhigh": ("Extended reasoning, thorough analysis", nil)
        case "max": ("Deepest reasoning", "uses more of your plan")
        default: ("", nil)
        }
    }

    /// What workflows on do at a level, by whose they are: Claude Code's own, OriCode's on Rays, or
    /// Codex's ultra at Max, which Codex calls "Maximum reasoning with automatic task delegation".
    /// Short enough for the cost after it.
    static func workflows(at level: String?, on option: ModelOption?, agent: String) -> String {
        if agent == ProviderInfo.claudeID { return "Workflows on every task" }
        if option?.ultraRays != true, level == "max" { return "Max, delegating itself" }
        return "Workers on every task"
    }

    /// The one that spends the plan faster, and gets the heavier tap and the halo.
    static func spendsFaster(_ level: String) -> Bool {
        level == "max"
    }

    /// How a level burns. The fill is the agent's colour at full strength at every level, since
    /// thinned orange mixes with the glass behind it and reads brown; what rises with the level
    /// is how far back from the thumb it starts to pale (`core`), how far toward ember it gets
    /// there (`heat`), how white the thumb is (`white`), and how far its glow reaches.
    struct Burn {
        let core: CGFloat
        let heat: Double
        let white: Double
        let glow: Double
        let reach: CGFloat
    }

    static func burn(_ level: String) -> Burn {
        switch level {
        case "low": Burn(core: 0, heat: 0.06, white: 0.45, glow: 0.2, reach: 5)
        case "medium": Burn(core: 22, heat: 0.12, white: 0.5, glow: 0.26, reach: 6)
        case "high": Burn(core: 32, heat: 0.2, white: 0.56, glow: 0.32, reach: 7)
        case "xhigh": Burn(core: 44, heat: 0.3, white: 0.63, glow: 0.4, reach: 8)
        case "max": Burn(core: 56, heat: 0.4, white: 0.8, glow: 0.6, reach: 9)
        default: Burn(core: 0, heat: 0, white: 0.8, glow: 0, reach: 0)
        }
    }

    /// The fill at the thumb: the agent's colour paled toward its ember by the level's heat.
    static func hot(_ level: String, in ink: AgentInk) -> Color {
        ink.color.mix(with: ink.emberColor, by: burn(level).heat, in: .device)
    }
}

/// Effort as a rail with a stop for each level. Pressed, the thumb follows the pointer the way
/// EffortTrack says and the trackpad taps as it crosses a level; let go, it settles on a stop on
/// the app's spring, carrying the drag's speed, and only then is the thread's effort written.
/// The level Default lands on wears a ring with Default under it, and landing there is Default:
/// the thread sends no level and Claude Code picks the same one.
struct EffortRail: View {
    let stops: [String]
    /// Where Default lands; nil until the engine has read it.
    let home: String?
    /// The thread's agent's colour, which the fill, the lamps and the thumb's heat are drawn in.
    let ink: AgentInk
    /// The thread's choice; nil is Default.
    @Binding var effort: String?
    /// The level under the thumb while it's pressed, and the stop under the pointer, for the
    /// title and the line under the rail.
    @Binding var held: String?
    @Binding var hovered: String?
    var compact = false
    /// Where Back to Defaults would put the thumb, while the pointer is on it.
    var ghost: String?
    /// Bumped when a page that had the keyboard hands it back to the rail.
    var refocus = 0
    /// Return, which closes the picker.
    var onReturn: () -> Void = {}

    @State private var thumbX: CGFloat?
    @State private var heldStop: Int?
    /// Where on the thumb the press landed, so grabbing it doesn't make it jump.
    @State private var grab: CGFloat = 0
    @State private var poured = false
    /// Whether what moves in the fill is moving: for a few seconds after the picker opens or the
    /// level changes, then still, since a moving picker makes the window server redraw its blur
    /// every frame.
    @State private var live = false
    @State private var calming: Task<Void, Never>?
    @State private var bursts = 0
    @State private var wakes = 0
    @State private var arrival = EffortEffects.Arrival()
    /// Where a run of changes began, while one is going: a held key crossing three levels arrives
    /// once, at the last.
    @State private var runFrom: Int?
    @State private var running = false
    @State private var arriving: Task<Void, Never>?
    /// The change came from letting go of a drag, where the fill already followed the finger.
    @State private var dragged = false
    /// Bumped for each stop a drag crosses, and each fall, for the bead's pulse and dip.
    @State private var crossings = 0
    @State private var falls = 0
    @State private var keyed = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let row: CGFloat = 32
    static let rail: CGFloat = 24
    static let thumb: CGFloat = 32
    /// How much fill shows left of the thumb at the lowest level, so Low reads as lit too.
    static let cap: CGFloat = 13

    var height: CGFloat { compact ? Self.row : Self.row + 16 }

    private var index: Int? { (effort ?? home).flatMap(stops.firstIndex(of:)) }
    private var homeIndex: Int? { home.flatMap(stops.firstIndex(of:)) }

    var body: some View {
        GeometryReader { geometry in
            let track = EffortTrack(levels: stops, start: Self.thumb / 2 + Self.cap, end: geometry.size.width - Self.thumb / 2)
            let xs = track.positions
            let stop = heldStop ?? index
            let centre = thumbX ?? stop.map { xs[$0] } ?? track.start
            let level = stop.map { stops[$0] } ?? ""
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Surface.selected)
                    .frame(height: Self.rail)
                    .offset(y: (Self.row - Self.rail) / 2)
                fill(level: level, width: stop == nil || !poured ? 0 : centre)
                    .offset(y: (Self.row - Self.rail) / 2)
                if stop != nil, !reduceMotion {
                    // The whole rail, reaching past its last stop and above and below it for what's
                    // thrown off, placed rather than framed so the rail's hit area doesn't grow.
                    let width = geometry.size.width - Self.thumb / 2 + EffortEffects.reach
                    EffortEffects(level: level, ink: ink, live: live, bursts: bursts, wakes: wakes, thumb: centre, landing: centre,
                                  positions: xs, index: stop, arrival: arrival, compact: compact)
                        .frame(width: width, height: Self.rail + 2 * EffortEffects.air)
                        .position(x: width / 2, y: Self.row / 2)
                        .allowsHitTesting(false)
                }
                ForEach(stops.indices, id: \.self) { mark in
                    // The pour lights the stops it passes on the way to the thumb.
                    stopMark(mark, onFill: stop != nil && poured && xs[mark] <= centre)
                        .animation(.easeOut(duration: 0.14).delay(0.05 + 0.4 * xs[mark] / max(centre, 1)), value: poured)
                        .position(x: xs[mark], y: Self.row / 2)
                }
                if let ghost, let at = stops.firstIndex(of: ghost), at != stop {
                    Circle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: Self.thumb, height: Self.thumb)
                        .position(x: xs[at], y: Self.row / 2)
                        .transition(.opacity.animation(Motion.fade))
                }
                if !compact, let homeIndex {
                    Text("Default")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(onDefault ? Ink.primary : Ink.faint)
                        .fixedSize()
                        // Kept inside the row when the ring is an end stop.
                        .position(x: min(max(xs[homeIndex], 22), geometry.size.width - 22), y: Self.row + 9)
                        .onTapGesture { withAnimation(Motion.move) { effort = nil } }
                        .accessibilityHidden(true)
                }
                if stop != nil {
                    thumb(level: level, holding: thumbX != nil)
                        .position(x: centre, y: Self.row / 2)
                        .transition(.opacity)
                }
            }
            .contentShape(.rect)
            .gesture(drag(track))
            .onContinuousHover { phase in
                guard thumbX == nil else { return }
                if case .active(let point) = phase, point.y < Self.row + 4 {
                    hovered = stops[track.nearest(point.x)]
                } else {
                    hovered = nil
                }
            }
        }
        .frame(height: height)
        .animation(Motion.fade, value: hovered)
        .animation(Motion.reading, value: home)
        .focusable()
        .focused($focused)
        .focusEffectDisabled(!keyed)
        .contentShape(.focusEffect, .capsule)
        .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
            keyed = true
            let up = press.key == .rightArrow
            if press.modifiers.contains(.option) { return go(up ? stops.count - 1 : 0) }
            return step(up ? 1 : -1)
        }
        .onKeyPress(.home) {
            keyed = true
            return go(0)
        }
        .onKeyPress(.end) {
            keyed = true
            return go(stops.count - 1)
        }
        // ⌫ back to Default. Backspace reaches a focused view as the Delete command, never as a key
        // press, the way it does in the review.
        .onDeleteCommand {
            keyed = true
            withAnimation(Motion.move) { effort = nil }
        }
        .onKeyPress(.return) {
            onReturn()
            return .handled
        }
        // VoiceOver and Full Keyboard Access meet a native slider over the same stops.
        .accessibilityRepresentation {
            Slider(value: Binding(get: { Double(index ?? 0) }, set: { _ = go(Int($0.rounded())) }),
                   in: 0...Double(max(stops.count - 1, 1)), step: 1) {
                Text("Effort")
            }
            .accessibilityValue(spoken)
        }
        .onAppear {
            focused = true
            if reduceMotion {
                poured = true
            } else {
                withAnimation(Motion.glide.delay(0.05)) { poured = true }
            }
            Task {
                // The fill pours in first; what moves in it starts once it's there.
                try? await Task.sleep(for: .milliseconds(350))
                wake()
            }
        }
        .onChange(of: refocus) { focused = true }
        .onChange(of: effort) { old, new in
            wake()
            let from = (old ?? home).flatMap(stops.firstIndex(of:))
            if let from, let to = (new ?? home).flatMap(stops.firstIndex(of:)), to < from { falls += 1 }
            arrive(from: from)
        }
        .onChange(of: hovered) { _, now in
            // A pointer moving along the rail at the top of the scale keeps the heat up; one left
            // still lets it rest.
            if now != nil, let index, EffortScale.spendsFaster(stops[index]) { stoke() }
        }
        .onDisappear { calming?.cancel() }
    }

    /// Wakes what moves in the fill for a change, with the slugs sent again.
    private func wake() {
        wakes += 1
        stoke()
    }

    /// Tells EffortEffects the thumb has come to rest, once a run of changes has stopped for 180ms,
    /// with the stop the run began from.
    private func arrive(from: Int?) {
        if !running {
            runFrom = from
            running = true
        }
        arriving?.cancel()
        arriving = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            arrival = EffortEffects.Arrival(count: arrival.count + 1, from: runFrom, dragged: dragged)
            running = false
            dragged = false
        }
    }

    private func stoke() {
        calming?.cancel()
        live = true
        calming = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { live = false }
        }
    }

    private var onDefault: Bool {
        guard let heldStop else { return effort == nil }
        return stops[heldStop] == home
    }

    private var spoken: String {
        guard let index else { return "Default" }
        let level = stops[index]
        return ModelMenu.effortName(level) + (effort == nil ? ", default" : "")
    }

    /// The agent's colour, since effort is how hard it thinks, lit like a tube: full strength
    /// at every level, paling toward ember over a stretch before the thumb that grows with the
    /// level, brighter along its top and shaded along its bottom, with a line of light under the
    /// top edge like the composer's. Its colours move with the thumb's own spring.
    private func fill(level: String, width: CGFloat) -> some View {
        let burn = EffortScale.burn(level)
        let stops: [Gradient.Stop] = [
            .init(color: ink.color, location: 0),
            .init(color: ink.color, location: width > 0 ? max(0, 1 - burn.core / width) : 1),
            .init(color: EffortScale.hot(level, in: ink), location: 1),
        ]
        let edge = width > 16 ? min(0.5, 10 / (width - 16)) : 0.5
        return Capsule()
            .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
            .overlay {
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .white.opacity(0.14), location: 0), .init(color: .clear, location: 0.45),
                                                 .init(color: .black.opacity(0.12), location: 1)],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.28), location: edge),
                                                 .init(color: .white.opacity(0.28), location: 1 - edge), .init(color: .clear, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
            }
            .frame(width: width, height: Self.rail)
    }

    @ViewBuilder
    private func stopMark(_ mark: Int, onFill: Bool) -> some View {
        let hover = stops[mark] == hovered && thumbX == nil
        if mark == homeIndex {
            Circle()
                .strokeBorder(onFill ? ink.emberColor.opacity(0.9) : Color.white.opacity(0.5), lineWidth: 1.5)
                .frame(width: hover ? 11 : 9, height: hover ? 11 : 9)
                .shadow(color: ink.emberColor.opacity(onFill ? 0.8 : 0), radius: 2)
        } else {
            // A stop the fill has passed is a lamp, lit ember; one ahead of it is a faint point.
            Circle()
                .fill(onFill ? ink.emberColor.opacity(0.9) : Color.white.opacity(0.24))
                .frame(width: hover ? 6 : onFill ? 4.5 : 4, height: hover ? 6 : onFill ? 4.5 : 4)
                .shadow(color: ink.emberColor.opacity(onFill ? 0.9 : 0), radius: 2)
        }
    }

    /// The part you hold: a bead of the rail's own heat carrying OriCode's dot, the main head.
    private func thumb(level: String, holding: Bool) -> some View {
        let burn = EffortScale.burn(level)
        let hot = EffortScale.hot(level, in: ink)
        // Lit from below by the level's heat: pale at the top, warm at the bottom, and white only
        // where the top of the scale earns it. No highlight spot: round a black dot it reads as an eye.
        let body = LinearGradient(stops: [
            .init(color: hot.mix(with: .white, by: burn.white + (1 - burn.white) * 0.75, in: .device), location: 0),
            .init(color: hot.mix(with: .white, by: burn.white + (1 - burn.white) * 0.56, in: .device), location: 0.45),
            .init(color: hot.mix(with: .white, by: burn.white, in: .device), location: 1),
        ], startPoint: .top, endPoint: .bottom)
        return ZStack {
            // Frosted glass the fill shows through, warmed a little by the level's heat.
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .fill(body.opacity(0.55))
            Circle()
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                              lineWidth: 1)
            Circle()
                .fill(Color.black.opacity(0.85))
                .frame(width: 8, height: 8)
        }
        .frame(width: Self.thumb, height: Self.thumb)
        .shadow(color: .black.opacity(0.3), radius: holding ? 7 : 4, y: 1.5)
        // A glow that reaches further at each level, widest at Max.
        .shadow(color: ink.color.opacity(burn.glow + (holding ? 0.06 : 0)), radius: burn.reach + (holding ? 1 : 0))
        .scaleEffect(holding ? 1.08 : 1)
        .animation(Motion.move, value: holding)
        // A pulse for each stop a drag crosses, in step with the trackpad's tap, and a dip as a
        // fall lets the heat out.
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : crossings) { bead, scale in
            bead.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(1.05, duration: 0.08)
            CubicKeyframe(1, duration: 0.12)
        }
        .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : falls) { bead, scale in
            bead.scaleEffect(scale)
        } keyframes: { _ in
            CubicKeyframe(0.95, duration: 0.12)
            CubicKeyframe(1, duration: 0.18)
        }
    }

    private func drag(_ track: EffortTrack) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let xs = track.positions
                let was = heldStop ?? index
                if thumbX == nil {
                    // A press on the thumb takes it where it was hit; anywhere else, the thumb
                    // springs to the pointer and follows from there.
                    let centre = was.map { xs[$0] } ?? track.start
                    grab = abs(drag.startLocation.x - centre) <= Self.thumb / 2 ? centre - drag.startLocation.x : 0
                }
                let (x, stop) = track.follow(drag.location.x + grab)
                if thumbX == nil {
                    withAnimation(Motion.move) { thumbX = x }
                } else {
                    var still = Transaction()
                    still.disablesAnimations = true
                    withTransaction(still) { thumbX = x }
                }
                if stop != was, abs(drag.translation.width) >= 3 {
                    crossings += 1
                    let rising = stop > (was ?? -1)
                    if rising, EffortScale.spendsFaster(stops[stop]) {
                        Haptics.threshold()
                        bursts += 1
                        // The arrival's heat runs from here, not from the release.
                        wake()
                    } else {
                        Haptics.detent()
                    }
                }
                heldStop = stop
                held = stops[stop]
                hovered = nil
            }
            .onEnded { drag in
                let holding = heldStop ?? index ?? 0
                let clicked = abs(drag.translation.width) < 3
                let target = clicked ? holding : track.settle(drag.location.x + grab, velocity: drag.velocity.width, holding: holding)
                if clicked, target > (index ?? -1), EffortScale.spendsFaster(stops[target]) {
                    bursts += 1
                    wake()
                }
                let xs = track.positions
                let distance = xs[target] - (thumbX ?? xs[target])
                // The drag's speed, as a share of the way left, starts the spring; the rail's own
                // implicit animations mustn't replace it.
                let push = abs(distance) < 1 ? 0 : max(min(drag.velocity.width / distance, 8), -8)
                var settle = Transaction(animation: reduceMotion ? Motion.fade : .interpolatingSpring(duration: 0.28, bounce: 0.12, initialVelocity: push))
                settle.disablesAnimations = true
                dragged = !clicked
                withTransaction(settle) {
                    thumbX = nil
                    heldStop = nil
                    if target != index { choose(target) }
                }
                held = nil
                grab = 0
            }
    }

    private func choose(_ stop: Int) {
        let level = stops[stop]
        effort = level == home ? nil : level
    }

    private func step(_ by: Int) -> KeyPress.Result {
        go((index ?? (by > 0 ? -1 : stops.count)) + by)
    }

    private func go(_ stop: Int) -> KeyPress.Result {
        guard stops.indices.contains(stop) else { return .ignored }
        // A key that lands on the top of the scale arrives there as a drag does, without the tap.
        if stop > (index ?? -1), EffortScale.spendsFaster(stops[stop]) {
            bursts += 1
            wake()
        }
        withAnimation(Motion.move) { choose(stop) }
        return .handled
    }
}

/// Equal when everything it draws from is. Its bindings and actions are closures made anew each
/// time the page draws, so without this every change of rays ran the hidden rail's body again.
extension EffortRail: @MainActor Equatable {
    static func == (a: EffortRail, b: EffortRail) -> Bool {
        a.stops == b.stops && a.home == b.home && a.ink == b.ink && a.effort == b.effort && a.held == b.held
            && a.hovered == b.hovered && a.compact == b.compact && a.ghost == b.ghost && a.refocus == b.refocus
    }
}
