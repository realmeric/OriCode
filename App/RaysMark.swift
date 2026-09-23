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
    /// White on the glass; the effort thumb draws it dark on its white disc.
    var color = Color.white
    /// Rays that light come up one after another, clockwise, instead of together.
    var stagger = false
    /// Drawn as layers even while still, so a turn that stops stops where it is.
    var layered = false

    var body: some View {
        Group {
            if turning || waiting || layered {
                MovingRays(lit: min(lit, Self.rays), turning: turning, waiting: waiting,
                           restingOpacity: restingOpacity, litOpacity: litOpacity, dotOpacity: dotOpacity,
                           color: NSColor(color), stagger: stagger)
            } else {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    ZStack {
                        rays(side: side)
                        Circle().fill(color).opacity(dotOpacity)
                            .frame(width: side * 0.3, height: side * 0.3)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
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
                    .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .opacity(index < min(lit, Self.rays) ? litOpacity : restingOpacity)
                    .padding(width / 2)
                    .animation(.spring(response: 0.9, dampingFraction: 0.9), value: lit)
            }
        }
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

/// The mark while it moves: the same rays and dot as layers, turned and pulsed by Core
/// Animation in the render server. Drawn from a TimelineView, every frame of the turn made
/// SwiftUI lay the whole window out again.
private struct MovingRays: NSViewRepresentable {
    let lit: Int
    let turning: Bool
    let waiting: Bool
    let restingOpacity: Double
    let litOpacity: Double
    let dotOpacity: Double
    let color: NSColor
    let stagger: Bool

    func makeNSView(context: Context) -> RaysView { RaysView() }

    func updateNSView(_ view: RaysView, context: Context) {
        view.paint(color)
        view.show(lit: lit, turning: turning, waiting: waiting, resting: restingOpacity, litOpacity: litOpacity, dotOpacity: dotOpacity,
                  stagger: stagger)
    }

    final class RaysView: NSView {
        /// Holds the rays and turns. Flipped, so the rays' paths come out as SwiftUI draws them.
        private let spinner = CALayer()
        private var rays: [CAShapeLayer] = []
        private let dot = CAShapeLayer()
        private var lit = -1

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            spinner.isGeometryFlipped = true
            for _ in 0..<RaysMark.rays {
                let ray = CAShapeLayer()
                ray.fillColor = nil
                ray.strokeColor = NSColor.white.cgColor
                ray.lineCap = .round
                spinner.addSublayer(ray)
                rays.append(ray)
            }
            layer?.addSublayer(spinner)
            dot.fillColor = NSColor.white.cgColor
            layer?.addSublayer(dot)
        }

        required init?(coder: NSCoder) { nil }

        func paint(_ color: NSColor) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for ray in rays { ray.strokeColor = color.cgColor }
            dot.fillColor = color.cgColor
            CATransaction.commit()
        }

        func show(lit: Int, turning: Bool, waiting: Bool, resting: Double, litOpacity: Double, dotOpacity: Double, stagger: Bool = false) {
            let before = max(self.lit, 0)
            CATransaction.begin()
            // A newly lit ray eases in, the way the still mark's spring brings it up.
            CATransaction.setAnimationDuration(lit == self.lit || self.lit < 0 || stagger ? 0 : 0.6)
            for (index, ray) in rays.enumerated() {
                ray.opacity = Float(index < lit ? litOpacity : resting)
            }
            CATransaction.commit()
            if stagger, lit > before {
                // Clockwise from twelve, each 0.16s and 0.04s after the one before.
                let now = CACurrentMediaTime()
                for index in before..<min(lit, rays.count) {
                    let light = CABasicAnimation(keyPath: "opacity")
                    light.fromValue = resting
                    light.toValue = litOpacity
                    light.duration = 0.16
                    light.beginTime = now + Double(index - before) * 0.04
                    light.fillMode = .backwards
                    rays[index].add(light, forKey: "light")
                }
            }
            self.lit = lit
            if turning, spinner.animation(forKey: "turn") == nil {
                // One turn in nine seconds, clockwise, which for a layer is the negative way,
                // from wherever an earlier turn stopped.
                let from = spinner.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = from
                turn.toValue = from - 2 * Double.pi
                turn.duration = 9
                turn.repeatCount = .infinity
                spinner.add(turn, forKey: "turn")
            } else if !turning, spinner.animation(forKey: "turn") != nil {
                // Stops where it is rather than snapping back to twelve.
                let angle = spinner.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                spinner.setValue(angle, forKeyPath: "transform.rotation.z")
                spinner.removeAnimation(forKey: "turn")
                CATransaction.commit()
            }
            dot.opacity = Float(dotOpacity)
            if waiting, dot.animation(forKey: "pulse") == nil {
                // Down to a third and back every 1.8 seconds: the thread is waiting on you.
                let pulse = CABasicAnimation(keyPath: "opacity")
                pulse.fromValue = dotOpacity
                pulse.toValue = dotOpacity * 0.35
                pulse.duration = 0.9
                pulse.autoreverses = true
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.add(pulse, forKey: "pulse")
            } else if !waiting {
                dot.removeAnimation(forKey: "pulse")
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let side = min(bounds.width, bounds.height)
            spinner.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            spinner.position = CGPoint(x: bounds.midX, y: bounds.midY)
            let width = max(1.2, side * 0.085)
            let circle = spinner.bounds.insetBy(dx: width / 2, dy: width / 2)
            for (index, ray) in rays.enumerated() {
                ray.frame = spinner.bounds
                ray.lineWidth = width
                ray.path = Ray(index: index, count: RaysMark.rays).path(in: circle).cgPath
            }
            let dotSide = side * 0.3
            dot.frame = CGRect(x: bounds.midX - dotSide / 2, y: bounds.midY - dotSide / 2, width: dotSide, height: dotSide)
            dot.path = CGPath(ellipseIn: dot.bounds, transform: nil)
            CATransaction.commit()
        }
    }
}
