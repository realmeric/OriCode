import CoreGraphics
import Testing
@testable import OriCode

struct EffortTrackTests {
    let five = EffortTrack(levels: ["low", "medium", "high", "xhigh", "max"], start: 17, end: 311)
    let six = EffortTrack(levels: ["low", "medium", "high", "xhigh", "max", "ultracode"], start: 17, end: 311)

    @Test func stopsRunEndToEndWithAWiderStepBeforeUltracode() {
        #expect(five.positions.first == 17)
        #expect(five.positions.last == 311)
        let xs = six.positions
        #expect(xs.last == 311)
        let step = xs[1] - xs[0]
        #expect(abs((xs[5] - xs[4]) - step * 1.4) < 0.001)
    }

    @Test func theThumbSticksNearAStopAndMeetsTheNextHalfway() {
        let xs = five.positions
        #expect(five.follow(xs[2] + 8, holding: 2) == (xs[2] + 2, 2))
        let midpoint = (xs[2] + xs[3]) / 2
        #expect(abs(five.follow(midpoint - 0.001, holding: 2).x - midpoint) < 0.01)
        #expect(five.follow(midpoint + 1, holding: 2).stop == 3)
    }

    @Test func theEndsGiveALittle() {
        #expect(five.follow(-100, holding: 0) == (17 - EffortTrack.give, 0))
        #expect(five.follow(400, holding: 4) == (311 + EffortTrack.give, 4))
    }

    @Test func ultracodeWaitsForThePointerAndLetsGoLater() {
        let xs = six.positions
        #expect(six.follow(xs[5] - 20, holding: 4).stop == 4)
        #expect(six.follow(xs[5] - 10, holding: 4).stop == 5)
        #expect(six.follow(xs[5] - 30, holding: 5).stop == 5)
        #expect(six.follow(xs[5] - 40, holding: 5).stop == 4)
    }

    @Test func aFlickCarriesOneStopAndNeverOntoMaxOrUltracode() {
        let xs = six.positions
        #expect(six.settle(xs[1], velocity: 2400, holding: 1) == 2)
        #expect(six.settle(xs[1], velocity: 0, holding: 1) == 1)
        #expect(six.settle(xs[3], velocity: 2400, holding: 3) == 3)
        #expect(six.settle(xs[4], velocity: 2400, holding: 4) == 4)
        #expect(six.settle(xs[4], velocity: -2400, holding: 4) == 3)
        #expect(six.settle(xs[5] - 30, velocity: -800, holding: 5) == 4)
    }

    @Test func aBlockedUltracodeNeverOpens() {
        var blocked = six
        blocked.blocked = true
        let xs = blocked.positions
        #expect(blocked.follow(xs[5], holding: 4).stop == 4)
        #expect(blocked.follow(xs[5] + 20, holding: 4).stop == 4)
    }
}
