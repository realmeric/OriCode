import SwiftUI

/// How many of a review's rows are made. The first come with the panel and the rest one to a
/// frame after; a key that asks for a row not made yet makes them all, and from then on the
/// count takes nothing more: a task that slept through the key adds to nothing.
struct MadeRows: Equatable {
    private(set) var count: Int

    static let all = MadeRows(count: .max)

    /// One more row, while there are fewer than `limit`.
    mutating func makeOne(of limit: Int) {
        if count < limit { count += 1 }
    }

    mutating func makeAll() {
        count = .max
    }
}

/// Whether the page is asked for the selected change a second time. SwiftUI sometimes drops
/// a scrollTo asked while an earlier one's glide is still running, and one asked before that
/// glide has moved the page finds its change in view and asks for nothing: either way the
/// page rests where the earlier ask was taking it, with the selected change off it. One asked
/// at rest lands, so an ask made inside a glide is made again when the scroll says the glide
/// is over. A second ask inside a glide's first frame makes the scroll say so at once, with
/// the page still to move, and that one is made again by the clock.
struct PageFollow: Equatable {
    private var lastAsk: ContinuousClock.Instant?
    /// When the scroll said it began to glide, while it says it is gliding.
    private var began: ContinuousClock.Instant?
    private var late = false

    /// Longer than Motion.move takes to bring the page to rest, 405 to 420 ms from the ask.
    static let glide = Duration.milliseconds(600)
    /// No glide is over sooner than this: a rest said earlier is the second ask's doing.
    static let shortest = Duration.milliseconds(300)

    /// The page was asked to follow the selection. True when a glide may be running, and the
    /// ask is to be made again: when the scroll rests, or `glide` from now by `waited`.
    mutating func asked(at now: ContinuousClock.Instant = .now) -> Bool {
        if began != nil || lastAsk.map({ now - $0 < Self.glide }) == true { late = true }
        lastAsk = now
        return late
    }

    /// The scroll changed phase. True when a glide with an ask inside it has come to rest,
    /// which is when to ask again.
    mutating func rests(at phase: ScrollPhase, now: ContinuousClock.Instant = .now) -> Bool {
        guard phase != .animating else {
            began = now
            return false
        }
        let glided = began.map { now - $0 >= Self.shortest } ?? false
        began = nil
        // A hand on the wheel takes the page where it wants it, and it stays there.
        if phase != .idle { late = false }
        guard late, glided else { return false }
        late = false
        lastAsk = now
        return true
    }

    /// `glide` has passed since an ask that was to be made again. True when it still is, and
    /// the scroll doesn't say it glides: an ask made inside a glide that outlasts the clock
    /// can be dropped like any other, so that glide's rest is left to make it.
    mutating func waited(at now: ContinuousClock.Instant = .now) -> Bool {
        guard late, began == nil else { return false }
        late = false
        lastAsk = now
        return true
    }
}
