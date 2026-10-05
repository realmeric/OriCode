import Foundation
import Testing
@testable import OriCode

struct ActivityTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    @Test func aTurnsTokensAreEverythingItReadAndWrote() {
        let payload = Data(#"{"event":"turn.done","usage":{"input":1200,"output":300,"cacheRead":50000,"cacheWrite":800},"costUSD":0.1}"#.utf8)
        #expect(TokenActivity.tokens(in: payload) == 52_300)
        #expect(TokenActivity.tokens(in: Data(#"{"event":"turn.done","stopReason":"interrupted"}"#.utf8)) == 0)
        #expect(TokenActivity.tokens(in: Data()) == 0)
    }

    @Test func daysAddUpAndTheSpanKeepsTheQuietOnes() {
        let days = TokenActivity.days([(date(1, hour: 9), 100), (date(1, hour: 23), 50), (date(3), 1000), (date(4), 0)], calendar: calendar)
        #expect(days.count == 2 && days[calendar.startOfDay(for: date(1))] == 150)
        // Two weeks ending Sunday the 4th, weeks starting on Monday: the 21st of September on.
        let span = TokenActivity.span(days, weeks: 2, until: date(4), calendar: calendar)
        #expect(span.count == 14)
        #expect(span.first?.weekday == 0 && span.last?.weekday == 6)
        #expect(span.map(\.tokens).suffix(4) == [150, 0, 1000, 0])
        #expect(span.last?.total == 1150)
        #expect(Set(span.map(\.week)).count == 2)
    }

    @Test func tokenCountsAreShort() {
        #expect(TokenActivity.short(640) == "640")
        #expect(TokenActivity.short(12_300) == "12.3K")
        #expect(TokenActivity.short(108_400_000) == "108.4M")
        #expect(TokenActivity.short(2_500_000_000) == "2.5B")
    }
}
