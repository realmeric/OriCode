import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread that changes agent (K-214): the menu offers every agent's models in a begun thread,
/// picking one moves the thread, the next send carries the thread so far, and the transcript says
/// where it changed.
@MainActor
struct HandoverTests {
    private let container: ModelContainer
    private let project: Project
    private let model: AppModel
    private let luna = ModelRef(provider: "codex", id: "gpt-6-luna")

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.models = ModelMenuTests.claudeModels
        model.modelsByAgent[ModelMenuTests.codex.id] = ModelMenuTests.codexModels
        model.providers = [.claude, ModelMenuTests.codex]
        model.selectedProjectID = project.id
    }

    private func receive(_ name: String, _ body: [String: JSON] = [:], in conversation: Conversation, of chat: Chat) {
        var body = body
        body["event"] = .string(name)
        conversation.receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    /// A Claude thread that has said "my number is 47" and been answered, its session s1.
    private func begun() throws -> (Chat, Conversation) {
        let chat = Chat(project: project)
        chat.started = true
        chat.model = "default"
        chat.effort = "max"
        chat.permissionMode = "auto"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let conversation = model.conversation(for: chat)
        conversation.userSent("my number is 47")
        receive("text", ["delta": "Noted."], in: conversation, of: chat)
        receive("turn.done", ["sessionId": "s1", "stopReason": "end_turn", "durationMs": 1, "costUSD": 0], in: conversation, of: chat)
        return (chat, conversation)
    }

    @Test func aBegunThreadIsOfferedEveryAgentsModelsUntilItWorks() throws {
        let (chat, conversation) = try begun()
        #expect(model.agentsListed(for: chat).map(\.id) == ["claude", "codex"])
        #expect(model.modelGroups(for: chat).flatMap(\.rows).map(\.id).contains("codex/gpt-6-luna"))
        // A turn running, or something it left out, keeps it on its own agent, and a pick does nothing.
        conversation.userSent("and again")
        #expect(model.agentsListed(for: chat).map(\.id) == ["claude"])
        model.setModel(luna, for: chat)
        #expect(chat.providerID == "claude" && chat.sessionId == "s1" && !chat.handover)
    }

    @Test func pickingAnotherAgentsModelMovesTheThreadAndItsSession() throws {
        let restore = ModelMenuTests.keepingDefaults()
        defer { restore() }
        let (chat, conversation) = try begun()
        chat.workflows = true
        #expect(model.workflows(of: chat))
        model.setModel(luna, for: chat)
        #expect(chat.providerID == "codex" && chat.model == "gpt-6-luna")
        // Codex has neither Auto nor Max, nor workflows on this model; the session is the old agent's.
        #expect(chat.permissionMode == "default" && chat.effort == nil)
        #expect(!model.workflows(of: chat))
        #expect(chat.sessionId == nil && chat.handover)
        #expect(model.agent(for: chat).id == "codex")

        // Back to Claude starts again the same way.
        receive("turn.started", ["sessionId": "c1"], in: conversation, of: chat)
        #expect(!chat.handover && chat.sessionId == "c1")
        receive("turn.done", ["sessionId": "c1", "stopReason": "end_turn", "durationMs": 1, "costUSD": 0], in: conversation, of: chat)
        model.setModel(ModelRef(provider: "claude", id: "haiku"), for: chat)
        #expect(chat.providerID == "claude" && chat.sessionId == nil && chat.handover)
        // A pick within the agent it's on changes nothing else.
        chat.sessionId = "c2"
        chat.handover = false
        model.setModel(ModelRef(provider: "claude", id: "default"), for: chat)
        #expect(chat.sessionId == "c2" && !chat.handover)
    }

    @Test func theTranscriptSaysWhereTheAgentChanged() throws {
        let restore = ModelMenuTests.keepingDefaults()
        defer { restore() }
        let (chat, conversation) = try begun()
        model.setModel(luna, for: chat)
        guard case .note(_, let text) = try #require(conversation.items.last) else { Issue.record("not a note"); return }
        #expect(text == "Now on Codex · GPT-6 Luna")
        model.setModel(ModelRef(provider: "claude", id: "haiku"), for: chat)
        guard case .note(_, let back) = try #require(conversation.items.last) else { Issue.record("not a note"); return }
        #expect(back == "Now on Claude · Haiku 5")
        // The line is stored with the thread, so a relaunch shows it.
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Event>(predicate: #Predicate { $0.kind == "note" })) == 2)
    }

    @Test func theNextSendCarriesTheThreadSoFarAndNotItsOwnMessage() throws {
        let restore = ModelMenuTests.keepingDefaults()
        defer { restore() }
        let (chat, conversation) = try begun()
        #expect(model.handover(for: chat) == nil)
        model.setModel(luna, for: chat)
        conversation.userSent("what's my number?")
        #expect(model.handover(for: chat) == "User: my number is 47\nAssistant: Noted.")
        // Until a turn on the new agent has begun; a thread that never had a message has nothing to hand.
        receive("turn.started", ["sessionId": "c1"], in: conversation, of: chat)
        #expect(model.handover(for: chat) == nil)
    }

    @Test func theHandoverKeepsWhatWasSaidAndOneLinePerTool() {
        let read = ToolCall(toolUseId: "t1", name: "Read", input: ["file_path": "/tmp/alpha/a.swift"])
        let items: [Item] = [
            .user(id: UUID(), text: "look at a.swift"),
            .thinking(id: UUID(), text: "hm"),
            .text(id: UUID(), text: "Reading it."),
            .tool(id: UUID(), call: read),
            .text(id: UUID(), text: "It adds two numbers."),
            .note(id: UUID(), text: "Now on Codex · GPT-6 Luna"),
            .footer(id: UUID(), footer: TurnFooter(durationMs: 1, costUSD: 0, stopReason: "end_turn")),
            .user(id: UUID(), text: "thanks", images: [Data([1])]),
        ]
        let text = Handover.text(from: items, cwd: "/tmp/alpha")
        #expect(text == """
        User: look at a.swift
        Assistant: Reading it.
        Tool: Read a.swift
        Assistant: It adds two numbers.
        User: thanks [1 image]
        """)
        #expect(Handover.text(from: [.text(id: UUID(), text: "hi")], cwd: "/tmp") == "")
        #expect(Handover.text(from: [], cwd: "/tmp") == "")
    }

    @Test func theHandoverIsCappedAndTheLatestExchangeStaysWhole() {
        var items: [Item] = []
        for number in 1...200 {
            items.append(.user(id: UUID(), text: "question \(number)"))
            items.append(.text(id: UUID(), text: "answer \(number) " + String(repeating: "x", count: 3_000)))
        }
        let last = String(repeating: "y", count: 6_000)
        items.append(.user(id: UUID(), text: "the last question"))
        items.append(.text(id: UUID(), text: last))
        let text = Handover.text(from: items, cwd: "/tmp")
        #expect(text.count <= Handover.cap)
        #expect(text.hasPrefix("[") && text.contains("earlier parts of the thread are left out."))
        // The most recent is whole, and an older reply is cut to what an older one keeps.
        #expect(text.hasSuffix("Assistant: \(last)"))
        #expect(text.contains("question 200\nAssistant: answer 200 "))
        #expect(!text.contains(String(repeating: "x", count: Handover.older + 1)))
        // A smaller cap keeps less, and only cuts the latest reply when half the cap can't hold it.
        let small = Handover.text(from: items, cwd: "/tmp", cap: 10_000)
        #expect(small.count <= 10_000 && small.hasSuffix("…") && small.contains("the last question"))
    }
}
