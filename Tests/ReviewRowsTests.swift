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
