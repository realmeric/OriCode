import AppKit
import SwiftUI

/// What moves in and around the effort rail: the agent's heat, and where it goes. At every level a
/// change arrives: rising, light runs up the fill into the thumb and flares the lamps it passes,
/// a slug at Medium, a brighter one with embers at High, a sweep at Extra high; falling, the heat
/// the fill gave up drains back into the thumb. At Max, motes drift toward the thumb, slugs of
/// light sink into it with the glow round it breathing in as each lands, embers lift off the
/// fill's hot half and one jet of sparks flies off the rim. All of it is Core Animation, so the
/// render server draws it and the app does nothing per frame, and it moves only briefly after a
/// change, while the picker is on screen.
struct EffortEffects: NSViewRepresentable, Animatable {
    /// A change of level that has come to rest: bumped once a run of changes stops, with the stop
    /// the thumb left and whether a drag put it where it is.
    struct Arrival: Equatable {
        var count = 0
        var from: Int?
        var dragged = false
    }

    /// The level under the thumb.
    var level: String?
    /// The thread's agent's colour, which the heat is drawn in.
    var ink: AgentInk
    /// False for the first moments after the picker opens, while the fill pours in, and once the
    /// rail has rested.
    var live: Bool
    /// Bumped each time the thumb arrives at Max on the way up.
    var bursts: Int
    /// Bumped each time the rail wakes for a change, which starts the slugs over.
    var wakes: Int
    /// Where the thumb's centre is drawn, from the rail's start, following its spring: SwiftUI
    /// hands the view each step of the thumb's animation through `animatableData`.
    nonisolated var thumb: CGFloat
    /// Where it's going, which is where what runs up the fill sinks in.
    var landing: CGFloat
    /// The rail's stops, and the one under the thumb; the stops before it are lit lamps.
    var positions: [CGFloat]
    var index: Int?
    var arrival: Arrival
    /// The picker without the line under the rail, where the tiles come up closer.
    var compact: Bool

    nonisolated var animatableData: CGFloat {
        get { thumb }
        set { thumb = newValue }
    }

    /// How far past the thumb's centre the view reaches, and how far above and below the rail,
    /// for what the thumb and the fill throw off.
    static let reach: CGFloat = 40
    static let air: CGFloat = 20

    func makeNSView(context: Context) -> EffectsView { EffectsView() }

    func updateNSView(_ view: EffectsView, context: Context) {
        view.want(self)
    }

    static func dismantleNSView(_ view: EffectsView, coordinator: ()) {
        view.stop()
    }

    final class EffectsView: NSView {
        /// The fill's own shape: what runs along the rail stays inside it, and its last 10pt fade
        /// so what reaches the thumb sinks into it.
        private let tube = CALayer()
        private let fade = CAGradientLayer()
        private let moteLayer = CAEmitterLayer()
        private let burstLayer = CAEmitterLayer()
        private let emberLayer = CAEmitterLayer()
        private let jetLayer = CAEmitterLayer()
        /// Embers thrown off the hot end as High and Extra high arrive.
        private let puffLayer = CAEmitterLayer()
        /// Round the thumb and under it, and clear at rest, where the thumb's own halo is the glow.
        private let glow = CAGradientLayer()
        /// Keeps whatever is thrown off the rail away from the text above and below it.
        private let band = CAGradientLayer()
        private var level: String?
        private var ink = AgentInk.claude
        private var live = false
        private var bursts = 0
        private var wakes = 0
        private var thumb: CGFloat = 0
        private var landing: CGFloat = 0
        private var positions: [CGFloat] = []
        private var index: Int?
        private var arrival = Arrival()
        private var compact = false
        /// An arrival asked for before the view was on screen, played as soon as it is.
        private var pendingArrival: Arrival?
        /// Whether the picker's opening has had its moment.
        private var opened = false
        /// The wake whose slugs have been sent, so the next one sends its own.
        private var scored = -1
        /// Slugs yet to set off, which the next wake takes back, and the breaths they'd bring.
        private var waiting: [(slug: CAGradientLayer, start: CFTimeInterval, breath: String)] = []
        private var breaths = 0
        /// A burst asked for before the view was on screen, thrown as soon as it is.
        private var pendingBurst = false
        private var occlusion: NSObjectProtocol?
        private var displayOptions: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            band.startPoint = CGPoint(x: 0.5, y: 0)
            band.endPoint = CGPoint(x: 0.5, y: 1)
            band.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            layer?.mask = band
            glow.type = .radial
            glow.locations = [0, 0.5, 1]
            glow.startPoint = CGPoint(x: 0.5, y: 0.5)
            glow.endPoint = CGPoint(x: 1, y: 1)
            glow.opacity = 0
            layer?.addSublayer(glow)
            tube.masksToBounds = true
            tube.cornerRadius = EffortRail.rail / 2
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            tube.mask = fade
            layer?.addSublayer(tube)
            for emitter in [moteLayer, burstLayer] { tube.addSublayer(emitter) }
            layer?.addSublayer(emberLayer)
            layer?.addSublayer(puffLayer)
            layer?.addSublayer(jetLayer)
            for emitter in [moteLayer, burstLayer, emberLayer, jetLayer] {
                emitter.renderMode = .additive
                emitter.birthRate = 0
            }
            moteLayer.emitterShape = .rectangle
            moteLayer.emitterMode = .surface
            burstLayer.emitterShape = .point
            emberLayer.emitterShape = .rectangle
            emberLayer.emitterMode = .surface
            puffLayer.emitterShape = .rectangle
            puffLayer.emitterMode = .surface
            puffLayer.renderMode = .additive
            jetLayer.emitterShape = .point
            tint()
        }

        required init?(coder: NSCoder) { nil }

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            place()
        }

        private func place() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let air = EffortEffects.air
            let rail = EffortRail.rail
            let centre = thumb
            let mid = air + rail / 2
            let end = max(centre - EffortRail.thumb / 2 - 6, 0)
            band.frame = bounds
            // Clear from 18pt above the rail and 18pt below it, or 12pt where the tiles come closer.
            let height = max(bounds.height, 1)
            let below: CGFloat = compact ? 8 : 14
            band.locations = [air - 18, air - 14, air + rail + below, air + rail + below + 4].map { NSNumber(value: Double($0 / height)) }
            tube.frame = CGRect(x: 0, y: air, width: end, height: rail)
            fade.frame = tube.bounds
            let solid = end > 0 ? max(0, 1 - 10 / end) : 0
            fade.locations = [0, NSNumber(value: Double(solid)), 1]
            for emitter in [moteLayer, burstLayer] { emitter.frame = tube.bounds }
            moteLayer.emitterPosition = CGPoint(x: end / 2, y: rail / 2)
            moteLayer.emitterSize = CGSize(width: end, height: max(rail - 8, 1))
            burstLayer.emitterPosition = CGPoint(x: end, y: rail / 2)
            // Embers lift off the fill's top edge, its hot half.
            let from = end / 2
            let to = max(end - 4, from)
            emberLayer.frame = bounds
            emberLayer.emitterPosition = CGPoint(x: (from + to) / 2, y: air + 4)
            emberLayer.emitterSize = CGSize(width: to - from, height: 8)
            let puffFrom = max(centre - 44, 0)
            puffLayer.frame = bounds
            puffLayer.emitterPosition = CGPoint(x: (puffFrom + max(centre - 18, puffFrom)) / 2, y: air + 4)
            puffLayer.emitterSize = CGSize(width: max(centre - 18, puffFrom) - puffFrom, height: 8)
            // Half past ten on the rim, 17pt out from the thumb's centre. Only births follow the
            // thumb: sparks already thrown stay where they were thrown.
            jetLayer.frame = bounds
            jetLayer.emitterPosition = CGPoint(x: centre - 12, y: mid - 12)
            glow.bounds = CGRect(x: 0, y: 0, width: 64, height: 44)
            glow.position = CGPoint(x: centre, y: mid)
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

        /// Max, the level with heat of its own.
        private var atMax: Bool { level == "max" }

        /// The stops the thumb has passed, where the lamps are lit.
        private var lamps: [CGFloat] {
            Array(positions.prefix(index ?? 0))
        }

        func want(_ wanted: EffortEffects) {
            let moved = wanted.level != level || wanted.compact != compact || wanted.thumb != thumb
            level = wanted.level
            if wanted.ink != ink {
                ink = wanted.ink
                tint()
            }
            live = wanted.live
            if wanted.bursts > bursts { pendingBurst = true }
            bursts = wanted.bursts
            wakes = wanted.wakes
            thumb = wanted.thumb
            landing = wanted.landing
            positions = wanted.positions
            index = wanted.index
            if wanted.arrival.count > arrival.count { pendingArrival = wanted.arrival }
            arrival = wanted.arrival
            compact = wanted.compact
            if moved { place() }
            apply()
        }

        func stop() {
            forget()
            for emitter in [moteLayer, emberLayer, jetLayer] {
                emitter.birthRate = 0
                emitter.emitterCells = nil
                emitter.removeAllAnimations()
            }
            for layer in [burstLayer, glow] { layer.removeAllAnimations() }
            for sent in waiting { sent.slug.removeFromSuperlayer() }
            waiting.removeAll()
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
            let on = visible && live
            // Extra high is the first level where heat lingers: a few motes, no more.
            let motes: Float = atMax ? 1 : level == "xhigh" ? 0.4 : 0
            run(moteLayer, rate: on ? motes : 0, prewarm: atMax, cells: [moteCell])
            run(emberLayer, rate: on && atMax ? 1 : 0, cells: [emberCell])
            run(jetLayer, rate: on && atMax ? 1 : 0, ramp: false, cells: jetCells)
            if on, wakes != scored {
                scored = wakes
                score()
            }
            // Arriving at Max makes this view in the same moment, before it's on screen.
            if pendingBurst, visible {
                pendingBurst = false
                arrive()
            }
            if let pending = pendingArrival, visible {
                pendingArrival = nil
                play(pending)
            }
        }

        /// Starting ramps the birth rate up, except for a jet, which fires at once. Stopping fades
        /// what's still out, so nothing drifts on through a level that doesn't have it.
        private func run(_ emitter: CAEmitterLayer, rate: Float, ramp: Bool = true, prewarm: Bool = false,
                         cells: @autoclosure () -> [CAEmitterCell]) {
            guard emitter.birthRate != rate else { return }
            if rate > 0 {
                if emitter.birthRate == 0 {
                    emitter.removeAnimation(forKey: "opacity")
                    emitter.opacity = 1
                    emitter.emitterCells = cells()
                    if prewarm { emitter.beginTime = CACurrentMediaTime() - 1.2 }
                    if ramp {
                        let up = CABasicAnimation(keyPath: "birthRate")
                        up.fromValue = 0
                        up.toValue = rate
                        up.duration = 0.25
                        emitter.add(up, forKey: "birthRate")
                    }
                }
            } else {
                let out = CABasicAnimation(keyPath: "opacity")
                out.fromValue = emitter.presentation()?.opacity ?? 1
                out.toValue = 0
                out.duration = 0.5
                emitter.add(out, forKey: "opacity")
                emitter.opacity = 0
            }
            emitter.birthRate = rate
        }

        /// Slugs of heat drawn along the fill into the thumb, the glow breathing in as each lands:
        /// two slow ones at Max.
        private func score() {
            let now = tube.convertTime(CACurrentMediaTime(), from: nil)
            for sent in waiting where sent.start > now {
                sent.slug.removeFromSuperlayer()
                glow.removeAnimation(forKey: sent.breath)
            }
            waiting.removeAll()
            defer { opened = true }
            guard atMax else {
                // Below Max the picker's opening is the moment: the glow breathes as the pour lands.
                if !opened { glowUp(peak: 0.35, swell: 0.1, rise: 0.1, fall: 0.5, at: now, key: "open") }
                return
            }
            for (order, start) in [0.15, 1.95].enumerated() {
                // The first slug lights the lamps on its way.
                send(at: now + start, flaring: order == 0)
            }
        }

        private func send(at start: CFTimeInterval, flaring: Bool) {
            let travel = 1.35
            let slug = CAGradientLayer()
            slug.type = .radial
            slug.colors = [ember.copy(alpha: 0.6)!, ember.copy(alpha: 0)!]
            slug.startPoint = CGPoint(x: 0.5, y: 0.5)
            slug.endPoint = CGPoint(x: 1, y: 1)
            slug.bounds = CGRect(x: 0, y: 0, width: 48, height: 20)
            slug.position = CGPoint(x: -slug.bounds.width / 2, y: EffortRail.rail / 2)
            slug.opacity = 0
            tube.insertSublayer(slug, at: 0)
            // Gathers speed and light toward the thumb, and sinks into the fade in front of it.
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -slug.bounds.width / 2
            move.toValue = landing - EffortRail.thumb / 2 + 2
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.9, 0.55)
            if flaring { flareLamps(from: -slug.bounds.width / 2, to: landing - EffortRail.thumb / 2 + 2, start: start, travel: travel, peak: 0.9) }
            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, 0.5, 1]
            light.keyTimes = [0, 0.35, 1]
            let slide = CAAnimationGroup()
            slide.animations = [move, light]
            slide.duration = travel
            slide.beginTime = start
            CATransaction.begin()
            CATransaction.setCompletionBlock { slug.removeFromSuperlayer() }
            slug.add(slide, forKey: "slide")
            CATransaction.commit()
            breaths += 1
            let breath = "breath\(breaths)"
            glowUp(peak: 0.5, swell: 0.15, rise: 0.5, fall: 0.9, at: start + travel - 0.5, key: breath)
            waiting.append((slug, start, breath))
        }

        /// A level come to rest below the top. Rising, light runs up the fill into the thumb, sized to
        /// the level, and the lamps it passes flare as it reaches them; falling, the heat the fill gave
        /// up drains back into the thumb. Max arrives through its burst, and a fall a
        /// drag made has already drained under the finger.
        private func play(_ arrival: Arrival) {
            guard let from = arrival.from, positions.indices.contains(from), let index else { return }
            if from < index {
                carry()
            } else if from > index, !arrival.dragged {
                drain(from: positions[from])
            }
        }

        private func carry() {
            let spec: (width: CGFloat, height: CGFloat, light: CGFloat, travel: CFTimeInterval, flare: Float, peak: Double, swell: Double, embers: Float)
            switch level {
            case "medium": spec = (30, 13, 0.4, 0.5, 0.7, 0.35, 0.1, 0)
            case "high": spec = (34, 14, 0.48, 0.48, 0.8, 0.45, 0.14, 40)
            case "xhigh": spec = (26, 22, 0.8, 0.42, 0.95, 0.55, 0.18, 80)
            default: return
            }
            let now = tube.convertTime(CACurrentMediaTime(), from: nil)
            let from = -spec.width / 2
            let to = landing - EffortRail.thumb / 2 + 2
            let carrier = CAGradientLayer()
            if level == "xhigh" {
                // A sweep, the CLI's shimmer at Extra high done in heat.
                carrier.colors = [ember.copy(alpha: 0)!, ember.copy(alpha: spec.light)!, ember.copy(alpha: 0)!]
                carrier.startPoint = CGPoint(x: 0, y: 0.5)
                carrier.endPoint = CGPoint(x: 1, y: 0.5)
            } else {
                carrier.type = .radial
                carrier.colors = [ember.copy(alpha: spec.light)!, ember.copy(alpha: 0)!]
                carrier.startPoint = CGPoint(x: 0.5, y: 0.5)
                carrier.endPoint = CGPoint(x: 1, y: 1)
            }
            carrier.bounds = CGRect(x: 0, y: 0, width: spec.width, height: spec.height)
            carrier.position = CGPoint(x: from, y: EffortRail.rail / 2)
            tube.addSublayer(carrier)
            let run = CABasicAnimation(keyPath: "position.x")
            run.fromValue = from
            run.toValue = to
            run.duration = spec.travel
            // Gathering speed toward the thumb, and sinking into the fade in front of it.
            run.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.085, 0.68, 0.53)
            run.fillMode = .forwards
            run.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { carrier.removeFromSuperlayer() }
            carrier.add(run, forKey: "carry")
            CATransaction.commit()
            flareLamps(from: from, to: to, start: now, travel: spec.travel, peak: spec.flare)
            glowUp(peak: spec.peak, swell: spec.swell, rise: 0.1, fall: 0.5, at: now + spec.travel - 0.1, key: "arrival")
            if spec.embers > 0 { fire(puffLayer, cell: "puff", rate: spec.embers, at: now + spec.travel, for: 0.1) }
        }

        /// Flares each lit lamp as light running from `from` to `to` on an ease-in reaches it.
        private func flareLamps(from: CGFloat, to: CGFloat, start: CFTimeInterval, travel: CFTimeInterval, peak: Float) {
            for lamp in lamps where lamp > from && lamp < to {
                let flare = CAGradientLayer()
                flare.type = .radial
                flare.colors = [ember.copy(alpha: 0.9)!, ember.copy(alpha: 0)!]
                flare.startPoint = CGPoint(x: 0.5, y: 0.5)
                flare.endPoint = CGPoint(x: 1, y: 1)
                flare.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
                flare.position = CGPoint(x: lamp, y: EffortEffects.air + EffortRail.rail / 2)
                flare.opacity = 0
                layer?.addSublayer(flare)
                let light = CAKeyframeAnimation(keyPath: "opacity")
                light.values = [0, peak, 0]
                let grow = CAKeyframeAnimation(keyPath: "transform.scale")
                grow.values = [0.5, 1.3, 1]
                for animation in [light, grow] { animation.keyTimes = [0, 0.3, 1] }
                let strike = CAAnimationGroup()
                strike.animations = [light, grow]
                strike.duration = 0.32
                strike.beginTime = start + travel * sqrt(Double((lamp - from) / (to - from)))
                CATransaction.begin()
                CATransaction.setCompletionBlock { flare.removeFromSuperlayer() }
                flare.add(strike, forKey: "strike")
                CATransaction.commit()
            }
        }

        /// The fill a fall gave up, glowing where it was and draining back into the thumb.
        private func drain(from: CGFloat) {
            guard from > landing else { return }
            let heat = CAGradientLayer()
            heat.colors = [base.copy(alpha: 0.55)!, base.copy(alpha: 0.3)!]
            heat.startPoint = CGPoint(x: 0, y: 0.5)
            heat.endPoint = CGPoint(x: 1, y: 0.5)
            heat.cornerRadius = EffortRail.rail / 2
            heat.anchorPoint = CGPoint(x: 0, y: 0.5)
            heat.bounds = CGRect(x: 0, y: 0, width: from - landing + EffortRail.rail / 2, height: EffortRail.rail)
            heat.position = CGPoint(x: landing, y: EffortEffects.air + EffortRail.rail / 2)
            layer?.insertSublayer(heat, below: tube)
            let shrink = CABasicAnimation(keyPath: "bounds.size.width")
            shrink.toValue = 0
            shrink.duration = 0.45
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.toValue = 0
            fade.duration = 0.5
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let group = CAAnimationGroup()
            group.animations = [shrink, fade]
            group.duration = 0.5
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { heat.removeFromSuperlayer() }
            heat.add(group, forKey: "drain")
            CATransaction.commit()
        }

        /// Arriving at the top: embers thrown back out of the thumb and drawn in again, a flash of
        /// the glow, and a spit of sparks from Max's jet.
        private func arrive() {
            burstLayer.beginTime = CACurrentMediaTime()
            let burst = CAKeyframeAnimation(keyPath: "emitterCells.burst.birthRate")
            burst.values = [240, 240, 0]
            burst.keyTimes = [0, 0.99, 1]
            burst.duration = 0.12
            burstLayer.birthRate = 1
            burstLayer.add(burst, forKey: "burst")
            guard atMax else { return }
            let now = jetLayer.convertTime(CACurrentMediaTime(), from: nil)
            fire(jetLayer, cell: "spit", rate: 80, at: now, for: 0.1)
            glowUp(peak: 0.85, swell: 0.2, rise: 0.08, fall: 0.47, at: now, key: "flash")
        }

        private func fire(_ emitter: CAEmitterLayer, cell: String, rate: Float, at start: CFTimeInterval, for duration: CFTimeInterval) {
            let puff = CAKeyframeAnimation(keyPath: "emitterCells.\(cell).birthRate")
            puff.values = [rate, rate, 0]
            puff.keyTimes = [0, 0.99, 1]
            puff.duration = duration
            puff.beginTime = start
            emitter.add(puff, forKey: cell)
        }

        /// Lights the glow and swells it, on top of whatever else it's doing: every animation on
        /// it adds, so a flash and a breath that overlap sum.
        private func glowUp(peak: Double, swell: Double, rise: CFTimeInterval, fall: CFTimeInterval, at start: CFTimeInterval, key: String) {
            let turn = rise / (rise + fall)
            let light = CAKeyframeAnimation(keyPath: "opacity")
            light.values = [0, peak, 0]
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [-swell / 2, swell, 0]
            for animation in [light, grow] {
                animation.keyTimes = [0, NSNumber(value: turn), 1]
                animation.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .easeOut)]
                animation.isAdditive = true
            }
            let group = CAAnimationGroup()
            group.animations = [light, grow]
            group.duration = rise + fall
            group.beginTime = start
            glow.add(group, forKey: key)
        }

        private static let dot: CGImage = image(size: CGSize(width: 12, height: 12)) { context, size in
            let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 0)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            context.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: size.width / 2, options: [])
        }

        /// The agent's colour, and a pale ember: the particles' white, warmed to sit in it.
        private var base: CGColor { .of(ink.base) }
        private var ember: CGColor { .of(ink.ember) }
        /// What a spark is born as, before it cools to the agent's colour.
        private var whiteHot: CGColor { .of(ink.whiteHot) }

        /// What's drawn in the agent's colour before anything is fired.
        private func tint() {
            glow.colors = [ember, base.copy(alpha: 0.5)!, base.copy(alpha: 0)!]
            burstLayer.emitterCells = [burstCell]
            puffLayer.emitterCells = [puffCell]
        }

        /// Takes a cell from `color` to the agent's colour over `seconds`.
        private func cool(_ cell: CAEmitterCell, from color: CGColor, over seconds: Float) {
            cell.color = color
            let from = color.components ?? [1, 1, 1, 1]
            let to = base.components ?? [1, 1, 1, 1]
            cell.redSpeed = Float(to[0] - from[0]) / seconds
            cell.greenSpeed = Float(to[1] - from[1]) / seconds
            cell.blueSpeed = Float(to[2] - from[2]) / seconds
        }

        /// The reasoning at the top of the scale: soft points drifting toward the thumb, growing as
        /// they near it and fading out rather than vanishing.
        private var moteCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = Self.dot
            cell.color = ember
            cell.contentsScale = 2
            cell.birthRate = 10
            cell.lifetime = 2.2
            cell.lifetimeRange = 0.5
            cell.velocity = 24
            cell.velocityRange = 8
            cell.emissionLongitude = 0
            cell.emissionRange = 0.3
            cell.yAcceleration = -3
            cell.scale = 0.1
            cell.scaleRange = 0.03
            cell.scaleSpeed = 0.12
            cell.alphaSpeed = -0.45
            return cell
        }

        /// Arriving at the top: embers thrown back out of the thumb white-hot, slowed, and drawn
        /// back in, cooling as they go.
        private var burstCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.name = "burst"
            cell.contents = Self.dot
            cell.contentsScale = 2
            cell.birthRate = 0
            cell.lifetime = 0.95
            cell.lifetimeRange = 0.15
            cell.velocity = 95
            cell.velocityRange = 30
            cell.emissionLongitude = .pi
            cell.emissionRange = 0.3
            cell.xAcceleration = 190
            cell.scale = 0.22
            cell.scaleRange = 0.08
            cell.scaleSpeed = -0.12
            cell.alphaSpeed = -1
            cool(cell, from: whiteHot, over: 0.95)
            return cell
        }

        /// The same embers, thrown in a handful as High and Extra high arrive.
        private var puffCell: CAEmitterCell {
            let cell = emberCell
            cell.name = "puff"
            cell.birthRate = 0
            return cell
        }

        /// Embers lifting off the top of the fill, born bright in the agent's colour and gone within 12pt.
        private var emberCell: CAEmitterCell {
            let cell = CAEmitterCell()
            cell.contents = Self.dot
            cell.contentsScale = 2
            cell.birthRate = 8
            cell.lifetime = 0.8
            cell.lifetimeRange = 0.4
            cell.velocity = 8
            cell.velocityRange = 6
            // Up, leaning a little away from the thumb.
            cell.emissionLongitude = -.pi / 2 - 0.1
            cell.emissionRange = 0.45
            cell.yAcceleration = -4
            cell.scale = 0.2
            cell.scaleRange = 0.06
            cell.scaleSpeed = -0.04
            cell.alphaSpeed = -1.1
            cool(cell, from: ember.copy(alpha: 0.9)!, over: 0.8)
            return cell
        }

        private func spark(_ name: String, birthRate: Float, velocity: CGFloat, longitude: CGFloat, life: Float) -> CAEmitterCell {
            let cell = CAEmitterCell()
            cell.name = name
            cell.contents = Self.dot
            cell.contentsScale = 2
            cell.birthRate = birthRate
            cell.lifetime = life
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.4
            cell.emissionLongitude = longitude
            cool(cell, from: whiteHot, over: life)
            return cell
        }

        /// Max's jet, off the rim like a grinder's: sparks that rise a few points, arc back and die
        /// over the fill behind the thumb, and a spit of them, lower, as the thumb arrives.
        private var jetCells: [CAEmitterCell] {
            [spark("spark", birthRate: 11, velocity: 46, longitude: -2.05, life: 0.55),
             spark("spit", birthRate: 0, velocity: 55, longitude: -2.5, life: 0.55)].map { cell in
                cell.lifetimeRange = 0.3
                cell.emissionRange = 0.6
                cell.yAcceleration = 170
                cell.scale = 0.18
                cell.scaleRange = 0.05
                cell.scaleSpeed = -0.1
                cell.alphaSpeed = -1.6
                return cell
            }
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
