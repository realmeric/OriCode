import CoreGraphics

/// Where the effort track's stops sit and how the thumb follows the pointer between them. It
/// sticks near a stop, catches up between stops, gives a little past either end, and holds back
/// before Ultracode until the pointer is nearly there, so the stop that costs the most is never
/// reached by accident.
struct EffortTrack {
    let levels: [String]
    /// The first and last stops' centres: the thumb's radius in from the track's ends.
    let start: CGFloat
    let end: CGFloat
    /// Ultracode is drawn but can't be reached: dynamic workflows are off.
    var blocked = false

    /// Pointer travel either side of a stop that moves the thumb only a quarter as far.
    static let capture: CGFloat = 9
    /// How far past an end stop the thumb gives.
    static let give: CGFloat = 8
    /// How close to Ultracode the pointer has to come before the thumb goes there, and how much
    /// further back it has to go to come out again.
    static let gate: CGFloat = 14
    static let hysteresis: CGFloat = 20

    /// Even steps, and a wider one before Ultracode, a mode past the levels rather than one more.
    var positions: [CGFloat] {
        let weights = levels.indices.map { $0 == 0 ? 0 : (levels[$0] == Effort.ultracode ? 1.4 : 1) }
        let total = weights.reduce(0, +)
        var x = start
        return weights.map { weight in
            x += total > 0 ? (end - start) * weight / total : 0
            return x
        }
    }

    func nearest(_ x: CGFloat) -> Int {
        let xs = positions
        return xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? 0
    }

    /// The thumb's centre and the stop it holds for a pointer at `pointer`. `holding` is the stop
    /// held until now, which decides whether Ultracode's gate is being entered or left.
    func follow(_ pointer: CGFloat, holding: Int?) -> (x: CGFloat, stop: Int) {
        let xs = positions
        guard let first = xs.first, let last = xs.last else { return (pointer, 0) }
        if pointer <= first {
            return (first - min((first - pointer) / 4, Self.give), 0)
        }
        if let ultra = levels.firstIndex(of: Effort.ultracode), ultra > 0, pointer > xs[ultra - 1] {
            let at = xs[ultra]
            let inside = !blocked && (holding == ultra ? pointer > at - Self.gate - Self.hysteresis : pointer >= at - Self.gate)
            if inside {
                return (at + max(min((pointer - at) / 4, Self.give), -Self.gate / 4), ultra)
            }
            let before = xs[ultra - 1]
            return (before + (pointer - before) * 0.35, ultra - 1)
        }
        if pointer >= last {
            return (last + min((pointer - last) / 4, Self.give), xs.count - 1)
        }
        let stop = nearest(pointer)
        let offset = pointer - xs[stop]
        let neighbour = offset < 0 ? stop - 1 : stop + 1
        guard xs.indices.contains(neighbour) else { return (xs[stop] + offset / 4, stop) }
        let half = abs(xs[neighbour] - xs[stop]) / 2
        let zone = min(Self.capture, half * 0.9)
        let distance = abs(offset)
        let moved = distance <= zone ? distance / 4 : zone / 4 + (distance - zone) * (half - zone / 4) / (half - zone)
        return (xs[stop] + (offset < 0 ? -moved : moved), stop)
    }

    /// Where a let-go settles: the stop nearest where the pointer was heading a moment later, so a
    /// flick carries one stop further at most. Momentum never carries up onto Max or Ultracode,
    /// the two that spend the plan faster: those take the pointer itself. It can carry down off them.
    func settle(_ pointer: CGFloat, velocity: CGFloat, holding: Int) -> Int {
        let ahead = nearest(pointer + max(min(velocity, 2400), -2400) * 0.09)
        let target = min(max(ahead, holding - 1), holding + 1)
        return target > holding && EffortScale.spendsFaster(levels[target]) ? holding : target
    }
}
