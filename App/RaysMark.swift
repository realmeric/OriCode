import SwiftUI

/// Meriç's mark: a dot inside six arcs. The arcs are rays, and a lit ray is a head
/// running in the thread, the main loop first and then each subagent, lit clockwise
/// from twelve o'clock.
struct RaysMark: View {
    static let rays = 6

    /// How many rays are lit, clamped to the six there are.
    var lit = 0
    /// Turns slowly while work is running, so a lit mark also reads as moving.
    var turning = false
    /// Pulses the dot: the thread is waiting on you.
    var waiting = false
    var restingOpacity = 0.3
    var litOpacity = 0.92
    var dotOpacity = 0.92

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                if turning {
                    TimelineView(.animation) { context in
                        rays(side: side).rotationEffect(.degrees(angle(at: context.date)))
                    }
                } else {
                    rays(side: side)
                }
                Dot(waiting: waiting, opacity: dotOpacity)
                    .frame(width: side * 0.3, height: side * 0.3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel(lit == 0 ? "Idle" : "\(lit) running")
    }

    private func rays(side: CGFloat) -> some View {
        let width = max(1.2, side * 0.085)
        return ZStack {
            ForEach(0..<Self.rays, id: \.self) { index in
                Ray(index: index, count: Self.rays)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .opacity(index < min(lit, Self.rays) ? litOpacity : restingOpacity)
                    .padding(width / 2)
                    .animation(.spring(response: 0.9, dampingFraction: 0.9), value: lit)
            }
        }
    }

    /// One turn every nine seconds: slow enough to read as breathing rather than loading.
    private func angle(at date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate / 9).truncatingRemainder(dividingBy: 1) * 360
    }
}

/// One of the arcs, centred on its sixth of the circle with a gap either side.
struct Ray: Shape {
    let index: Int
    let count: Int
    var gap: Double = 22

    func path(in rect: CGRect) -> Path {
        let share = 360 / Double(count)
        let middle = -90 + Double(index) * share
        let half = (share - gap) / 2
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(middle - half),
            endAngle: .degrees(middle + half),
            clockwise: false)
        return path
    }
}

/// Driven by the clock rather than a repeating animation, which keeps going after its
/// value is set back; derived from the time, the pulse simply stops being drawn.
private struct Dot: View {
    let waiting: Bool
    let opacity: Double

    var body: some View {
        if waiting {
            TimelineView(.animation) { context in
                Circle().fill(Color.white).opacity(opacity * pulse(at: context.date))
            }
        } else {
            Circle().fill(Color.white).opacity(opacity)
        }
    }

    private func pulse(at date: Date) -> Double {
        let phase = (date.timeIntervalSinceReferenceDate / 1.8).truncatingRemainder(dividingBy: 1)
        return 0.35 + 0.65 * (0.5 + 0.5 * cos(phase * 2 * .pi))
    }
}
