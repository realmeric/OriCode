import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread Claude's plan limits stopped, and the session limit's reset sending it on; the limits
/// as a thread's CLI reports them on the way there.
@MainActor
struct LimitTests {
    private let container: ModelContainer
    private let chat: Chat

    init() throws {
        container = try TestStore.memory()
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

    @Test func aWeeklyLimitWaitsForItsResetToo() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        let reset = Date.now.addingTimeInterval(3 * 86_400).rounded
        conversation.receive(limited("seven_day", at: reset))
        #expect(chat.resumeAt == reset)
        #expect(conversation.lastLimit != nil)
    }

    /// A reset used, in OriCode or in the agent's own app, starts the limit over before the time
    /// the thread was told, and the thread goes on then and not days later.
    @Test func aResetUsedSendsAWaitingThreadOnNow() {
        let model = AppModel(container: container)
        model.engineState = .ready
        model.providers = [.claude]
        defer { model.resumeTask?.cancel() }
        let reset = Date.now.addingTimeInterval(3 * 86_400).rounded
        model.conversation(for: chat).receive(limited("seven_day", at: reset))
        #expect(chat.resumeAt == reset)
        // A reading of the same window, still full, changes nothing.
        model.takeLimits(["windows": [["id": "seven_day", "used": .number(1), "resetsAt": .number(reset.timeIntervalSince1970 * 1000)]]], for: "claude")
        #expect(chat.resumeAt == reset)
        // One that shows the window started over sends it on.
        let next = Date.now.addingTimeInterval(7 * 86_400)
        model.takeLimits(["windows": [["id": "seven_day", "used": .number(0.01), "resetsAt": .number(next.timeIntervalSince1970 * 1000)]]], for: "claude")
        #expect(chat.resumeAt == nil)
        let sent = model.conversation(for: chat).items.contains { if case .user(_, let text, _, _) = $0 { text == AppModel.limitLine("seven_day") } else { false } }
        #expect(sent)
    }

    @Test func aResetUsedFromTheCardSendsOnEveryThreadOfItsAgent() {
        let model = AppModel(container: container)
        model.engineState = .ready
        model.providers = [.claude]
        defer { model.resumeTask?.cancel() }
        model.conversation(for: chat).receive(limited("five_hour", at: .now.addingTimeInterval(3600)))
        model.goOnEarly("codex", used: true)
        #expect(chat.resumeAt != nil)
        model.goOnEarly("claude", used: true)
        #expect(chat.resumeAt == nil)
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
        let sent = conversation.items.contains { if case .user(_, let text, _, _) = $0 { text.hasSuffix(AppModel.limitLineEnd) } else { false } }
        #expect(sent)
        #expect(chat.resumeAt == nil)
    }

    @Test func withSettingsSayingNoTheSessionLimitDoesntWait() {
        UserDefaults.standard.set(false, forKey: Limit.goOnKey)
        defer { UserDefaults.standard.removeObject(forKey: Limit.goOnKey) }
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.receive(limited("five_hour", at: .now.addingTimeInterval(3600)))
        #expect(chat.resumeAt == nil)
        #expect(conversation.lastLimit != nil)
    }

    @Test func theCardsToggleCallsOffAWaitForAWeeklyLimitAndWaitsAgain() {
        let model = AppModel(container: container)
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        let reset = Date.now.addingTimeInterval(3 * 86_400).rounded
        model.conversation(for: chat).receive(limited("seven_day", at: reset))
        model.goOn(false, at: reset)
        #expect(chat.resumeAt == nil)
        model.goOn(true, at: reset)
        #expect(chat.resumeAt == reset)
        #expect(model.conversation(for: chat).lastLimitWindow == "seven_day")
        model.goOn(false, at: reset)
        #expect(chat.resumeAt == nil)
        model.resumeTask?.cancel()
        #expect(AppModel.limitLine("seven_day") == "The weekly limit has reset. Please continue from where you left off.")
    }

    @Test func theLimitThatStoppedTheLatestTurnIsKnownUntilTheNextOne() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.userSent("Run the tests")
        conversation.receive(limited("seven_day", at: .now.addingTimeInterval(3600)))
        conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        #expect(conversation.turnLimit?.window == "seven_day")
        conversation.userSent("Try again")
        conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
        #expect(conversation.turnLimit == nil)
    }

    /// The turn a background subagent's end woke, refused by the limit that stopped the subagent,
    /// as the engine tells it: the thread waits, and goes on at the reset or once a reset is used.
    @Test func aSubagentsLimitMakesItsThreadWaitAndGoOn() {
        let model = AppModel(container: container)
        model.engineState = .ready
        model.providers = [.claude]
        defer { model.resumeTask?.cancel() }
        let conversation = model.conversation(for: chat)
        let woke = { (body: JSON) in model.route(EngineEvent(name: body["event"]?.string ?? "", threadId: chat.id.uuidString, body: body)) }
        let reset = Date.now.addingTimeInterval(3600).rounded
        woke(["event": "turn.started", "sessionId": "s", "woke": "Redesign the site failed"])
        woke(["event": "limited", "resetsAt": .number(reset.timeIntervalSince1970 * 1000), "window": "five_hour"])
        woke(["event": "turn.done", "stopReason": "stop_sequence", "durationMs": 10, "costUSD": 0])
        #expect(chat.resumeAt == reset)
        #expect(conversation.turnLimit?.window == "five_hour")
        model.goOnEarly("claude", used: true)
        #expect(chat.resumeAt == nil)
        let sent = { conversation.items.filter { if case .user(_, let text, _, _) = $0 { text == AppModel.limitLine("five_hour") } else { false } }.count }
        #expect(sent() == 1)
        // A subagent stopped by a limit its thread's turn went on past: the thread waits for it
        // too, and is sent on at its reset.
        woke(["event": "turn.done", "stopReason": "end_turn", "durationMs": 10, "costUSD": 0])
        woke(["event": "limited", "resetsAt": .number(Date.now.addingTimeInterval(-30).timeIntervalSince1970 * 1000), "window": "five_hour", "subagent": true])
        woke(["event": "turn.done", "stopReason": "end_turn", "durationMs": 10, "costUSD": 0])
        #expect(chat.resumeAt != nil)
        chat.resumeAt = .now.addingTimeInterval(-30)
        model.resumeDue()
        #expect(chat.resumeAt == nil)
        #expect(sent() == 2)
    }

    private func limits(_ status: String, _ window: String, used: Double, resetsAt: Date) -> EngineEvent {
        EngineEvent(name: "limits", threadId: chat.id.uuidString, body: [
            "event": "limits", "status": .string(status), "rateLimitType": .string(window), "utilization": .number(used),
            "resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000), "surpassedThreshold": .number(0.75),
            "windows": [["id": "five_hour", "used": .number(used), "resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000)]],
        ])
    }

    private func nearLines(_ conversation: Conversation) -> [(String, Double)] {
        conversation.items.compactMap { if case .nearLimit(_, let window, let used, _, _) = $0 { (window, used) } else { nil } }
    }

    @Test func nearALimitTheThreadSaysSoOncePerWindow() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        let reset = Date.now.addingTimeInterval(4200)
        conversation.receive(limits("allowed", "five_hour", used: 0.6, resetsAt: reset))
        conversation.receive(limits("allowed_warning", "five_hour", used: 0.9, resetsAt: reset))
        conversation.receive(limits("allowed_warning", "five_hour", used: 0.93, resetsAt: reset))
        conversation.receive(limits("allowed_warning", "seven_day", used: 0.76, resetsAt: .now.addingTimeInterval(3 * 86_400)))
        #expect(nearLines(conversation).map(\.0) == ["five_hour", "seven_day"])
        #expect(nearLines(conversation).first?.1 == 0.9)
        // Stored, so a relaunch shows it and doesn't say it again.
        let again = Conversation(chat: chat, context: container.mainContext)
        again.receive(limits("allowed_warning", "five_hour", used: 0.95, resetsAt: reset))
        #expect(nearLines(again).map(\.0) == ["five_hour", "seven_day"])
    }

    @Test func aWindowThatHasResetCanBeNearItsLimitAgain() {
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.receive(limits("allowed_warning", "five_hour", used: 0.9, resetsAt: .now.addingTimeInterval(-60)))
        conversation.receive(limits("allowed_warning", "five_hour", used: 0.8, resetsAt: .now.addingTimeInterval(5 * 3600)))
        #expect(nearLines(conversation).count == 2)
    }

    @Test func theGlassReadsWhatTheCLIReportsAsItGoes() {
        let model = AppModel(container: container)
        #expect(model.usage == nil)
        model.route(limits("allowed", "seven_day", used: 0.42, resetsAt: .now.addingTimeInterval(3600)))
        // A fraction, as the probe's readings are once the engine has divided them.
        #expect(model.usage?.headline?.id == "five_hour")
        #expect(model.usage?.headline?.used == 0.42)
        #expect(model.usage?.headline?.label == "Session")
        #expect(model.usage?.windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(Band.of(model.usage?.headline?.used ?? 0) == .ample)
        model.route(limits("allowed_warning", "five_hour", used: 0.72, resetsAt: .now.addingTimeInterval(3600)))
        #expect(model.usage?.headline?.used == 0.72)
        #expect(Band.of(model.usage?.headline?.used ?? 0) == .critical)
    }
}

private extension Date {
    /// To the millisecond, as the wire carries it.
    var rounded: Date { Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000) }
}
