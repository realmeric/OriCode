import SwiftUI

/// Left of send: how much of the plan's session window is gone, white while there's room and in
/// kullanym-notch's amber and red as a limit nears. Hovering opens the card.
struct UsageGauge: View {
    @Environment(AppModel.self) private var model
    @AppStorage(UsageLook.key) private var look = UsageLook.words
    let chat: Chat?

    @State private var shown = false
    @State private var overGauge = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    var body: some View {
        let used = model.usage?.headline?.used
        Group {
            switch look {
            case .words: UsageWords(used: used)
            case .glass: UsageGlass(used: used)
            case .meter: UsageMeter(used: used)
            }
        }
        .animation(Motion.reading, value: used)
        .opacity(model.usageStale ? 0.45 : 1)
        .frame(height: 30)
        // Lit while its card is out, as the model button is while its picker is.
        .background(shown ? Surface.hover : .clear, in: .capsule)
        .contentShape(.rect)
        .onHover { inside in
            overGauge = inside
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
    /// card; closes a moment after it has left both the gauge and the card.
    private func settle() {
        pending?.cancel()
        let wanted = overGauge || overCard
        guard wanted != shown else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 250 : 300))
            guard !Task.isCancelled, (overGauge || overCard) == wanted else { return }
            shown = wanted
        }
    }
}

/// How the composer shows plan usage, three ways until Meriç keeps one: the percentage in words,
/// a glass that fills, or the card's bar in small. Thread › Usage Look.
enum UsageLook: String, CaseIterable, Identifiable {
    case words, glass, meter

    static let key = "usageLook"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .words: "A · Words"
        case .glass: "B · Glass"
        case .meter: "C · Meter"
        }
    }
}

/// The session's share in the composer's type, faint the way a Default level is until a limit
/// is near. With no reading yet it takes no room.
private struct UsageWords: View {
    let used: Double?

    var body: some View {
        if let used {
            Text("\(Int((used * 100).rounded()))%")
                .font(Type.secondary.monospacedDigit())
                .foregroundStyle(Band.of(used) == .ample ? Ink.faint : Band.of(used).color)
                .contentTransition(.numericText(value: used))
                .padding(.horizontal, 8)
        }
    }
}

/// A disc of the send button's tint that fills from the bottom as the session goes, inside a rim
/// of that tint, so even a full one reads as a glass rather than a dot.
private struct UsageGlass: View {
    let used: Double?
    private let side: CGFloat = 18
    private let rim: CGFloat = 2

    var body: some View {
        let inner = side - rim * 2
        ZStack {
            Circle().fill(Surface.selected)
            if let used {
                let level = min(max(used, 0), 1)
                Rectangle()
                    .fill(Band.of(used).color)
                    // A sliver at least, so a live 1% is visible.
                    .frame(height: level > 0 ? max(1.5, inner * level) : 0)
                    .frame(width: inner, height: inner, alignment: .bottom)
                    .clipShape(.circle)
            }
        }
        .frame(width: side, height: side)
        .padding(6)
    }
}

/// The card's session bar in small.
private struct UsageMeter: View {
    let used: Double?

    var body: some View {
        Bar(fraction: used ?? 0, color: used.map { Band.of($0).color } ?? .clear)
            .frame(width: 24)
            .padding(.horizontal, 8)
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
                Text(model.usageLoading ? "Asking Claude…" : "Usage isn't available right now.")
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
