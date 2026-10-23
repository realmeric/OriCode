import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Two threads streaming at once, shown at the display's frame, with one costly thing a frame
/// past the open thread's stream.
@MainActor
struct StreamClockTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let open: Conversation
    private let beside: Conversation
    private let clock = StreamClock(manual: true)

    init() throws {
        container = try TestStore.memory()
        context = container.mainContext
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        var conversations: [Conversation] = []
        for _ in 0..<2 {
            let chat = Chat(project: project)
            chat.started = true
            context.insert(chat)
            let conversation = Conversation(chat: chat, context: context)
            conversation.clock = clock
            conversation.userSent("Go")
            conversations.append(conversation)
        }
        try context.save()
        open = conversations[0]
        beside = conversations[1]
        beside.everyOtherFrame = { true }
    }

    private func delta(_ text: String, in conversation: Conversation) {
        conversation.receive(EngineEvent(name: "text", threadId: conversation.chat.id.uuidString, body: ["event": "text", "delta": .string(text)]))
    }

    private func text(of conversation: Conversation) -> String? {
        conversation.items.last?.text
    }

    /// Both replies started: the open thread's row at once, the one beside's two frames later,
    /// after the frame the first row fills.
    private func startBoth(_ first: String, _ second: String) {
        delta(first, in: open)
        delta(second, in: beside)
        clock.tick()
        clock.tick()
    }

    @Test func deltasWaitForTheFrameAndBothThreadsShowInIt() {
        beside.everyOtherFrame = { false }
        delta("One", in: open)
        delta("Uno", in: beside)
        delta(" two", in: open)
        delta(" dos", in: beside)
        // The first makes the reply's item; the rest wait for the frame.
        #expect(text(of: open) == "One")
        #expect(text(of: beside) == "Uno")
        clock.tick()
        #expect(text(of: open) == "One two")
        #expect(text(of: beside) == "Uno dos")
    }

    @Test func theRowBesideWaitsForAFrameWithRoom() {
        delta("A", in: open)
        delta("a", in: beside)
        delta(" b", in: beside)
        #expect(text(of: beside) == "Go")
        // The open thread's new row fills this frame.
        clock.tick()
        #expect(text(of: beside) == "Go")
        clock.tick()
        #expect(text(of: beside) == "a b")
    }

    @Test func theThreadBesideShowsEveryOtherFrame() {
        startBoth("A", "a")
        var shown: [String?] = []
        for n in 0..<4 {
            delta(" \(n)", in: open)
            delta(" \(n)", in: beside)
            clock.tick()
            #expect(text(of: open) == "A" + (0...n).map { " \($0)" }.joined())
            shown.append(text(of: beside))
        }
        #expect(shown == ["a", "a 0 1", "a 0 1", "a 0 1 2 3"])
    }

    @Test func theThreadBesideWaitsAFrameWhileTheOpenOneStartsABlock() {
        startBoth("A", "a")
        clock.tick()
        delta(" more", in: beside)
        clock.tick()
        #expect(text(of: beside) == "a more")
        delta(" Still.", in: open)
        delta(" and more", in: beside)
        clock.tick()
        // Its turn comes as the open thread's reply starts a block, and it waits that frame out,
        delta("\n\nA second one.", in: open)
        clock.tick()
        #expect(text(of: open) == "A Still.\n\nA second one.")
        #expect(text(of: beside) == "a more")
        // but never past the third.
        delta("\n\nA third.", in: open)
        clock.tick()
        #expect(text(of: beside) == "a more and more")
    }

    @Test func aFrameStartsOneBlockAtMost() {
        delta("A", in: open)
        clock.tick()
        delta("\n\nTwo.\n\nThree.", in: open)
        clock.tick()
        #expect(text(of: open) == "A\n\nTwo.\n\n")
        clock.tick()
        #expect(text(of: open) == "A\n\nTwo.\n\nThree.")
    }

    @Test func whatWaitsIsAllWrittenBeforeASave() {
        delta("A", in: open)
        delta("\n\nTwo.\n\nThree.", in: open)
        delta("a", in: beside)
        delta(" b", in: beside)
        open.flush()
        beside.flush()
        #expect(text(of: open) == "A\n\nTwo.\n\nThree.")
        #expect(text(of: beside) == "a b")
        #expect(Conversation(chat: beside.chat, context: context).items.last?.text == "a b")
    }

    @Test func aReplyWhoseRowWaitedStaysOneRowWhenThePacingStops() {
        delta("a", in: beside)
        // The open thread's turn ends before the row is made.
        beside.everyOtherFrame = { false }
        delta(" b", in: beside)
        clock.tick()
        delta(" c", in: beside)
        beside.flush()
        #expect(beside.items.compactMap(\.text) == ["Go", "a b c"])
        #expect(Conversation(chat: beside.chat, context: context).items.compactMap(\.text) == ["Go", "a b c"])
    }

    @Test func aCommandStartedWhileTheRowWaitsLeavesTheReplyAboveIt() {
        delta("Before", in: beside)
        beside.shellStarted(ShellRun(command: "ls", folder: "/tmp/alpha"), id: UUID())
        delta(" and after", in: beside)
        beside.flush()
        let items = Conversation(chat: beside.chat, context: context).items
        #expect(items.compactMap(\.text) == ["Go", "Before and after"])
        guard case .shell = items.last else {
            Issue.record("The block isn't last")
            return
        }
    }

    @Test func aDeletedThreadsWaitingRowIsNeverRecorded() {
        delta("a", in: beside)
        beside.forget()
        clock.tick()
        clock.tick()
        #expect(beside.items.compactMap(\.text) == ["Go"])
        #expect(!context.hasChanges)
    }

    @Test func aBlockIsMadeAgainInAFrameWithRoom() async {
        nonisolated(unsafe) var made = false
        delta("A paragraph.", in: open)
        delta("b", in: beside)
        let maker = Task { @MainActor in
            await clock.frameToMake()
            made = true
        }
        func settle() async { for _ in 0..<5 { await Task.yield() } }
        await settle()
        // Not in a frame a row is added in,
        clock.tick()
        clock.tick()
        clock.tick()
        await settle()
        #expect(text(of: beside) == "b")
        #expect(!made)
        // nor in one the open thread starts a block in,
        delta("\n\nNext.", in: open)
        clock.tick()
        await settle()
        #expect(!made)
        // nor in one the thread beside grows in,
        delta(" c", in: beside)
        clock.tick()
        await settle()
        #expect(text(of: beside) == "b c")
        #expect(!made)
        // but in the first with room.
        delta(" On.", in: open)
        clock.tick()
        await maker.value
        #expect(made)
        // What it left to draw fills the next frame, so the thread beside waits for the one after.
        delta(" d", in: beside)
        clock.tick()
        #expect(text(of: beside) == "b c")
        clock.tick()
        #expect(text(of: beside) == "b c d")
    }

    @Test func aBlockWhoseViewGoesAwayStopsWaiting() async {
        let maker = Task { @MainActor in await clock.frameToMake() }
        for _ in 0..<5 { await Task.yield() }
        maker.cancel()
        await maker.value
    }

    @Test func theThreadBesideIsDueEveryOtherFrameAndAtTheLatestTheThird() {
        #expect(!StreamClock.besideShows(since: 1, busy: false))
        #expect(StreamClock.besideShows(since: 2, busy: false))
        #expect(!StreamClock.besideShows(since: 2, busy: true))
        #expect(StreamClock.besideShows(since: 3, busy: true))
        // Not shown lately, it's due unless the frame is full.
        #expect(StreamClock.besideShows(since: nil, busy: false))
        #expect(!StreamClock.besideShows(since: nil, busy: true))
    }

    @Test func aBurstIsShownOverTheNextFramesWordByWord() {
        beside.everyOtherFrame = { false }
        delta("Start.", in: open)
        let burst = String(repeating: " word", count: 120)
        delta(burst, in: open)
        clock.tick()
        let first = text(of: open) ?? ""
        #expect(first.count > 6 && first.count < 6 + burst.count)
        #expect(first.hasSuffix(" ") || first.hasSuffix("word"))
        for _ in 0..<40 { clock.tick() }
        #expect(text(of: open) == "Start." + burst)
    }
}
