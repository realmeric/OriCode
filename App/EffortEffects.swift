import AppKit
import SwiftUI

/// What moves inside the effort rail's fill, warm against Claude's orange: motes drifting toward
/// the thumb at Max and Ultracode, a burst thrown back as the thumb arrives there, and streaks
/// running back from the thumb while the CLI serves the thread fast. All of it is Core Animation, so the render server
/// draws it and the app does nothing per frame, and it runs only while the picker is on screen.
struct EffortEffects: NSViewRepresentable {
    var motes: Bool
    var streaks: Bool
    /// False for the first moments after the picker opens, while the fill pours in.
    var live: Bool
    /// Bumped each time the thumb arrives at Max or Ultracode on the way up.
    var bursts: Int

    func makeNSView(context: Context) -> EffectsView { EffectsView() }

    func updateNSView(_ view: EffectsView, context: Context) {
        view.want(motes: motes && live, streaks: streaks && live, bursts: bursts)
    }

    static func dismantleNSView(_ view: EffectsView, coordinator: ()) {
        view.stop()
    }

    final class EffectsView: NSView {
        private let moteLayer = CAEmitterLayer()
        private let burstLayer = CAEmitterLayer()
        private let streakLayer = CAEmitterLayer()
        private let fade = CAGradientLayer()
        private var wantsMotes = false
        private var wantsStreaks = false
        private var bursts = 0
        private var served = false
        /// A burst asked for before the view was on screen, thrown as soon as it is.
        private var pendingBurst = false
        private var occlusion: NSObjectProtocol?
        private var displayOptions: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.cornerRadius = 12
            // The last 10pt fade to clear, so the region's end in front of the thumb is soft.
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            layer?.mask = fade
            for emitter in [moteLayer, burstLayer, streakLayer] {
                emitter.renderMode = .additive
                emitter.birthRate = 0
                layer?.addSublayer(emitter)
            }
            moteLayer.emitterShape = .rectangle
            moteLayer.emitterMode = .surface
            burstLayer.emitterShape = .point
            burstLayer.emitterCells = [Self.burstCell]
            streakLayer.emitterShape = .rectangle
            streakLayer.emitterMode = .surface
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = bounds
            let solid = bounds.width > 0 ? max(0, 1 - 10 / bounds.width) : 0
            fade.locations = [0, NSNumber(value: solid), 1]
            for emitter in [moteLayer, burstLayer, streakLayer] { emitter.frame = bounds }
            moteLayer.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
            moteLayer.emitterSize = CGSize(width: bounds.width, height: max(bounds.height - 8, 1))
            burstLayer.emitterPosition = CGPoint(x: bounds.maxX, y: bounds.midY)
            streakLayer.emitterPosition = CGPoint(x: bounds.maxX, y: bounds.midY)
            streakLayer.emitterSize = CGSize(width: 1, height: 12)
            CATransaction.commit()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            forget()
            guard let window else {
                stop()
                return
            }
            let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main, using: refresh)
            displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main, using: refresh)
            apply()
        }

        func want(motes: Bool, streaks: Bool, bursts: Int) {
            wantsMotes = motes
            wantsStreaks = streaks
            if bursts > self.bursts { pendingBurst = true }
            self.bursts = bursts
            apply()
        }

        func stop() {
            forget()
            for emitter in [moteLayer, streakLayer] {
                emitter.birthRate = 0
                emitter.emitterCells = nil
            }
            for layer in [moteLayer, burstLayer, streakLayer] { layer.removeAllAnimations() }
        }

        private func forget() {
            if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
            if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
            occlusion = nil
            displayOptions = nil
        }

        private var visible: Bool {
            guard let window else { return false }
            return window.occlusionState.contains(.visible) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        private func apply() {
            run(moteLayer, on: visible && wantsMotes, cells: [Self.moteCell])
            run(streakLayer, on: visible && wantsStreaks, cells: [Self.streakCell])
            // Fast comes on with one bright band sweeping back from the thumb.
            let serving = visible && wantsStreaks
            if serving, !served { ignite() }
            served = serving
            // Arriving at Max makes this view in the same moment, before it's on screen.
            if pendingBurst, visible {
                pendingBurst = false
                throwBurst()
            }
        }

        /// Starting ramps the birth rate up, already moving. Stopping fades what's still out, so
        /// nothing drifts on through a level that doesn't have it.
        private func run(_ emitter: CAEmitterLayer, on: Bool, cells: @autoclosure () -> [CAEmitterCell]) {
            let rate: Float = on ? 1 : 0
            guard emitter.birthRate != rate else { return }
            if on {
                emitter.removeAnimation(forKey: "opacity")
                emitter.opacity = 1
                emitter.emitterCells = cells()
                emitter.beginTime = CACurrentMediaTime() - 1.2
                let ramp = CABasicAnimation(keyPath: "birthRate")
                ramp.fromValue = 0
                ramp.toValue = 1
                ramp.duration = 0.25
                emitter.add(ramp, forKey: "birthRate")
            } else {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = emitter.presentation()?.opacity ?? 1
                out.toValue = 0
                out.duration = 0.25
                emitter.add(out, forKey: "opacity")
                emitter.opacity = 0
            }
            emitter.birthRate = rate
        }

        private func throwBurst() {
            let burst = CAKeyframeAnimation(keyPath: "emitterCells.burst.birthRate")
            burst.values = [200, 200, 0]
            burst.keyTimes = [0, 0.99, 1]
            burst.duration = 0.12
            burstLayer.birthRate = 1
            burstLayer.beginTime = CACurrentMediaTime()
            burstLayer.add(burst, forKey: "burst")
        }

        private func ignite() {
            let band = CAGradientLayer()
            band.colors = [NSColor.clear.cgColor, Self.ember.copy(alpha: 0.85)!, NSColor.clear.cgColor]
            band.startPoint = CGPoint(x: 0, y: 0.5)
            band.endPoint = CGPoint(x: 1, y: 0.5)
            band.frame = CGRect(x: 0, y: bounds.midY - 7, width: 48, height: 14)
            layer?.addSublayer(band)
            CATransaction.begin()
            CATransaction.setCompletionBlock { band.removeFromSuperlayer() }
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = bounds.maxX
            sweep.toValue = -24
            sweep.duration = 0.35
            sweep.timingFunction = CAMediaTimingFunction(name: .easeOut)
            sweep.fillMode = .forwards
            sweep.isRemovedOnCompletion = false
            band.add(sweep, forKey: "sweep")
            CATransaction.commit()
        }

        private static let dot: CGImage = image(size: CGSize(width: 12, height: 12)) { context, size in
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size.width / 2, options: [])
        }

        /// Bright at its left end, which leads as the streak runs back from the thumb.
        private static let streak: CGImage = image(size: CGSize(width: 28, height: 2)) { context, size in
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.clip()
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: [])
        }

        /// A pale ember: the particles' white, warmed to sit in Claude's orange.
        private static let ember = CGColor(red: 1, green: 0.86, blue: 0.78, alpha: 1)

        /// The reasoning at the top of the scale: soft points drifting toward the thumb.
        private static var moteCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = ember
            cell.contentsScale = 2
            cell.birthRate = 8
            cell.lifetime = 2.2
            cell.lifetimeRange = 0.6
            cell.velocity = 24
            cell.velocityRange = 10
            cell.emissionLongitude = 0
            cell.emissionRange = 0.35
            cell.yAcceleration = -3
            cell.scale = 0.19
            cell.scaleRange = 0.06
            cell.alphaSpeed = -0.35
            return cell
        }

        private static var burstCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.name = "burst"
            cell.contents = dot
            cell.color = ember
            cell.contentsScale = 2
            cell.birthRate = 0
            cell.lifetime = 0.5
            cell.lifetimeRange = 0.15
            cell.velocity = 55
            cell.velocityRange = 25
            cell.emissionLongitude = .pi
            cell.emissionRange = 0.6
            cell.scale = 0.2
            cell.scaleRange = 0.08
            cell.alphaSpeed = -1.6
            return cell
        }

        /// Fast mode: streaks running back from the thumb, faster than anything else here.
        private static var streakCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = streak
            cell.contentsScale = 2
            cell.birthRate = 14
            cell.lifetime = 0.6
            cell.lifetimeRange = 0.25
            cell.velocity = 160
            cell.velocityRange = 40
            cell.emissionLongitude = .pi
            cell.scale = 1
            cell.scaleRange = 0.4
            cell.alphaRange = 0.18
            cell.color = ember.copy(alpha: 0.62)
            cell.alphaSpeed = -1.2
            return cell
        }

        private static func image(size: CGSize, draw: (CGContext, CGSize) -> Void) -> CGImage {
            let scale: CGFloat = 2
            let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.scaleBy(x: scale, y: scale)
            draw(context, size)
            return context.makeImage()!
        }
    }
}
