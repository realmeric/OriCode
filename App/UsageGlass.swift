import SwiftUI

/// Left of send: a disc of the send button's tint that fills from the bottom as the plan's session
/// window goes, white while there's room and in kullanym-notch's amber and red as a limit nears.
/// Its rim is the same tint, so even a full one reads as a glass rather than a dot. Hovering opens
/// the card.
///
/// With Water on, it is a glass of water instead, and says nothing of the plan: its water stands
/// at today's water on this Mac against a usual day, and its card is the water alone. That is on
/// a thread whose agent has a water figure, which is Claude Code's, since water.json counts its
/// transcripts alone; on any other the circle and its card stay as they are.
struct UsageGlass: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?

    @AppStorage(TranscriptSettings.showWater) private var showWater = false
    @State private var shown = false
    @State private var overGlass = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        let ofWater = showWater && model.providerID(for: chat) == ProviderInfo.claudeID
        let periods = ofWater ? model.waterTotals.periods : nil
        let used = ofWater ? nil : model.usage?.headline?.used
        // Empty until the first reading, which it rises to.
        let level = ofWater ? periods?.level ?? 0 : min(max(used ?? 0, 0), 1)
        Group {
            if ofWater {
                WaterGlass(level: level, overflowing: periods?.overflowing ?? false)
                    .task { model.waterTotals.read() }
            } else {
                GlassLevel(level: level)
            }
        }
        .animation(Motion.reading, value: level)
        .opacity(!ofWater && model.usageStale ? 0.45 : 1)
        .padding(6)
        // Lit while its card is out, as the model button is while its picker is.
        .background(shown ? Surface.hover : .clear, in: .circle)
        .contentShape(.rect)
        .onHover { inside in
            overGlass = inside
            if inside, !ofWater { model.refreshUsage() }
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
        .accessibilityLabel(ofWater ? waterLabel(periods) : used.map { "Plan usage, \(Int(($0 * 100).rounded()))% of the session" } ?? "Plan usage")
    }

    private func waterLabel(_ periods: Water.Periods?) -> String {
        guard let periods else { return "Water today" }
        guard let usualDay = periods.usualDay else { return "Water today, ≈ \(periods.today.volume)" }
        return "Water today, ≈ \(periods.today.volume), \(Int((periods.today.ml / usualDay.ml * 100).rounded()))% of a usual day"
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
/// button's tint for the glass, a thicker foot, and water up to the level in one ink, not the
/// plan's bands, since a full glass is a usual day and no limit. Past a usual day it brims, the
/// water a shade brighter and as still. The surface ripples and settles when the level moves and
/// when the mouse arrives, and is still otherwise: between the two nothing is drawn again, and
/// with Reduce Motion it never ripples.
private struct WaterGlass: View {
    let level: Double
    let overflowing: Bool
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
                    .fill(overflowing ? Ink.primary : Ink.secondary)
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

/// Each window as a bar with when it rolls over, then this thread's context. From a glass of
/// water it is the water alone: the thread's and this Mac's by the calendar, and nothing of the
/// plan or the context.
struct UsageCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    let ofWater: Bool
    @State private var appeared = false

    enum Part: Hashable {
        case plan, context, waterByPeriod
    }

    /// What the card holds, top to bottom.
    static func parts(ofWater: Bool, context: Bool) -> [Part] {
        if ofWater { return [.waterByPeriod] }
        return [.plan] + (context ? [.context] : [])
    }

    var body: some View {
        let thread = chat.flatMap { model.conversations[$0.id]?.water.reading }
        let parts = Self.parts(ofWater: ofWater, context: (chat?.contextWindow ?? 0) > 0)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.element) { index, part in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
                switch part {
                case .plan: plan
                case .context:
                    if let chat {
                        ContextBar(used: chat.contextUsed, window: chat.contextWindow, appeared: appeared)
                            .animation(Motion.reading.delay(0.18), value: appeared)
                    }
                case .waterByPeriod:
                    WaterByPeriod(thread: thread, periods: model.waterTotals.periods)
                        .task { model.waterTotals.read() }
                }
            }
        }
        .padding(14)
        .frame(width: 270)
        .onAppear { appeared = true }
    }

    /// The agent and its plan, and each window as a bar.
    @ViewBuilder private var plan: some View {
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

/// The water in litres for the thread, today, this week and this month, then the usual day the
/// glass is full at, with the coefficient and its source's name under them. The thread's is its
/// session's; the calendar's are every Claude Code session on this Mac, counted by the same rule.
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
                Text(periods.usualDay.map { "The glass is full at a usual day, ≈ \($0.volume) over the \(Water.Periods.Bounds.usualDays) days before today." }
                    ?? "No water in the \(Water.Periods.Bounds.usualDays) days before today to go by, so today's fills the glass.")
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
