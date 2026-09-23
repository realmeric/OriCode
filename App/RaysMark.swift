import SwiftUI

/// Meriç's mark: a dot inside six arcs. The arcs are rays, and a lit ray is a head
/// running in the thread, the main loop first and then each subagent, lit clockwise
/// from twelve o'clock.
struct RaysMark: View {
    static let rays = 6
    /// Seconds for one turn, and for one in fast mode.
    nonisolated static let turn: CFTimeInterval = 9
    nonisolated static let fastTurn: CFTimeInterval = 0.5
    /// Fast mode's trail: each ray drawn again this many times, each copy this much earlier.
    nonisolated static let trailCopies = 9
    nonisolated static let trailDelay: CFTimeInterval = 1.0 / 480

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
    /// A turn that ends coasts on to where the next ray stands, so the mark rests upright: the
    /// effort thumb's, whose rays stop each time the picker rests.
    var settles = false
    /// Fast mode: a turn goes round in half a second with a trail behind each ray, and coasts
    /// further to rest.
    var fast = false

    var body: some View {
        Group {
            if turning || waiting || layered {
                MovingRays(lit: min(lit, Self.rays), turning: turning, waiting: waiting,
                           restingOpacity: restingOpacity, litOpacity: litOpacity, dotOpacity: dotOpacity,
                           color: NSColor(color), stagger: stagger, settles: settles, fast: fast)
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
    let settles: Bool
    let fast: Bool

    func makeNSView(context: Context) -> RaysView { RaysView() }

    func updateNSView(_ view: RaysView, context: Context) {
        view.paint(color)
        view.show(lit: lit, turning: turning, waiting: waiting, resting: restingOpacity, litOpacity: litOpacity, dotOpacity: dotOpacity,
                  stagger: stagger, settles: settles, fast: fast)
    }

    final class RaysView: NSView {
        /// Draws the spinner again behind itself, each copy a moment earlier and fainter: fast
        /// mode's motion blur, sampled from the turn itself. One copy, the spinner alone, at rest.
        private let trail = CAReplicatorLayer()
        /// Holds the rays and turns. Flipped, so the rays' paths come out as SwiftUI draws them.
        private let spinner = CALayer()
        private var rays: [CAShapeLayer] = []
        private let dot = CAShapeLayer()
        private var lit = -1
        private var turnPeriod = RaysMark.turn
        /// Bumped by each turn, so a coast that ends after a newer turn began leaves its trail be.
        private var generation = 0

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            trail.instanceCount = 1
            trail.instanceDelay = RaysMark.trailDelay
            trail.instanceAlphaOffset = -0.11
            spinner.isGeometryFlipped = true
            for _ in 0..<RaysMark.rays {
                let ray = CAShapeLayer()
                ray.fillColor = nil
                ray.strokeColor = NSColor.white.cgColor
                ray.lineCap = .round
                spinner.addSublayer(ray)
                rays.append(ray)
            }
            trail.addSublayer(spinner)
            layer?.addSublayer(trail)
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

        func show(lit: Int, turning: Bool, waiting: Bool, resting: Double, litOpacity: Double, dotOpacity: Double, stagger: Bool = false,
                  settles: Bool = false, fast: Bool = false) {
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
            let period = fast ? RaysMark.fastTurn : RaysMark.turn
            if turning, spinner.animation(forKey: "turn") == nil || period != turnPeriod {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                trail.instanceCount = fast ? RaysMark.trailCopies : 1
                CATransaction.commit()
                generation += 1
                // Clockwise, which for a layer drawn upward is the negative way.
                spinner.startTurning(clockwise: -1, period: period)
                turnPeriod = period
            } else if !turning, settles {
                // The copies stay with the coast, which starts that much earlier so the trail
                // doesn't drop out, and go at rest, where they'd stack on each ray and brighten it.
                let span = trail.instanceCount > 1 ? Double(trail.instanceCount) * RaysMark.trailDelay : 0
                let generation = generation
                spinner.coastToRay(clockwise: -1, period: turnPeriod, trail: span) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.trail.instanceCount = 1
                    CATransaction.commit()
                }
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
            trail.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            trail.position = CGPoint(x: bounds.midX, y: bounds.midY)
            spinner.frame = trail.bounds
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

extension CALayer {
    /// One turn every `period` seconds, clockwise: the negative way for a layer drawn upward and
    /// the positive way for one drawn downward, which `clockwise` says. It starts from wherever an
    /// earlier turn or a coast has got to, so a change of speed doesn't jump.
    func startTurning(clockwise: Double, period: CFTimeInterval = RaysMark.turn) {
        let moving = animation(forKey: "turn") != nil || animation(forKey: "coast") != nil
        let from = (moving ? presentation() ?? self : self).value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        removeAnimation(forKey: "coast")
        removeAnimation(forKey: "turn")
        setValue(from, forKeyPath: "transform.rotation.z")
        CATransaction.commit()
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = from
        turn.toValue = from + clockwise * 2 * .pi
        turn.duration = period
        turn.repeatCount = .infinity
        turn.fillMode = .backwards
        if period < 1 { turn.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
        add(turn, forKey: "turn")
    }

    /// Ends a turn by coasting on to where the next ray stands, leaving at the turn's own speed
    /// and easing to a stop there, so the mark rests upright instead of wherever it was. A fast
    /// turn coasts longer and further, spinning down heavily. `span` starts the coast that much
    /// earlier, for a trail whose copies show the moments before now.
    func coastToRay(clockwise: Double, period: CFTimeInterval = RaysMark.turn, trail span: CFTimeInterval = 0,
                    completion: (() -> Void)? = nil) {
        guard animation(forKey: "turn") != nil else { return }
        let angle = presentation()?.value(forKeyPath: "transform.rotation.z") as? Double ?? 0
        let step = Double.pi / 3
        let speed = 2 * Double.pi / period
        let duration: CFTimeInterval = period < 1 ? 1.2 : 1
        // At least a third of a step on, so the coast is never a jolt, and far enough that it can
        // leave at the turn's speed and still ease in.
        let reach = max(step / 3, speed * duration / 4.8)
        let rest = ((angle * clockwise + reach) / step).rounded(.up) * step
        let slope = speed * (duration + span) / (rest - angle * clockwise + speed * span)
        let coast = CABasicAnimation(keyPath: "transform.rotation.z")
        coast.fromValue = angle - clockwise * speed * span
        coast.toValue = rest * clockwise
        coast.duration = duration + span
        coast.beginTime = convertTime(CACurrentMediaTime(), from: nil) - span
        coast.fillMode = .backwards
        coast.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, Float(0.2 * slope), 0.4, 1)
        if period < 1 { coast.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(completion)
        setValue(rest * clockwise, forKeyPath: "transform.rotation.z")
        removeAnimation(forKey: "turn")
        add(coast, forKey: "coast")
        CATransaction.commit()
    }
}
