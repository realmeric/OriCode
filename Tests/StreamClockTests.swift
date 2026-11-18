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
    /// The time the threads read, which moves only when a test moves it: pacing follows the
    /// arrival of deltas (K-364), and a test that ticks without time passing would see every
    /// delta land in the same instant.
    private let time = TestTime()

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
            conversation.now = { [time] in time.at }
            conversation.userSent("Go")
            conversations.append(conversation)
        }
        try context.save()
        open = conversations[0]
        beside = conversations[1]
        beside.everyOtherFrame = { true }
    }

    /// A frame long after every delta held came: all of it is due, so what a frame shows is
    /// decided by the blocks and the thread beside, not by the pace.
    private func tick() {
        time.at += Conversation.behind
        clock.tick()
    }

    /// The display's next frame, `elapsed` after the last.
    private func frame(after elapsed: Duration = Conversation.frame) {
        time.at += elapsed
        clock.tick()
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
        tick()
        tick()
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
        tick()
        #expect(text(of: open) == "One two")
        #expect(text(of: beside) == "Uno dos")
    }

    @Test func theRowBesideWaitsForAFrameWithRoom() {
        delta("A", in: open)
        delta("a", in: beside)
        delta(" b", in: beside)
        #expect(text(of: beside) == "Go")
        // The open thread's new row fills this frame.
        tick()
        #expect(text(of: beside) == "Go")
        tick()
        #expect(text(of: beside) == "a b")
    }

    @Test func theThreadBesideShowsEveryOtherFrame() {
        startBoth("A", "a")
        var shown: [String?] = []
        for n in 0..<4 {
            delta(" \(n)", in: open)
            delta(" \(n)", in: beside)
            tick()
            #expect(text(of: open) == "A" + (0...n).map { " \($0)" }.joined())
            shown.append(text(of: beside))
        }
        #expect(shown == ["a", "a 0 1", "a 0 1", "a 0 1 2 3"])
    }

    @Test func theThreadBesideWaitsAFrameWhileTheOpenOneStartsABlock() {
        startBoth("A", "a")
        tick()
        delta(" more", in: beside)
        tick()
        #expect(text(of: beside) == "a more")
        delta(" Still.", in: open)
        delta(" and more", in: beside)
        tick()
        // Its turn comes as the open thread's reply starts a block, and it waits that frame out,
        delta("\n\nA second one.", in: open)
        tick()
        #expect(text(of: open) == "A Still.\n\nA second one.")
        #expect(text(of: beside) == "a more")
        // but never past the third.
        delta("\n\nA third.", in: open)
        tick()
        #expect(text(of: beside) == "a more and more")
    }

    @Test func aFrameStartsOneBlockAtMost() {
        delta("A", in: open)
        tick()
        delta("\n\nTwo.\n\nThree.", in: open)
        tick()
        #expect(text(of: open) == "A\n\nTwo.\n\n")
        tick()
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
        tick()
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
        tick()
        tick()
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
        tick()
        tick()
        tick()
        await settle()
        #expect(text(of: beside) == "b")
        #expect(!made)
        // nor in one the open thread starts a block in,
        delta("\n\nNext.", in: open)
        tick()
        await settle()
        #expect(!made)
        // nor in one the thread beside grows in,
        delta(" c", in: beside)
        tick()
        await settle()
        #expect(text(of: beside) == "b c")
        #expect(!made)
        // but in the first with room.
        delta(" On.", in: open)
        tick()
        await maker.value
        #expect(made)
        // What it left to draw fills the next frame, so the thread beside waits for the one after.
        delta(" d", in: beside)
        tick()
        #expect(text(of: beside) == "b c")
        tick()
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
        frame()
        let first = text(of: open) ?? ""
        #expect(first.count > 6 && first.count < 6 + burst.count)
        #expect(first.hasSuffix(" ") || first.hasSuffix("word"))
        for _ in 0..<40 { frame() }
        #expect(text(of: open) == "Start." + burst)
    }

    /// Claude Code's stream as it comes: a delta every 20 ms, the result straight after the last.
    /// Each frame shows more of the reply, all of it but the delta still being spread (K-364),
    /// and the turn's end has nothing left to add.
    @Test func deltasTwentyMillisecondsApartShowAsTheyCome() {
        beside.everyOtherFrame = { false }
        let words = (0..<60).map { " word\($0)" }
        var events: [(at: Double, delta: String?)] = words.enumerated().map { (Double($0.offset) * 20, $0.element) }
        events += (1...80).map { (Double($0) * 1000 / 60, nil) }
        var sent = ""
        var last = ""
        var shown = ""
        let start = time.at
        for event in events.sorted(by: { $0.at < $1.at }) where event.at <= 1180 {
            time.at = start + .microseconds(Int(event.at * 1000))
            if let text = event.delta {
                delta(text, in: open)
                sent += text
                last = text
            } else {
                let behind = shown != sent
                clock.tick()
                let now = text(of: open) ?? ""
                #expect(sent.hasPrefix(now))
                #expect(sent.count - now.count < last.count, "\(now.count) of \(sent.count) at \(event.at) ms")
                // No frame with words waiting goes by without some of them.
                #expect(!behind || now.count > shown.count, "a stop at \(event.at) ms")
                shown = now
            }
        }
        #expect(sent == words.joined())
        let before = text(of: open) ?? ""
        open.receive(EngineEvent(name: "turn.done", threadId: open.chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        #expect(open.items.compactMap(\.text).last == sent)
        // At most the last delta joined the reply in the footer's frame.
        #expect(sent.count - before.count <= words.last!.count)
    }

    /// A burst the agent held and sent at once, with its turn's end right behind it: the footer
    /// waits for the burst, which is shown whole in the next frame (K-364), and comes in the one
    /// after.
    @Test func aTurnsEndWaitsForTheBurstBeforeIt() throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        let conversation = model.conversation(for: chat)
        conversation.clock = clock
        conversation.now = { [time] in time.at }
        conversation.userSent("Go")
        let id = chat.id.uuidString
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started", "sessionId": "s"]))
        model.route(EngineEvent(name: "text", threadId: id, body: ["event": "text", "delta": "Start."]))
        let burst = String(repeating: " word", count: 200)
        model.route(EngineEvent(name: "text", threadId: id, body: ["event": "text", "delta": .string(burst)]))
        model.route(EngineEvent(name: "turn.done", threadId: id, body: ["event": "turn.done", "sessionId": "s", "stopReason": "end_turn"]))
        #expect(conversation.running)
        #expect(conversation.items.last?.text == "Start.")
        frame()
        #expect(conversation.running)
        #expect(conversation.items.compactMap(\.text).last == "Start." + burst)
        frame()
        #expect(!conversation.running)
        #expect(conversation.items.compactMap(\.text).last == "Start." + burst)
        #expect(model.behindBurst.isEmpty)
    }

    /// Out of sight the clock keeps no frames: what's held waits for the hidden beat and is shown
    /// there all at once, with nothing paced and no block counted.
    @Test func outOfSightTheClockKeepsNoFrames() {
        clock.visible = false
        open.drawn = { false }
        delta("One", in: open)
        delta(" two three four five six seven", in: open)
        #expect(clock.beat == .hidden)
        tick()
        #expect(text(of: open) == "One two three four five six seven")
        #expect(clock.beat == nil)
        clock.visible = true
        delta(" eight", in: open)
        #expect(clock.beat == .display)
    }

    /// The window out of sight: the thread streaming in it isn't drawn, the shared clock keeps
    /// the hidden beat, and hangs aren't watched for; back in sight, all three as they were.
    @Test func aHiddenWindowDrawsNothingAndWatchesNoHangs() throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        let conversation = model.conversation(for: chat)
        model.holdingForTurns = true
        model.watchHangs()
        #expect(conversation.drawn() && model.watchingHangs && StreamClock.shared.visible)
        model.windowVisible = false
        #expect(!conversation.drawn() && !conversation.everyOtherFrame())
        #expect(!model.watchingHangs && !StreamClock.shared.visible)
        model.windowVisible = true
        #expect(conversation.drawn() && model.watchingHangs && StreamClock.shared.visible)
        model.holdingForTurns = false
        model.watchHangs()
    }
}
