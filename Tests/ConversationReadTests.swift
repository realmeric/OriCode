import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A stored transcript that cannot be read leaves its own explanation on the glass.
@MainActor
struct ConversationReadTests {
    private enum ReadError: LocalizedError {
        case unavailable

        var errorDescription: String? { "The conversation store is unavailable." }
    }

    @Test func aFailedReadLeavesItsError() async throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let model = AppModel(container: container, readEvents: { _, _ in throw ReadError.unavailable })

        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        for _ in 0..<50 where model.transcriptStatus[chat.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.transcriptStatus[chat.id] == ReadError.unavailable.localizedDescription)
        #expect(model.conversations[chat.id] == nil)
    }

    @Test func openingAgainReadsAgain() async throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let failing = Failing()
        // Only this thread's read: the model reads the thread last open in defaults as it starts.
        let id = chat.id
        let model = AppModel(container: container, readEvents: { read, context in
            if read == id, failing.once() { throw ReadError.unavailable }
            return try StoredEvent.read(read, from: context)
        })

        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        for _ in 0..<50 where model.transcriptStatus[chat.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.transcriptStatus[chat.id] != nil)

        model.selectedChatID = nil
        #expect(model.transcriptStatus[chat.id] == nil)
        model.selectedChatID = chat.id
        for _ in 0..<50 where model.conversations[chat.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.conversations[chat.id] != nil)
        #expect(model.transcriptStatus[chat.id] == nil)
    }
}

/// Fails the first read it's asked for and none after.
private final class Failing: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func once() -> Bool {
        lock.withLock {
            defer { failed = true }
            return !failed
        }
    }
}
