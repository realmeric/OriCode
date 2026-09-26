import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread Claude's plan limits stopped, and the session limit's reset sending it on.
@MainActor
struct LimitTests {
    private let container: ModelContainer
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.sessionId = "s"
        chat.started = true
        container.mainContext.insert(chat)
    }

    private func limited(_ window: String, at resetsAt: Date) -> EngineEvent {
        EngineEvent(name: "limited", threadId: chat.id.uuidString, body: [
            "event": "limited", "resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000), "window": .string(window),
        ])
    }

    @Test func theSessionLimitWaitsForItsReset() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        let reset = Date.now.addingTimeInterval(3600).rounded
        conversation.receive(limited("five_hour", at: reset))
        #expect(chat.resumeAt == reset)
        #expect(conversation.lastLimit == conversation.items.last?.id)
        // Stored, so a relaunch still knows.
        let again = Conversation(chat: chat, context: container.mainContext)
        guard case .limited(_, let resetsAt, let window) = again.items.last else {
            Issue.record("no limit line")
            return
        }
        #expect(resetsAt == reset && window == "five_hour")
    }

    @Test func aWeeklyLimitOnlySaysWhen() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.receive(limited("seven_day", at: .now.addingTimeInterval(3 * 86_400)))
        #expect(chat.resumeAt == nil)
        #expect(conversation.lastLimit != nil)
    }

    @Test func refusedPastTheResetItWaitsAWhileLonger() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.receive(limited("five_hour", at: .now.addingTimeInterval(-30)))
        #expect((chat.resumeAt?.timeIntervalSinceNow ?? 0) > 200)
    }

    @Test func aMessageOrCancelCallsItOff() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.receive(limited("five_hour", at: .now.addingTimeInterval(600)))
        conversation.cancelResume()
        #expect(chat.resumeAt == nil)
        conversation.receive(limited("five_hour", at: .now.addingTimeInterval(600)))
        conversation.userSent("Carry on with the tests instead")
        #expect(chat.resumeAt == nil)
    }

    @Test func atTheResetTheThreadIsSentTheLine() async throws {
        let model = AppModel(container: container)
        model.engineState = .ready
        chat.resumeAt = .now.addingTimeInterval(-30)
        model.scheduleResumes()
        try await Task.sleep(for: .milliseconds(1600))
        let conversation = model.conversation(for: chat)
        let sent = conversation.items.contains { if case .user(_, let text, _, _) = $0 { text == AppModel.limitLine } else { false } }
        #expect(sent)
        #expect(chat.resumeAt == nil)
    }
}

private extension Date {
    /// To the millisecond, as the wire carries it.
    var rounded: Date { Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000) }
}
