import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A message too long for its model, and a session the model can't be sent again (K-289).
@MainActor
struct SpentSessionTests {
    private let container: ModelContainer
    private let project: Project

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
    }

    private func thread(in model: AppModel) throws -> Chat {
        model.engineState = .ready
        let chat = Chat(project: project)
        chat.model = "haiku"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        return chat
    }

    private static func haiku(window: Int?) -> ModelOption {
        ModelOption(id: "haiku", name: "Haiku 5.5", description: "", efforts: [], fast: false, defaultEffort: nil, ultra: false,
                    ultraBlocked: nil, more: nil, needs: nil, window: window)
    }

    /// Over twice the model's window the message stays in the composer with one line that says
    /// why; at twice the window it goes.
    @Test func aMessageOverTwiceTheWindowIsSaidAndNotSent() async throws {
        let model = AppModel(container: container)
        model.models = [Self.haiku(window: 1_000_000)]
        let chat = try thread(in: model)
        let conversation = model.conversation(for: chat)
        #expect(!model.send(String(repeating: "a", count: 2_000_001), in: chat))
        #expect(conversation.items.isEmpty)
        #expect(model.note == "Haiku 5.5 reads about \(2_000_000.formatted()) characters. This has \(2_000_001.formatted()).")
        #expect(model.send(String(repeating: "a", count: 2_000_000), in: chat))
        #expect(conversation.items.count == 1)
        // No engine runs here, so the send fails; its note lands before the store goes.
        for _ in 0..<60 where conversation.running { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// With no window in the model's row, the one the thread's last turn reported is the line.
    @Test func aWindowATurnReportedIsTheLineWhenTheModelGivesNone() throws {
        let model = AppModel(container: container)
        model.models = [Self.haiku(window: nil)]
        let chat = try thread(in: model)
        #expect(model.whyTooLong(String(repeating: "a", count: 500_000), for: chat) == nil)
        chat.contextWindow = 200_000
        #expect(model.whyTooLong(String(repeating: "a", count: 400_001), for: chat)?.hasPrefix("Haiku 5.5 reads about \(400_000.formatted()) characters.") == true)
        #expect(model.whyTooLong(String(repeating: "a", count: 400_000), for: chat) == nil)
    }

    private func spent(_ chat: Chat, in model: AppModel, _ reason: String, held: Bool) {
        let id = chat.id.uuidString
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started", "sessionId": "s1"]))
        model.route(EngineEvent(name: "turn.done", threadId: id, body: [
            "event": "turn.done", "sessionId": "s1", "stopReason": "end_turn", "costUSD": .number(0.45), "spent": .string(reason), "held": .bool(held),
        ]))
    }

    /// The session's first turn broke it, so nothing goes again: the next message starts a new
    /// session that opens with the thread so far, and the queue comes back to the composer.
    @Test func aSessionTheModelRefusedGoesOnInANewOneAtTheNextMessage() throws {
        let model = AppModel(container: container)
        model.models = [Self.haiku(window: 1_000_000)]
        let chat = try thread(in: model)
        let conversation = model.conversation(for: chat)
        conversation.userSent("reply with only the word PINEAPPLE", previews: [], id: UUID())
        conversation.enqueue("and then MANGO", images: [])
        spent(chat, in: model, "refused", held: false)
        #expect(chat.sessionId == nil)
        #expect(chat.handover)
        #expect(conversation.queue.isEmpty)
        let notes = conversation.items.compactMap { if case .note(_, let text) = $0 { text } else { nil } }
        #expect(notes.last == "Claude won't go on in this session, so the next message starts a new one, handed what the thread has said.")
        conversation.userSent("Reply with only the word MANGO.", previews: [], id: UUID())
        #expect(model.handover(for: chat)?.contains("User: reply with only the word PINEAPPLE") == true)
        #expect(model.handover(for: chat)?.contains("MANGO") == false)
    }

    /// On Default the line names the agent, since the menu's name isn't a model's.
    @Test func onDefaultTheLineNamesTheAgent() throws {
        let model = AppModel(container: container)
        model.models = [ModelOption(id: ModelOption.claudeDefault, name: "Default (recommended)", description: "", efforts: [], fast: false, defaultEffort: nil,
                                    ultra: false, ultraBlocked: nil, more: nil, needs: nil, window: 1_000_000)]
        let chat = try thread(in: model)
        chat.model = ModelOption.claudeDefault
        #expect(model.whyTooLong(String(repeating: "a", count: 2_000_001), for: chat) == "Claude reads about \(2_000_000.formatted()) characters. This has \(2_000_001.formatted()).")
    }

    private func ended(_ chat: Chat, in model: AppModel) {
        let id = chat.id.uuidString
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started", "sessionId": "s1"]))
        model.route(EngineEvent(name: "turn.done", threadId: id, body: ["event": "turn.done", "sessionId": "s1", "stopReason": "end_turn"]))
    }

    private static let footer = TurnFooter(durationMs: 0, costUSD: 0, stopReason: "end_turn")
    private static let filler = String(repeating: "    let value = 1 // a step\n", count: 40_000)

    /// A session too long for the model that held more than the message just sent: that message
    /// goes again at once, in a new session handed what came before it, and the thread works.
    @Test func aSessionTooLongSendsTheMessageAgainInANewOne() async throws {
        let model = AppModel(container: container)
        model.models = [Self.haiku(window: 1_000_000)]
        let chat = try thread(in: model)
        chat.sessionId = "s1"
        let conversation = model.conversation(for: chat)
        conversation.userSent(Self.filler, previews: [], id: UUID())
        ended(chat, in: model)
        conversation.userSent("Reply with only the word KIWI.", previews: [], id: UUID())
        ended(chat, in: model)
        #expect(model.startOver(chat, spent: "long", held: true) == "Reply with only the word KIWI.")
        #expect(conversation.running)
        let notes = { conversation.items.compactMap { if case .note(_, let text) = $0 { text } else { nil } } }
        #expect(notes().last == "This session is more than Claude reads at once, so the message goes again in a new one, handed what the thread has said.")
        let sent = model.turnParams(in: chat, text: "Reply with only the word KIWI.")
        #expect(sent["sessionId"] == nil)
        #expect(sent["text"]?.string == "Reply with only the word KIWI.")
        let handover = try #require(sent["handover"]?.string)
        #expect(handover.contains("let value = 1"))
        #expect(!handover.contains("KIWI"))
        #expect(handover.count <= Handover.cap)
        // No engine runs here, so the send that goes again fails, and says so: it was made.
        for _ in 0..<60 where conversation.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(notes().count == 2)
    }

    /// Refused on a thread that held an older message far longer than the one just sent, which
    /// the new session gets cut: the message goes again.
    @Test func aRefusalAfterALongerOlderMessageSendsTheMessageAgain() throws {
        let items: [Item] = [
            .user(id: UUID(), text: Self.filler), .footer(id: UUID(), footer: Self.footer),
            .user(id: UUID(), text: "LEMON"), .footer(id: UUID(), footer: Self.footer),
        ]
        #expect(AppModel.sentAgain(after: "refused", in: items) == "LEMON")
    }

    /// Refused with nothing older longer than the message, or on the message that is itself the
    /// longest, nothing goes again: the model would most likely refuse it again, and be paid again.
    @Test func aRefusalOfTheLongestMessageOrOnAShortThreadSendsNothingAgain() throws {
        let short: [Item] = [
            .user(id: UUID(), text: "What does this do?"), .footer(id: UUID(), footer: Self.footer),
            .user(id: UUID(), text: "And this?"), .footer(id: UUID(), footer: Self.footer),
        ]
        #expect(AppModel.sentAgain(after: "refused", in: short) == nil)
        let longest: [Item] = [
            .user(id: UUID(), text: "What does this do?"), .footer(id: UUID(), footer: Self.footer),
            .user(id: UUID(), text: Self.filler), .footer(id: UUID(), footer: Self.footer),
        ]
        #expect(AppModel.sentAgain(after: "refused", in: longest) == nil)
        #expect(AppModel.sentAgain(after: "long", in: longest) == Self.filler)
    }

    /// A turn nobody sent, a background task reporting back after the last message was answered,
    /// sends nothing again: that message's turn is over, and what it asked may not be safe twice.
    @Test func aSpentTurnNobodySentSendsNothingAgain() throws {
        let items: [Item] = [
            .user(id: UUID(), text: Self.filler), .footer(id: UUID(), footer: Self.footer),
            .user(id: UUID(), text: "commit and push"), .text(id: UUID(), text: "Pushed."), .footer(id: UUID(), footer: Self.footer),
            .text(id: UUID(), text: "The tests finished."), .footer(id: UUID(), footer: Self.footer),
        ]
        #expect(AppModel.sentAgain(after: "long", in: items) == nil)
        #expect(AppModel.sentAgain(after: "refused", in: items) == nil)
    }

    /// A resumed session with short history the model refused: nothing goes again, and the
    /// thread is idle for the next message.
    @Test func aRefusedResumedSessionWithShortHistoryWaitsForTheNextMessage() throws {
        let model = AppModel(container: container)
        model.models = [Self.haiku(window: 1_000_000)]
        let chat = try thread(in: model)
        let conversation = model.conversation(for: chat)
        conversation.userSent("What does this do?", previews: [], id: UUID())
        ended(chat, in: model)
        conversation.userSent("And this?", previews: [], id: UUID())
        spent(chat, in: model, "refused", held: true)
        #expect(!conversation.running)
        #expect(chat.sessionId == nil)
        let notes = conversation.items.compactMap { if case .note(_, let text) = $0 { text } else { nil } }
        #expect(notes.last == "Claude won't go on in this session, so the next message starts a new one, handed what the thread has said.")
    }
}
