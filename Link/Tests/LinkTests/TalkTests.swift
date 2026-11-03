import Foundation
import Testing
@testable import Link

@Suite struct TalkTests {
    private func line(_ id: String, _ kind: TalkLine.Kind = .agent, _ text: String = "x") -> TalkLine {
        TalkLine(id: id, kind: kind, text: text)
    }

    @Test func pagesFillUpAndCutInTheSamePlace() {
        let lines = (0..<30).map { line("\($0)", .agent, String(repeating: "a", count: 10_000)) }
        let pages = Talk.cut(lines)
        #expect(pages.first == 0..<4)
        #expect(pages.flatMap { Array($0) } == Array(0..<30))
        // A line more leaves every finished page where it was.
        #expect(Array(Talk.cut(lines + [line("30")]).dropLast()) == Array(pages.dropLast()))
    }

    @Test func aLineLongerThanAPageIsAPageOfItsOwn() {
        let long = line("long", .agent, String(repeating: "a", count: Talk.pageBytes * 3))
        #expect(Talk.cut([line("a"), long, line("b")]) == [0..<1, 1..<2, 2..<3])
    }

    @Test func aPageIsWellUnderCloudKitsLimit() throws {
        let lines = (0..<400).map { line("\($0)", .tools, "Read App/Conversation.swift") }
        for page in Talk.cut(lines) {
            let box = try JSONEncoder().encode(TalkPage(thread: UUID(), index: 0, lines: Array(lines[page])))
            #expect(box.count < 150_000)
        }
    }

    @Test func pagesMergeInOrderAndALineStandsOnce() {
        let merged = Talk.merged([1: [line("c"), line("d")], 0: [line("a"), line("b"), line("c")]])
        #expect(merged.map(\.id) == ["a", "b", "c", "d"])
    }

    @Test func aSentMessageGoesWhenTheTranscriptCarriesIt() {
        let sent = [Talk.Outgoing(id: "s", text: "go on", after: "m1")]
        #expect(Talk.carried(sent, in: [line("m1", .mine, "hello")]).isEmpty)
        #expect(Talk.carried(sent, in: [line("m1", .mine, "hello"), line("r"), line("m2", .mine, "go on")]) == ["s"])
    }

    @Test func aRepeatedMessageIsNotTakenForAnOlderOne() {
        let lines = [line("m1", .mine, "ok"), line("r"), line("m2", .mine, "ok")]
        // Sent after m2: the "ok"s the thread held then are older words.
        #expect(Talk.carried([.init(id: "s", text: "ok", after: "m2")], in: lines).isEmpty)
        #expect(Talk.carried([.init(id: "s", text: "ok", after: "m1")], in: lines) == ["s"])
        // Two sent alike, one carried: the older goes.
        let two = [Talk.Outgoing(id: "a", text: "ok", after: "m1"), .init(id: "b", text: "ok", after: "m1")]
        #expect(Talk.carried(two, in: lines) == ["a"])
    }

    @Test func aFirstMessageIsCarriedByATask() {
        #expect(Talk.carried([.init(id: "s", text: "do it", after: nil)], in: [line("t", .task, "do it")]) == ["s"])
    }

    @Test func aLeaseEndsWhenItLapsesOrThePhoneLeaves() {
        let thread = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var leases = Leases()
        leases.take(thread, phone: "p", said: start, now: start)
        #expect(leases.threads == [thread])
        #expect(leases.nextEnd == start.addingTimeInterval(120))
        leases.expire(now: start.addingTimeInterval(119))
        #expect(leases.threads == [thread])
        leases.expire(now: start.addingTimeInterval(121))
        #expect(leases.threads.isEmpty)

        leases.take(thread, phone: "p", said: start, now: start)
        leases.take(nil, phone: "p", said: start.addingTimeInterval(5), now: start.addingTimeInterval(5))
        #expect(leases.threads.isEmpty)
        #expect(leases.nextEnd == nil)
    }

    @Test func aLateWordChangesNothing() {
        let thread = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        var leases = Leases()
        leases.take(thread, phone: "p", said: start.addingTimeInterval(10), now: start.addingTimeInterval(10))
        // Read after the word that followed it.
        let late = leases.take(nil, phone: "p", said: start, now: start.addingTimeInterval(10))
        #expect(!late)
        #expect(leases.threads == [thread])
        // Lapsed before it was read, the Mac asleep meanwhile.
        var fresh = Leases()
        let lapsed = fresh.take(thread, phone: "p", said: start, now: start.addingTimeInterval(200))
        #expect(!lapsed)
        #expect(fresh.threads.isEmpty)
    }

    @MainActor @Test func aRowStaysItselfAndOnlyANewRowChangesTheList() {
        let id = UUID()
        let talk = ThreadTalk(thread: id)
        talk.take(TalkPage(thread: id, index: 4, lines: [line("a", .agent, "one")]))
        let rows = talk.rows
        talk.take(TalkPage(thread: id, index: 4, lines: [line("a", .agent, "one two")]))
        #expect(talk.rows[0] === rows[0])
        #expect(talk.rows[0].line.text == "one two")
        talk.take(TalkPage(thread: id, index: 5, lines: [line("b")]))
        #expect(talk.rows.map(\.id) == ["a", "b"])
        #expect(talk.first == 4 && talk.last == 5)
    }

    @MainActor @Test func earlierPagesAreAskedForOnceAndReachTheStart() {
        let id = UUID()
        let talk = ThreadTalk(thread: id)
        #expect(talk.askEarlier() == nil)
        talk.take(TalkPage(thread: id, index: 4, lines: [line("e")]))
        #expect(talk.askEarlier() == 1)
        #expect(talk.askEarlier() == nil)
        talk.take(TalkPage(thread: id, index: 3, lines: [line("d")]))
        #expect(talk.asked == 1)
        talk.take(TalkPage(thread: id, index: 1, lines: [line("b")]))
        #expect(talk.asked == nil)
        #expect(talk.askEarlier() == 0)
        talk.take(TalkPage(thread: id, index: 0, lines: [line("a")]))
        #expect(!talk.hasEarlier)
        #expect(talk.rows.first?.id == "a")
    }
}
