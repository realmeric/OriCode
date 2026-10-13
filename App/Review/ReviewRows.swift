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
