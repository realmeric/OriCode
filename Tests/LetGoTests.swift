import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread only looked at, let go once the user has moved on, and read back when they return.
@MainActor
struct LetGoTests {
    private let container: ModelContainer
    private let model: AppModel
    private let first: Chat
    private let second: Chat

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        first = Chat(project: project)
        second = Chat(project: project)
        // A thread with nothing said in it is a draft, which the model clears as it opens.
        first.started = true
        second.started = true
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.awayLimit = .milliseconds(150)
        model.selectedProjectID = project.id
        model.selectedChatID = first.id
    }

    private func away() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    @Test func aThreadLookedAtIsLetGoOnceAnotherIsOpen() async throws {
        _ = model.conversation(for: first)
        model.selectedChatID = second.id
        #expect(model.conversations[first.id] != nil)
        try await away()
        #expect(model.conversations[first.id] == nil)
    }

    @Test func aThreadReturnedToBeforeTheLimitStays() async throws {
        _ = model.conversation(for: first)
        model.selectedChatID = second.id
        try await Task.sleep(for: .milliseconds(50))
        model.selectedChatID = first.id
        try await away()
        #expect(model.conversations[first.id] != nil)
    }

    @Test func aThreadRunningOrHoldingMessagesIsKept() async throws {
        let running = model.conversation(for: first)
        running.userSent("Run the tests")
        model.selectedChatID = second.id
        try await away()
        #expect(model.conversations[first.id] != nil)
        running.enqueue("Then this")
        model.letGo(first.id)
        #expect(model.conversations[first.id] != nil)
    }

    @Test func aThreadLetGoIsReadBackWhenReopened() async throws {
        _ = model.conversation(for: first)
        model.selectedChatID = second.id
        try await away()
        #expect(model.conversations[first.id] == nil)
        model.selectedChatID = first.id
        for _ in 0..<50 where model.conversations[first.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.conversations[first.id] != nil)
    }
}
