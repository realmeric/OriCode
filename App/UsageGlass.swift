import SwiftUI

/// Left of send: a disc of the send button's tint that fills from the bottom as the plan's session
/// window goes, white while there's room and in kullanym-notch's amber and red as a limit nears.
/// Its rim is the same tint, so even a full one reads as a glass rather than a dot. Hovering opens
/// the card.
struct UsageGlass: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?

    @State private var shown = false
    @State private var overGlass = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        let used = model.usage?.headline?.used
        // Empty until the first reading, which it rises to.
        let level = min(max(used ?? 0, 0), 1)
        GlassLevel(level: level)
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
            UsageCard(chat: chat)
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

/// Each window as a bar with when it rolls over, then this thread's context.
private struct UsageCard: View {
    @Environment(AppModel.self) private var model
    let chat: Chat?
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ClaudeMark().frame(width: 14, height: 14)
                Text("Claude").font(Type.body.weight(.semibold)).foregroundStyle(Ink.primary)
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
