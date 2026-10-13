import SwiftUI
import Testing
@testable import OriCode

/// The review's count of rows made.
struct ReviewRowsTests {
    @Test func aRowIsMadeAtATimeUpToTheLimit() {
        var made = MadeRows(count: 2)
        made.makeOne(of: 4)
        #expect(made.count == 3)
        made.makeOne(of: 4)
        made.makeOne(of: 4)
        #expect(made.count == 4)
    }

    /// J while the rows were still being made set the count to its most, and the task that had
    /// slept through the key added one to it: an overflow, and the app was gone.
    @Test func aKeyThatMakesEveryRowLeavesTheSleepingTaskNothingToAdd() {
        var made = MadeRows(count: 3)
        made.makeAll()
        made.makeOne(of: 16)
        #expect(made == .all)
        made.makeOne(of: .max)
        #expect(made == .all)
    }

    /// Legacy's count stopped at the rows there were, and a file opened after that had its
    /// changes cut from the page's end.
    @Test func rowsThatComeAfterEveryRowIsMadeAreOnThePage() {
        var made = MadeRows(count: 2)
        made.makeAll()
        #expect(Array((0..<40).prefix(made.count)).count == 40)
    }
}

/// Which of the review's asks for the selected change are made a second time, and when.
struct PageFollowTests {
    private enum Step {
        /// The selection moved, so many ms in.
        case ask(Int)
        case phase(ScrollPhase, Int)
        /// The wait after a late ask ran out.
        case clock(Int)
    }

    /// What each step answered: for an ask whether it is late, for the others whether to ask again.
    private func answers(_ steps: [Step]) -> [Bool] {
        var follow = PageFollow()
        let start = ContinuousClock.now
        return steps.map { step in
            switch step {
            case .ask(let ms): follow.asked(at: start + .milliseconds(ms))
            case .phase(let phase, let ms): follow.rests(at: phase, now: start + .milliseconds(ms))
            case .clock(let ms): follow.waited(at: start + .milliseconds(ms))
            }
        }
    }

    @Test func anAskAtRestIsMadeOnce() {
        let slow: [Step] = [.ask(0), .phase(.animating, 4), .phase(.idle, 410), .ask(700), .phase(.animating, 704), .phase(.idle, 1110), .clock(1300)]
        #expect(answers(slow) == [false, false, false, false, false, false, false])
    }

    /// J and then K inside J's glide: K's ask was dropped, and the page rested on the change
    /// J went to with the keyboard back on the one before.
    @Test(arguments: [20, 50, 100, 200, 300, 400]) func anAskInsideAGlideIsMadeAgainWhenThePageRests(gap: Int) {
        let keys: [Step] = [.ask(0), .phase(.animating, 4), .ask(gap), .phase(.idle, 410)]
        #expect(answers(keys) == [false, false, true, true])
        // The second glide has no ask inside it, and the clock finds nothing left to ask.
        #expect(answers(keys + [.phase(.animating, 414), .phase(.idle, 820), .clock(gap + 600)]).suffix(3) == [false, false, false])
    }

    /// K inside the first frame of J's glide: the scroll says it rests 2 ms after K, and J's
    /// glide runs on with nothing more said.
    @Test func aRestSaidAsAGlideBeginsIsNotBelieved() {
        #expect(answers([.ask(0), .phase(.animating, 4), .ask(12), .phase(.idle, 14), .clock(612), .clock(1212)]) == [false, false, true, false, true, false])
    }

    /// K before the scroll has said J's glide began.
    @Test func anAskJustAfterAnotherIsInsideItsGlide() {
        #expect(answers([.ask(0), .ask(3), .phase(.animating, 5), .phase(.idle, 412)]) == [false, true, false, true])
    }

    /// The ask made again glides too, and a key inside that glide is followed like any other.
    @Test func theAskMadeAgainCountsAsAnAsk() {
        let keys: [Step] = [.ask(0), .phase(.animating, 4), .ask(100), .phase(.idle, 410), .ask(415), .phase(.animating, 416), .phase(.idle, 825)]
        #expect(answers(keys) == [false, false, true, true, true, false, true])
    }

    /// Tab's glide to a file far down outlasts the clock, and ⇧Tab inside it is still late.
    @Test func anAskInsideALongGlideIsLateWhateverTheClockSays() {
        #expect(answers([.ask(0), .phase(.animating, 4), .ask(640), .phase(.idle, 700)]) == [false, false, true, true])
    }

    /// Tab and then ⇧Tab on a book whose far glide is still running when the clock fires: an
    /// ask made there could be dropped, so it waits for the rest.
    @Test func theClockLeavesAGlideStillRunningToItsRest() {
        #expect(answers([.ask(0), .phase(.animating, 4), .ask(30), .clock(630), .phase(.idle, 900)]) == [false, false, true, false, true])
    }

    @Test func aHandOnTheWheelKeepsThePageWhereItPutIt() {
        let keys: [Step] = [.ask(0), .phase(.animating, 4), .ask(100), .phase(.interacting, 150), .phase(.idle, 600), .clock(700)]
        #expect(answers(keys) == [false, false, true, false, false, false])
    }
}
