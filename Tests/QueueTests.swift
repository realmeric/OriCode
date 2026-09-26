import AppKit
import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Messages written while a turn runs, waiting for it to end.
@MainActor
struct QueueTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        chat = Chat(project: project)
        context.insert(chat)
    }

    /// A conversation with a turn running and the given messages queued behind it.
    private func running(queued texts: [String]) -> Conversation {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Run the tests")
        for text in texts { conversation.enqueue(text) }
        return conversation
    }

    private func done(_ stopReason: String, in chat: Chat? = nil) -> EngineEvent {
        EngineEvent(name: "turn.done", threadId: (chat ?? self.chat).id.uuidString, body: ["stopReason": .string(stopReason)])
    }

    private func lastSent(in conversation: Conversation) -> String? {
        for item in conversation.items.reversed() {
            if case .user(_, let text, _, _) = item { return text }
        }
        return nil
    }

    @Test func messagesWaitInTheOrderWritten() {
        let conversation = running(queued: ["one", "two", "three"])
        #expect(conversation.queue.map(\.text) == ["one", "two", "three"])
    }

    @Test func aFinishedTurnSendsOnlyTheFirst() {
        let conversation = running(queued: ["one", "two"])
        conversation.receive(done("end_turn"))
        var sent: [String] = []
        conversation.sendNext { message in
            sent.append(message.text)
            conversation.userSent(message.text)
            return true
        }
        #expect(sent == ["one"])
        #expect(conversation.queue.map(\.text) == ["two"])
        #expect(conversation.running)
        // The second waits for the first one's turn to end, and then goes too.
        conversation.sendNext { _ in
            Issue.record("sent while a turn runs")
            return true
        }
        conversation.receive(done("max_tokens"))
        conversation.sendNext { sent.append($0.text); return true }
        #expect(sent == ["one", "two"])
        #expect(conversation.queue.isEmpty)
        #expect(conversation.handedBack.isEmpty)
    }

    @Test(arguments: ["interrupted", "engine_stopped", "error_during_execution", "error_max_turns"])
    func aTurnThatDidntEndByItselfHandsEverythingBack(stopReason: String) {
        let conversation = running(queued: ["one", "two"])
        conversation.receive(done(stopReason))
        conversation.sendNext { _ in
            Issue.record("sent after \(stopReason)")
            return true
        }
        #expect(conversation.queue.isEmpty)
        #expect(conversation.takeHandedBack().map(\.text) == ["one", "two"])
        #expect(conversation.handedBack.isEmpty)
    }

    @Test func anErrorBeforeTheEndMakesItAFailedTurn() {
        let conversation = running(queued: ["one"])
        conversation.receive(EngineEvent(name: "error", threadId: chat.id.uuidString, body: ["message": "Broke"]))
        conversation.receive(done("end_turn"))
        #expect(conversation.queue.isEmpty)
        #expect(conversation.handedBack.map(\.text) == ["one"])
        // The next message starts clean.
        conversation.userSent("Again")
        conversation.enqueue("two")
        conversation.receive(done("end_turn"))
        #expect(conversation.queue.map(\.text) == ["two"])
    }

    /// Claude's session limit refuses a turn with `limited` rather than an error, and a result that
    /// reads as a finish; the next message would be refused too.
    @Test func aTurnTheLimitRefusedHandsBack() {
        let conversation = running(queued: ["one", "two"])
        conversation.receive(EngineEvent(name: "limited", threadId: chat.id.uuidString, body: [
            "resetsAt": .number(Date.now.addingTimeInterval(3600).timeIntervalSince1970 * 1000), "window": "five_hour",
        ]))
        // The CLI ends such a turn as a success, stopped at a stop sequence.
        conversation.receive(done("stop_sequence"))
        conversation.sendNext { _ in
            Issue.record("sent into the limit")
            return true
        }
        #expect(conversation.handedBack.map(\.text) == ["one", "two"])
    }

    /// A background agent reporting back starts a turn nobody sent, after one that failed.
    @Test func aTurnNobodySentDoesntCarryTheLastOnesError() {
        let conversation = running(queued: [])
        conversation.receive(EngineEvent(name: "error", threadId: chat.id.uuidString, body: ["message": "Broke"]))
        conversation.receive(done("error_max_turns"))
        conversation.receive(EngineEvent(name: "turn.started", threadId: chat.id.uuidString, body: [:]))
        conversation.enqueue("one")
        conversation.receive(done("end_turn"))
        var sent: [String] = []
        conversation.sendNext { sent.append($0.text); return true }
        #expect(sent == ["one"])
        #expect(conversation.handedBack.isEmpty)
    }

    /// Stop hands the queue back before the interrupt goes, so a turn already ending by itself
    /// when it lands sends nothing; what was sent into the turn comes back as the engine cancels
    /// it, and all of it comes back to the field together, in the order it was written.
    @Test func stopHandsBackTheQueueAndWhatWaitsInTheOrderWritten() throws {
        // The turn's end would post Finished from the test host.
        let notify = UserDefaults.standard.object(forKey: "notify")
        UserDefaults.standard.set(false, forKey: "notify")
        defer { UserDefaults.standard.set(notify, forKey: "notify") }
        let (model, chat) = try thread()
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        conversation.enqueue("one")
        let two = conversation.sentIntoTurn("two", images: [])
        conversation.enqueue("three")
        model.stop()
        #expect(conversation.queue.isEmpty)
        #expect(conversation.returning.isEmpty)
        // The turn ends by itself just as the interrupt goes out.
        model.route(done("end_turn", in: chat))
        #expect(lastSent(in: conversation) == "Run the tests")
        model.route(EngineEvent(name: "message.cancelled", threadId: chat.id.uuidString, body: ["messageId": .string(two.id.uuidString)]))
        #expect(lastSent(in: conversation) == "Run the tests")
        #expect(!conversation.running)
        #expect(conversation.takeHandedBack().map(\.text) == ["one", "two", "three"])
    }

    @Test func optionReturnQueuesAndReturnSendsIntoTheTurn() async throws {
        let (model, chat) = try thread()
        let conversation = model.conversation(for: chat)
        #expect(!model.queue("before any turn"))
        conversation.userSent("Run the tests")
        let image = try #require(ImageAttachment(image: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }))
        model.draftAttachments = [image]
        #expect(model.queue("  then lint  "))
        #expect(conversation.queue.map(\.text) == ["then lint"])
        #expect(conversation.queue.first?.images == [image])
        #expect(model.draftAttachments.isEmpty)
        #expect(model.send("and look at the build"))
        #expect(conversation.waiting.map(\.text) == ["and look at the build"])
        #expect(conversation.queue.count == 1)
        // No engine runs here, so the message comes back, and the queue stays for the turn's end.
        for _ in 0..<100 where !conversation.waiting.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(conversation.returning.map(\.text) == ["and look at the build"])
        #expect(conversation.queue.map(\.text) == ["then lint"])
    }

    /// The queue's next goes out only once the messages sent into the turn have run, which keeps
    /// the thread working through the turn.done between.
    @Test func theQueueWaitsForWhatWasSentIntoTheTurn() {
        let conversation = running(queued: ["one"])
        let message = conversation.sentIntoTurn("two", images: [])
        conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["stopReason": "end_turn", "waiting": 1]))
        #expect(conversation.running)
        conversation.sendNext { _ in
            Issue.record("sent while a message waited")
            return true
        }
        conversation.receive(EngineEvent(name: "message.taken", threadId: chat.id.uuidString,
                                         body: ["messageId": .string(message.id.uuidString), "newTurn": true]))
        conversation.receive(done("end_turn"))
        var sent: [String] = []
        conversation.sendNext { sent.append($0.text); return true }
        #expect(sent == ["one"])
    }

    /// Sent just as the turn ended, a message reaches the engine after it and starts a turn of
    /// its own; the queue doesn't go out in between.
    @Test func theQueueWaitsForAMessageStillOnItsWay() {
        let conversation = running(queued: ["one"])
        _ = conversation.sentIntoTurn("two", images: [])
        conversation.receive(done("end_turn"))
        #expect(!conversation.running)
        conversation.sendNext { _ in
            Issue.record("sent ahead of the message on its way")
            return true
        }
        #expect(conversation.queue.map(\.text) == ["one"])
    }

    /// A model on the in-memory store with one thread open.
    private func thread() throws -> (AppModel, Chat) {
        let project = Project(name: "beta", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let open = Chat(project: project)
        container.mainContext.insert(open)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = open.id
        return (model, open)
    }

    @Test func theEngineStoppingAndAFailedSendHandBackToo() {
        let conversation = running(queued: ["one"])
        conversation.stopped()
        #expect(conversation.handedBack.map(\.text) == ["one"])
        let failed = running(queued: ["two"])
        failed.sendFailed("The engine isn't running.")
        #expect(failed.handedBack.map(\.text) == ["two"])
    }

    @Test func whatEndedByItself() {
        #expect(QueuedMessage.endedByItself("end_turn", failed: false))
        #expect(QueuedMessage.endedByItself("max_tokens", failed: false))
        #expect(QueuedMessage.endedByItself(nil, failed: false))
        #expect(!QueuedMessage.endedByItself("end_turn", failed: true))
        #expect(!QueuedMessage.endedByItself("interrupted", failed: false))
        #expect(!QueuedMessage.endedByItself("engine_stopped", failed: false))
        #expect(!QueuedMessage.endedByItself("error_during_execution", failed: false))
    }

    @Test func takeBackAndRemove() {
        let conversation = running(queued: ["one", "two", "three"])
        let two = conversation.queue[1]
        #expect(conversation.takeBack(two.id)?.text == "two")
        #expect(conversation.takeBack(two.id) == nil)
        conversation.removeQueued(conversation.queue[0].id)
        #expect(conversation.queue.map(\.text) == ["three"])
        #expect(conversation.handedBack.isEmpty)
    }

    @Test func textGoesBackPartedByBlankLines() {
        #expect(QueuedMessage.joined(["typed", "two\nlines"]) == "typed\n\ntwo\nlines")
        #expect(QueuedMessage.joined(["", "one", "  \n", "two"]) == "one\n\ntwo")
        #expect(QueuedMessage(text: "First line\nsecond").line == "First line")
    }

    @Test func aRefusedSendHandsBackWithTheRest() {
        let conversation = running(queued: ["one", "two"])
        conversation.receive(done("end_turn"))
        conversation.sendNext { _ in false }
        #expect(conversation.queue.isEmpty)
        #expect(conversation.handedBack.map(\.text) == ["one", "two"])
    }

    /// Through the app's own routing, with no engine running, so nothing reaches Claude and the
    /// engine turns the send down.
    @Test func aThreadNotOnScreenSendsItsNextToo() async {
        // The notification a turned-down send posts is off, so the test host posts nothing.
        let notify = UserDefaults.standard.object(forKey: "notify")
        UserDefaults.standard.set(false, forKey: "notify")
        defer { UserDefaults.standard.set(notify, forKey: "notify") }
        let model = AppModel(container: container)
        let project = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(project)
        let away = Chat(project: project)
        container.mainContext.insert(away)
        #expect(model.chat?.id != away.id)
        let conversation = model.conversation(for: away)
        conversation.userSent("Run the tests")
        conversation.enqueue("one")
        conversation.enqueue("two")
        model.route(done("end_turn", in: away))
        #expect(lastSent(in: conversation) == "one")
        #expect(conversation.running)
        #expect(conversation.queue.map(\.text) == ["two"])
        // Turned down, the send ends the thread's work and the rest goes back to the field.
        for _ in 0..<100 where conversation.running {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!conversation.running)
        #expect(conversation.handedBack.map(\.text) == ["two"])
    }
}
