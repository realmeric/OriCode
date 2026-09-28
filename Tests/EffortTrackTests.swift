import CoreGraphics
import Testing
@testable import OriCode

struct EffortTrackTests {
    let five = EffortTrack(levels: ["low", "medium", "high", "xhigh", "max"], start: 17, end: 311)

    @Test func stopsRunEndToEndInEvenSteps() {
        let xs = five.positions
        #expect(xs.first == 17)
        #expect(xs.last == 311)
        #expect(xs.indices.dropFirst().allSatisfy { abs((xs[$0] - xs[$0 - 1]) - 73.5) < 0.001 })
    }

    @Test func theThumbSticksNearAStopAndMeetsTheNextHalfway() {
        let xs = five.positions
        #expect(five.follow(xs[2] + 8) == (xs[2] + 2, 2))
        let midpoint = (xs[2] + xs[3]) / 2
        #expect(abs(five.follow(midpoint - 0.001).x - midpoint) < 0.01)
        #expect(five.follow(midpoint + 1).stop == 3)
    }

    @Test func theEndsGiveALittle() {
        #expect(five.follow(-100) == (17 - EffortTrack.give, 0))
        #expect(five.follow(400) == (311 + EffortTrack.give, 4))
    }

    @Test func aFlickCarriesOneStopAndNeverOntoMax() {
        let xs = five.positions
        #expect(five.settle(xs[1], velocity: 2400, holding: 1) == 2)
        #expect(five.settle(xs[1], velocity: 0, holding: 1) == 1)
        #expect(five.settle(xs[3], velocity: 2400, holding: 3) == 3)
        #expect(five.settle(xs[4], velocity: -2400, holding: 4) == 3)
    }
}
