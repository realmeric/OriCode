import SwiftUI

/// Left of send: a disc of the send button's tint that fills from the bottom as the plan's session
/// window goes, white while there's room and in kullanym-notch's amber and red as a limit nears.
/// Its rim is the same tint, so even a full one reads as a glass rather than a dot. Hovering opens
/// the card. With Water and A glass of water on, on a thread of Claude Code's, it is a glass of
/// water at the same level, since water.json counts Claude Code's transcripts alone.
struct UsageGlass: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?

    @AppStorage(TranscriptSettings.showWater) private var showWater = false
    @AppStorage(TranscriptSettings.waterGlass) private var waterGlass = false
    @State private var shown = false
    @State private var overGlass = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        let used = model.usage?.headline?.used
        // Empty until the first reading, which it rises to.
        let level = min(max(used ?? 0, 0), 1)
        let ofWater = showWater && waterGlass && model.providerID(for: chat) == ProviderInfo.claudeID
        Group {
            if ofWater { WaterGlass(level: level) } else { GlassLevel(level: level) }
        }
        .animation(Motion.reading, value: level)
        .opacity(model.usageStale ? 0.45 : 1)
        .padding(6)
        // Lit while its card is out, as the model button is while its picker is.
        .background(shown ? Surface.hover : .clear, in: .circle)
        .contentShape(.rect)
        .onHover { inside in
            overGlass = inside
            if inside { model.refreshUsage() }
            settle()
        }
        .popover(isPresented: $shown, arrowEdge: .top) {
            UsageCard(chat: chat, ofWater: ofWater)
                .onHover { inside in
                    overCard = inside
                    settle()
                }
        }
        .accessibilityElement()
        .accessibilityLabel(used.map { "Plan usage, \(Int(($0 * 100).rounded()))% of the session" } ?? "Plan usage")
    }

    /// Opens a quarter second after the mouse arrives, so passing over it doesn't flash a
    /// card; closes a moment after it has left both the glass and the card.
    private func settle() {
        pending?.cancel()
        let wanted = overGlass || overCard
        guard wanted != shown else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 250 : 300))
            guard !Task.isCancelled, (overGlass || overCard) == wanted else { return }
            shown = wanted
        }
    }
}

/// The glass itself, a disc of the send button's tint inside a rim of it, filled from the bottom
/// in the band's colour: 18pt in the composer, larger on a limit's card. A plan's tally fills it
/// in one ink, since there a full glass is good news.
struct GlassLevel: View {
    let level: Double
    var side: CGFloat = 18
    var fill: Color?

    var body: some View {
        let inner = side - side / 9 * 2
        ZStack {
            Circle().fill(Surface.selected)
            Rectangle()
                .fill(fill ?? Band.of(level).color)
                // A sliver at least, so a live 1% is visible.
                .frame(height: level > 0 ? max(1.5, inner * level) : 0)
                .frame(width: inner, height: inner, alignment: .bottom)
                .clipShape(.circle)
        }
        .frame(width: side, height: side)
    }
}

/// The glass as a tumbler of water, a little taller than wide in the disc's place: the send
/// button's tint for the glass, a thicker foot, and water in the band's colour up to the level.
/// The surface ripples and settles when the level moves and when the mouse arrives, and is
/// still otherwise: between the two nothing is drawn again, and with Reduce Motion it never
/// ripples.
private struct WaterGlass: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stirs = 0

    private static let size = CGSize(width: 13, height: 17)
    private static let wall: CGFloat = 1.5
    private static let foot: CGFloat = 2.5

    var body: some View {
        let tumbler = Tumbler()
        let water = Tumbler(sides: Self.wall, bottom: Self.foot)
        KeyframeAnimator(initialValue: Ripple(), trigger: reduceMotion ? 0 : stirs) { ripple in
            ZStack {
                tumbler.fill(Surface.selected)
                WaterLevel(level: level, ripple: ripple)
                    .fill(Band.of(level).color)
                    .clipShape(water)
            }
        } keyframes: { _ in
            KeyframeTrack(\.height) {
                CubicKeyframe(1.2, duration: 0.25)
                CubicKeyframe(0, duration: 1.4)
            }
            KeyframeTrack(\.phase) {
                // Still at the start, so the jump back doesn't show.
                MoveKeyframe(0)
                LinearKeyframe(.pi * 5, duration: 1.65)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .frame(width: 18, height: 18)
        .onChange(of: level) { stirs += 1 }
        .onHover { inside in if inside { stirs += 1 } }
    }

    private struct Ripple {
        /// How far the surface rises and falls, in points.
        var height = 0.0
        var phase = 0.0
    }

    /// Open at the top and narrower at the foot, whose corners are round; inset by the glass's
    /// wall and foot, the water inside it.
    private struct Tumbler: Shape {
        var sides: CGFloat = 0
        var bottom: CGFloat = 0

        func path(in rect: CGRect) -> Path {
            let rect = CGRect(x: rect.minX + sides, y: rect.minY, width: rect.width - sides * 2, height: rect.height - bottom)
            let taper = rect.width * 0.12
            let foot = CGPoint(x: rect.maxX - taper, y: rect.maxY)
            let heel = CGPoint(x: rect.minX + taper, y: rect.maxY)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addArc(tangent1End: foot, tangent2End: heel, radius: rect.width * 0.2)
            path.addArc(tangent1End: heel, tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: rect.width * 0.2)
            path.closeSubpath()
            return path
        }
    }

    /// The water up to the level, its surface a wave of the ripple's height. Only the level
    /// animates by itself; the ripple comes from the keyframes.
    private struct WaterLevel: Shape {
        var level: Double
        let ripple: Ripple

        var animatableData: Double {
            get { level }
            set { level = newValue }
        }

        private static let steps = 12

        func path(in rect: CGRect) -> Path {
            guard level > 0 else { return Path() }
            // A sliver at least, so a live 1% is visible.
            let top = rect.maxY - WaterGlass.foot - max(1.5, (rect.height - WaterGlass.foot) * level)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            for step in 0...Self.steps {
                let along = Double(step) / Double(Self.steps)
                path.addLine(to: CGPoint(x: rect.minX + rect.width * along, y: top + ripple.height * sin(.pi * 2 * along + ripple.phase)))
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }
}

/// Each window as a bar with when it rolls over, then this thread's context, and its water when
/// Settings asks for that: the thread's, and from a glass of water this Mac's by the calendar too.
struct UsageCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let ofWater: Bool
    @State private var appeared = false
    @AppStorage(TranscriptSettings.showWater) private var showWater = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AgentMark(agent: model.providerID(for: chat)).frame(width: 14, height: 14)
                Text(model.agent(for: chat).agent).font(Type.body.weight(.semibold)).foregroundStyle(Ink.primary)
                if let plan = model.usage?.plan {
                    Text(plan.capitalized).font(Type.secondary).foregroundStyle(Ink.secondary)
                }
                Spacer(minLength: 8)
                if model.usageStale, let at = model.usageAt {
                    Text("as of \(ResetCopy.span(Date.now.timeIntervalSince(at))) ago")
                        .font(Type.secondary).foregroundStyle(Ink.faint)
                }
            }
            if let usage = model.usage {
                if usage.available {
                    ForEach(Array(usage.windows.enumerated()), id: \.element.id) { index, window in
                        WindowBar(window: window, appeared: appeared)
                            .animation(Motion.reading.delay(min(Double(index) * 0.045, 0.18)), value: appeared)
                    }
                } else {
                    Text("Plan limits don't apply to this login.")
                        .font(Type.secondary).foregroundStyle(Ink.secondary)
                }
            } else {
                Text(model.usageLoading ? "Checking usage…" : "Usage isn't available right now.")
                    .font(Type.secondary).foregroundStyle(Ink.secondary)
            }
            if let chat, chat.contextWindow > 0 {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                ContextBar(used: chat.contextUsed, window: chat.contextWindow, appeared: appeared)
                    .animation(Motion.reading.delay(0.18), value: appeared)
            }
            let thread = chat.flatMap { model.conversations[$0.id]?.water.reading }
            if ofWater {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                WaterByPeriod(thread: thread, periods: model.waterTotals.periods)
                    .task { model.waterTotals.read() }
            } else if showWater, let thread {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                WaterLines(water: thread)
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { appeared = true }
    }
}

private struct WindowBar: View {
    let window: PlanUsage.Window
    let appeared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                if let resetsAt = window.resetsAt {
                    Text(ResetCopy.text(for: resetsAt)).foregroundStyle(Ink.secondary)
                }
            }
            .font(Type.secondary)
            if let used = window.used {
                Bar(fraction: appeared ? used : 0, color: Band.of(used).color)
                Text("\(Int((used * 100).rounded()))% used")
                    .font(Type.secondary).foregroundStyle(Ink.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct ContextBar: View {
    let used: Int
    let window: Int
    let appeared: Bool

    var body: some View {
        let fraction = min(1, Double(used) / Double(window))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This thread").foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                Text("\(used.formatted(.number.notation(.compactName))) of \(window.formatted(.number.notation(.compactName)))")
                    .foregroundStyle(Ink.secondary)
            }
            .font(Type.secondary)
            Bar(fraction: appeared ? fraction : 0, color: Ink.secondary)
            Text("of its context in use").font(Type.secondary).foregroundStyle(Ink.secondary)
        }
    }
}

/// The thread's water once more, with what the footer leaves out: the glasses, the coefficient
/// and the source it comes from by name.
private struct WaterLines: View {
    let water: Water.Reading

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Water").foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                Text("≈ \(water.volume), estimated").foregroundStyle(Ink.secondary)
            }
            Text((water.hasGlasses ? "\(water.glasses) glasses of \(water.glassMl), at " : "At ") + water.coefficient)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(water.source)
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Type.secondary)
    }
}

/// The water in litres for the thread, today, this week and this month, with the coefficient and
/// its source's name under them. The thread's is its session's; the calendar's are every Claude
/// Code session on this Mac, counted by the same rule.
private struct WaterByPeriod: View {
    let thread: Water.Reading?
    /// Nil until the first reading of the month's transcripts comes back.
    let periods: Water.Periods?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Water").foregroundStyle(Ink.primary)
                Spacer(minLength: 8)
                Text("estimated").foregroundStyle(Ink.secondary)
            }
            if let thread { row("This thread", thread) }
            if let periods {
                row("Today", periods.today)
                row("This week", periods.week)
                row("This month", periods.month)
            } else {
                Text("Counting this Mac's sessions…").foregroundStyle(Ink.secondary)
            }
            if let figure = periods?.month ?? thread {
                Text("Today, this week and this month: every Claude Code session on this Mac, at \(figure.coefficient).")
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(figure.source)
                    .foregroundStyle(Ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Type.secondary)
    }

    private func row(_ label: String, _ water: Water.Reading) -> some View {
        HStack {
            Text(label).foregroundStyle(Ink.secondary)
            Spacer(minLength: 8)
            Text("≈ \(water.volume)").monospacedDigit().foregroundStyle(Ink.primary)
                .contentTransition(.numericText())
        }
    }
}

private struct Bar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                // A sliver at least, so a live 1% is visible.
                Capsule().fill(color).frame(width: max(fraction > 0 ? 4 : 0, proxy.size.width * min(fraction, 1)))
            }
        }
        .frame(height: 4)
    }
}
