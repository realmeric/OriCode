import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Claude's plan: a card where it was first written, kept to the latest TodoWrite, a new card for
/// a new plan, and the same plan read back from the stored calls.
@MainActor
struct PlanTests {
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

    private func receive(_ name: String, _ body: [String: JSON], in conversation: Conversation) {
        var body = body
        body["event"] = .string(name)
        conversation.receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    /// A TodoWrite of "Read the engine", "Run the tests", … with each item's status.
    private func write(_ todos: [(String, String)], in conversation: Conversation) {
        let id = JSON.string(UUID().uuidString)
        let list: [JSON] = todos.map { content, status in
            ["content": .string(content), "activeForm": .string(content.replacing("Run ", with: "Running ")), "status": .string(status)]
        }
        receive("tool.use", ["toolUseId": id, "name": "TodoWrite", "input": ["todos": .array(list)]], in: conversation)
        receive("tool.result", ["toolUseId": id, "content": "Todos have been modified successfully."], in: conversation)
    }

    private func call(_ name: String, in conversation: Conversation) {
        let id = JSON.string(UUID().uuidString)
        receive("tool.use", ["toolUseId": id, "name": .string(name), "input": ["file_path": "/tmp/alpha/App/A.swift"]], in: conversation)
        receive("tool.result", ["toolUseId": id, "content": "ok"], in: conversation)
    }

    private static let steps = ["Read the engine", "Run the tests", "Write the notes"]

    private static func plan(_ statuses: String...) -> [(String, String)] {
        Array(zip(steps, statuses))
    }

    private static func cards(_ entries: [TranscriptEntry]) -> [Plan] {
        entries.compactMap { entry in
            if case .item(.tool(_, let call)) = entry { call.plan } else { nil }
        }
    }

    private static func shape(_ entries: [TranscriptEntry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .run(let items): "run of \(items.count)"
            case .item(.tool(_, let call)): call.plan == nil ? call.name : "plan"
            case .item(.user): "user"
            case .item(.text): "text"
            case .item: "other"
            }
        }
    }

    @Test func aPlanIsWrittenUpdatedAndFinishedOnOneCard() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Fix the flaky test")
        write(Self.plan("in_progress", "pending", "pending"), in: conversation)
        #expect(conversation.planStep == "Read the engine")
        call("Read", in: conversation)
        write(Self.plan("completed", "in_progress", "pending"), in: conversation)
        call("Bash", in: conversation)
        receive("text", ["delta": "The tests pass."], in: conversation)

        // The update folds into the run around it and has no line of its own.
        var entries = TranscriptEntry.fold(conversation.items)
        #expect(Self.shape(entries) == ["user", "plan", "run of 2", "text"])
        let plan = Self.cards(entries)[0]
        #expect(plan.done == 1)
        #expect(plan.current?.activeForm == "Running the tests")
        #expect(conversation.planStep == "Running the tests")

        // A lone update beside a lone call leaves that call its own line.
        call("Read", in: conversation)
        write(Self.plan("completed", "completed", "completed"), in: conversation)
        entries = TranscriptEntry.fold(conversation.items)
        #expect(Self.shape(entries) == ["user", "plan", "run of 2", "text", "Read"])
        #expect(Self.cards(entries)[0].finished)
        #expect(conversation.planStep == nil)
    }

    @Test func aNewPlanStartsACardOfItsOwn() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        write(Self.plan("completed", "completed", "completed"), in: conversation)
        // Written after the last was all done, even with the same items.
        write(Self.plan("in_progress", "pending", "pending"), in: conversation)
        // Two of three items new: mostly different.
        write([("Read the engine", "completed"), ("Profile the review", "in_progress"), ("Cache the diff", "pending")], in: conversation)
        // Two of four new: half the items carried on, so the same plan.
        write([("Read the engine", "completed"), ("Cache the diff", "in_progress"), ("Time it", "pending"), ("Ship it", "pending")],
              in: conversation)
        let cards = Self.cards(TranscriptEntry.fold(conversation.items))
        #expect(cards.map(\.todos.count) == [3, 3, 4])
        #expect(cards[2].current?.content == "Cache the diff")

        // An empty list clears the plan, and the next one starts afresh.
        write([], in: conversation)
        #expect(conversation.plan == nil)
        write([("Cache the diff", "completed"), ("Time it", "in_progress")], in: conversation)
        #expect(Self.shape(TranscriptEntry.fold(conversation.items)) == ["user", "plan", "plan", "plan", "plan"])
    }

    @Test func aReplayedThreadShowsItsLastPlanFromTheStoredCalls() throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        write(Self.plan("in_progress", "pending", "pending"), in: conversation)
        call("Read", in: conversation)
        write(Self.plan("completed", "in_progress", "pending"), in: conversation)
        receive("turn.done", ["stopReason": "end_turn"], in: conversation)
        #expect(conversation.planStep == nil)

        let replayed = Conversation(chat: chat, context: context)
        #expect(replayed.items == conversation.items)
        #expect(replayed.plan?.done == 1)
        let kinds = Set(try context.fetch(FetchDescriptor<Event>()).map(\.kind))
        #expect(kinds == ["user", "tool.use", "tool.result", "turn.done"])
    }
}
