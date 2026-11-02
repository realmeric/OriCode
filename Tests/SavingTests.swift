import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Threads at work on the main thread's frames: a call's save waits for the others', and a thread
/// asked for by id comes from memory after the first time.
@MainActor
struct SavingTests {
    private let container: ModelContainer
    private let model: AppModel
    private let chat: Chat

    init() throws {
        container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project, title: "One")
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        _ = model.conversation(for: chat)
    }

    private func send(_ name: String, _ body: [String: JSON] = [:]) {
        var body = body
        body["event"] = .string(name)
        model.route(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    @Test func aCallWaitsForTheNextSaveAndATurnsEndDoesNot() async throws {
        send("turn.started")
        send("tool.use", ["toolUseId": "a", "name": "Read", "input": ["file_path": "/tmp/a"]])
        send("tool.result", ["toolUseId": "a", "content": "read", "isError": false])
        #expect(container.mainContext.hasChanges)
        try await Task.sleep(for: .milliseconds(500))
        #expect(!container.mainContext.hasChanges)
        send("tool.use", ["toolUseId": "b", "name": "Read", "input": ["file_path": "/tmp/b"]])
        send("turn.done", ["durationMs": 1, "costUSD": 0, "stopReason": "end_turn"])
        #expect(!container.mainContext.hasChanges)
    }

    @Test func aThreadDeletedBeforeItsCallIsSavedDoesNoHarm() async throws {
        send("turn.started")
        send("tool.use", ["toolUseId": "a", "name": "Read", "input": ["file_path": "/tmp/a"]])
        model.dropConversation(chat.id)
        container.mainContext.delete(chat)
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(500))
        #expect(!container.mainContext.hasChanges)
    }

    @Test func aThreadComesFromMemoryAndNotOnceItIsGone() throws {
        let other = Chat(project: try #require(chat.project), title: "Two")
        container.mainContext.insert(other)
        try container.mainContext.save()
        let id = other.id
        #expect(model.chat(withID: id)?.title == "Two")
        #expect(model.chatsByID[id] != nil)
        container.mainContext.delete(other)
        try container.mainContext.save()
        #expect(model.chat(withID: id) == nil)
    }
}
