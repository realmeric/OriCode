import SwiftUI

/// Left of send: how much of the plan's session window is gone, in kullanym-notch's bands,
/// with a thin white arc turning inside while the thread works. Hovering opens the card.
struct UsageCircle: View {
    @Environment(AppModel.self) private var model
    let running: Bool
    let chat: Chat?

    @State private var shown = false
    @State private var overCircle = false
    @State private var overCard = false
    @State private var pending: Task<Void, Never>?

    private let diameter: CGFloat = 22
    private let stroke: CGFloat = 2.5

    var body: some View {
        let used = model.usage?.headline?.used
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: stroke)
            if let used {
                Circle()
                    .trim(from: 0, to: min(max(used, 0), 1))
                    .stroke(Band.of(used).color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(Motion.reading, value: used)
            }
            if running {
                WorkingArc()
                    .frame(width: diameter - stroke * 2 - 5, height: diameter - stroke * 2 - 5)
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(model.usageStale ? 0.45 : 1)
        .padding(5)
        .contentShape(.rect)
        .onHover { inside in
            overCircle = inside
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
    /// card; closes a moment after it has left both the circle and the card.
    private func settle() {
        pending?.cancel()
        let wanted = overCircle || overCard
        guard wanted != shown else { return }
        pending = Task {
            try? await Task.sleep(for: .milliseconds(wanted ? 250 : 300))
            guard !Task.isCancelled, (overCircle || overCard) == wanted else { return }
            shown = wanted
        }
    }
}

/// kullanym-notch's activity arc: a quarter of a circle turning once every 1.1 seconds. Core
/// Animation turns it in the render server, so it costs the app nothing per frame; drawn from a
/// TimelineView it made SwiftUI lay the whole window out again on every frame, about a tenth of
/// a core for as long as a turn ran.
private struct WorkingArc: NSViewRepresentable {
    func makeNSView(context: Context) -> ArcView { ArcView() }

    func updateNSView(_ view: ArcView, context: Context) {}

    final class ArcView: NSView {
        private let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
            arc.lineWidth = 1.6
            arc.lineCap = .round
            layer?.addSublayer(arc)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            // Clockwise: a layer's y axis points up, so that's the negative direction.
            turn.toValue = -2 * Double.pi
            turn.duration = 1.1
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            arc.add(turn, forKey: "turn")
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            // From twelve o'clock to three, a quarter of the circle.
            let radius = min(bounds.width, bounds.height) / 2 - arc.lineWidth / 2
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                        startAngle: .pi / 2, endAngle: 0, clockwise: true)
            arc.path = path
            CATransaction.commit()
        }
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
