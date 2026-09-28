import CoreGraphics

/// Where the effort track's stops sit and how the thumb follows the pointer between them. It
/// sticks near a stop, catches up between stops, and gives a little past either end.
struct EffortTrack {
    let levels: [String]
    /// The first and last stops' centres: the thumb's radius in from the track's ends.
    let start: CGFloat
    let end: CGFloat

    /// Pointer travel either side of a stop that moves the thumb only a quarter as far.
    static let capture: CGFloat = 9
    /// How far past an end stop the thumb gives.
    static let give: CGFloat = 8

    /// Even steps from end to end.
    var positions: [CGFloat] {
        let steps = CGFloat(max(levels.count - 1, 1))
        return levels.indices.map { start + (end - start) * CGFloat($0) / steps }
    }

    func nearest(_ x: CGFloat) -> Int {
        let xs = positions
        return xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) } ?? 0
    }

    /// The thumb's centre and the stop it holds for a pointer at `pointer`.
    func follow(_ pointer: CGFloat) -> (x: CGFloat, stop: Int) {
        let xs = positions
        guard let first = xs.first, let last = xs.last else { return (pointer, 0) }
        if pointer <= first {
            return (first - min((first - pointer) / 4, Self.give), 0)
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
    /// flick carries one stop further at most. Momentum never carries up onto Max, which spends
    /// the plan faster: that takes the pointer itself. It can carry down off it.
    func settle(_ pointer: CGFloat, velocity: CGFloat, holding: Int) -> Int {
        let ahead = nearest(pointer + max(min(velocity, 2400), -2400) * 0.09)
        let target = min(max(ahead, holding - 1), holding + 1)
        return target > holding && EffortScale.spendsFaster(levels[target]) ? holding : target
    }
}
