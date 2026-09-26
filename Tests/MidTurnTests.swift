import AppKit
import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A message sent while a turn runs: waiting, then taken up into the turn or as one of its own,
/// or handed back.
@MainActor
struct MidTurnTests {
    private let context: ModelContext
    private let chat: Chat

    init() throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        chat = Chat(project: project)
        context.insert(chat)
    }

    private func receive(_ name: String, _ body: [String: JSON] = [:], in conversation: Conversation) {
        var body = body
        body["event"] = .string(name)
        body["threadId"] = .string(chat.id.uuidString)
        conversation.receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    /// An edit that added one line to a file, as the engine reports it.
    private func edit(_ file: String, _ line: String, in conversation: Conversation) {
        let id = UUID().uuidString
        receive("tool.use", ["toolUseId": .string(id), "name": "Edit", "input": ["file_path": .string("/tmp/alpha/" + file)]], in: conversation)
        receive("tool.result", ["toolUseId": .string(id), "content": "ok", "isError": false,
                                "patch": [["oldStart": 1, "newStart": 1, "lines": [.string("+" + line)]]]], in: conversation)
    }

    private func taken(_ message: WaitingMessage, newTurn: Bool, in conversation: Conversation) {
        receive("message.taken", ["messageId": .string(message.id.uuidString), "newTurn": .bool(newTurn)], in: conversation)
    }

    private func done(waiting: Int = 0, in conversation: Conversation) {
        receive("turn.done", ["stopReason": "end_turn", "durationMs": 1000, "costUSD": 0, "waiting": .number(Double(waiting))], in: conversation)
    }

    private var footer: (Conversation) -> TurnFooter? {
        { conversation in
            if case .footer(_, let footer) = conversation.items.last { footer } else { nil }
        }
    }

    @Test func takenMidTurnItLandsAtTheEndOfTheSameTurn() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Rename the helper")
        edit("a.swift", "func renamed()", in: conversation)
        let message = conversation.sentIntoTurn("Also add a test", images: [])
        #expect(conversation.waiting.map(\.id) == [message.id])
        #expect(conversation.items.count == 2)
        taken(message, newTurn: false, in: conversation)
        #expect(conversation.waiting.isEmpty)
        #expect(conversation.items.last == .user(id: message.id, text: "Also add a test", midTurn: true))
        #expect(conversation.turn == 1)
        #expect(conversation.running)
        let stored = chat.events.first { $0.id == message.id }
        #expect(stored?.turn == 1)
    }

    @Test func theFooterCountsEditsFromBeforeAndAfterIt() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Rename the helper")
        edit("a.swift", "func renamed()", in: conversation)
        taken(conversation.sentIntoTurn("Also add a test", images: []), newTurn: false, in: conversation)
        edit("b.swift", "func testRenamed()", in: conversation)
        done(in: conversation)
        #expect(footer(conversation)?.files == 2)
        #expect(footer(conversation)?.added == 2)
        #expect(!conversation.running)
    }

    @Test func theReviewKeepsItOneTurn() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Rename the helper")
        edit("a.swift", "func renamed()", in: conversation)
        taken(conversation.sentIntoTurn("Also add a test", images: []), newTurn: false, in: conversation)
        edit("b.swift", "func testRenamed()", in: conversation)
        done(in: conversation)
        let found = Provenance(items: conversation.items) { RepoPath.relative($0, cwd: "/tmp/alpha", root: "/tmp/alpha") }
        #expect(found.prompts == [1: "Rename the helper"])
        #expect(found.turn(of: "+func renamed()", in: "a.swift") == 1)
        #expect(found.turn(of: "+func testRenamed()", in: "b.swift") == 1)
    }

    @Test func aTurnThatEndsWithMessagesWaitingKeepsTheThreadWorking() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Write about the sea")
        let message = conversation.sentIntoTurn("Now the mountains", images: [])
        done(waiting: 1, in: conversation)
        #expect(footer(conversation) != nil)
        #expect(conversation.running)
        taken(message, newTurn: true, in: conversation)
        #expect(conversation.turn == 2)
        #expect(conversation.items.last == .user(id: message.id, text: "Now the mountains"))
        #expect(conversation.running)
        done(in: conversation)
        #expect(!conversation.running)
    }

    @Test func stoppedBetweenTheTwoTurnsNothingMoreRuns() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Write about the sea")
        let message = conversation.sentIntoTurn("Now the mountains", images: [])
        done(waiting: 1, in: conversation)
        receive("message.cancelled", ["messageId": .string(message.id.uuidString)], in: conversation)
        #expect(!conversation.running)
        #expect(conversation.takeHandedBack().map(\.text) == ["Now the mountains"])
    }

    @Test func aTurnThatEndedBeforeTheMessageArrivedEndsAsUsual() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Write about the sea")
        _ = conversation.sentIntoTurn("Now the mountains", images: [])
        // The engine had nothing waiting: the message started a turn of its own instead.
        done(waiting: 0, in: conversation)
        #expect(!conversation.running)
    }

    @Test func cancelledMessagesGoBackToTheComposerInOrder() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Run the tests")
        let first = conversation.sentIntoTurn("Then lint", images: [])
        let second = conversation.sentIntoTurn("And build", images: [])
        let before = conversation.items
        // The newer one first: they come back in the order they were written, and only once
        // neither still waits.
        receive("message.cancelled", ["messageId": .string(second.id.uuidString)], in: conversation)
        #expect(conversation.returning.isEmpty)
        #expect(conversation.takeHandedBack().isEmpty)
        receive("message.cancelled", ["messageId": .string(first.id.uuidString)], in: conversation)
        #expect(conversation.waiting.isEmpty)
        #expect(conversation.items == before)
        #expect(conversation.holdsMessages)
        #expect(conversation.takeHandedBack().map(\.text) == ["Then lint", "And build"])
        #expect(conversation.takeHandedBack().isEmpty)
        #expect(!conversation.holdsMessages)
    }

    @Test func oneHandedBackWhileAnotherIsTakenComesBackOnceThatOneIs() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Run the tests")
        let first = conversation.sentIntoTurn("Then lint", images: [])
        let second = conversation.sentIntoTurn("And build", images: [])
        receive("message.cancelled", ["messageId": .string(first.id.uuidString)], in: conversation)
        #expect(conversation.returning.isEmpty)
        taken(second, newTurn: false, in: conversation)
        #expect(conversation.returning.map(\.text) == ["Then lint"])
    }

    @Test func aReplayFromTheStoreGivesTheSameItems() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Rename the helper")
        edit("a.swift", "func renamed()", in: conversation)
        taken(conversation.sentIntoTurn("Also add a test", images: []), newTurn: false, in: conversation)
        receive("text", ["delta": "Renamed it and added the test."], in: conversation)
        edit("b.swift", "func testRenamed()", in: conversation)
        done(in: conversation)
        let replayed = Conversation(chat: chat, context: context)
        #expect(replayed.items == conversation.items)
        #expect(replayed.turn == 1)
    }

    @Test func aQuitAfterAMidTurnMessageStillFindsTheTurnsAsk() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Make the file")
        receive("ask", ["requestId": "r1", "kind": "permission", "tool": "Bash", "input": ["command": "touch notes.txt"]], in: conversation)
        // After the ask, so a search for the last message that doesn't skip it misses the ask.
        taken(conversation.sentIntoTurn("Call it notes.txt", images: []), newTurn: false, in: conversation)
        conversation.quitting()
        let replayed = Conversation(chat: chat, context: context)
        #expect(replayed.waitingAsk?.requestId == "r1")
    }

    @Test func aTurnThatEndedBeforeTheMessageArrivedKeepsItsFooterBeforeIt() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Rename the helper")
        edit("a.swift", "func renamed()", in: conversation)
        let message = conversation.sentIntoTurn("Also add a test", images: [])
        // The engine got the message after the turn's result: turn.done first, then the message
        // starting a turn of its own.
        done(waiting: 0, in: conversation)
        taken(message, newTurn: true, in: conversation)
        guard case .footer(_, let footer) = conversation.items[conversation.items.count - 2] else {
            Issue.record("No footer before the message")
            return
        }
        #expect(footer.files == 1)
        #expect(conversation.items.last == .user(id: message.id, text: "Also add a test"))
        #expect(conversation.turn == 2)
        #expect(conversation.running)
        let stored = chat.events.first { $0.id == message.id }
        #expect(stored?.turn == 2)
    }

    @Test func imagesSentAloneComeBackWithoutTheQuestionPutWithThem() throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Look at the layout")
        let image = try #require(ImageAttachment(image: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }))
        let message = conversation.sentIntoTurn("What's in this image?", typed: "", images: [image])
        #expect(conversation.waiting.first?.text == "What's in this image?")
        receive("message.cancelled", ["messageId": .string(message.id.uuidString)], in: conversation)
        let back = conversation.takeHandedBack()
        #expect(back.map(\.text) == [""])
        #expect(back.flatMap(\.images) == [image])
    }

    @Test func blocksAMessageIntoTheTurnCarriesAreReadOnlyOnceClaudeTakesItUp() async throws {
        let (model, chat, container) = try thread()
        defer { withExtendedLifetime(container) {} }
        let block = try #require(model.runCommand("echo from the shell"))
        for _ in 0..<100 where block.running || !block.text.hasSuffix("from the shell") { try await Task.sleep(for: .milliseconds(50)) }
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run it")
        #expect(model.send("and this"))
        let message = try #require(conversation.waiting.last)
        // Taken up before the send's reply, which with no engine here is a failure.
        model.route(EngineEvent(name: "message.taken", threadId: chat.id.uuidString,
                                body: ["event": "message.taken", "messageId": .string(message.id.uuidString), "newTurn": false]))
        #expect(model.withShells("next", in: chat).text == "next")
        #expect(model.shellReads.isEmpty)
        // The failed send's note, written before the store goes with the test.
        for _ in 0..<100 where !conversation.items.contains(where: { if case .note = $0 { true } else { false } }) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func blocksAHandedBackMessageCarriedStayUnread() async throws {
        let (model, chat, container) = try thread()
        defer { withExtendedLifetime(container) {} }
        let block = try #require(model.runCommand("echo from the shell"))
        for _ in 0..<100 where block.running || !block.text.hasSuffix("from the shell") { try await Task.sleep(for: .milliseconds(50)) }
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run it")
        #expect(model.send("and this"))
        #expect(conversation.waiting.count == 1)
        // No engine runs here, so the send fails and the message comes back.
        for _ in 0..<100 where !conversation.waiting.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(conversation.returning.map(\.text) == ["and this"])
        #expect(model.shellReads.isEmpty)
        #expect(model.withShells("next", in: chat).text.hasPrefix("<bash-input>echo from the shell</bash-input>"))
    }

    /// A model with one thread open, on an in-memory store.
    private func thread() throws -> (AppModel, Chat, ModelContainer) {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        return (model, chat, container)
    }
}
