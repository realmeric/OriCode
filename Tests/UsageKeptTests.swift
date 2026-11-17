import Foundation
import SwiftData
import Testing
@testable import OriCode

/// The usage ring answers on any thread, working or not, from the last numbers the app knows,
/// kept across a quit; a thread that hasn't run this launch has nothing of its own to wait for.
@MainActor
struct UsageKeptTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: "UsageKeptTests-\(UUID().uuidString)"))
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
    }

    private func launched() -> AppModel {
        let model = AppModel(container: container, usageKept: defaults)
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        return model
    }

    private let resets = Date.now.addingTimeInterval(3600)
    private var session: JSON { ["windows": [["id": "five_hour", "used": .number(0.42), "resetsAt": .number(resets.timeIntervalSince1970 * 1000)]]] }

    @Test func aReadingIsStillThereAfterARelaunch() {
        launched().takeLimits(session, for: "claude")
        let next = launched()
        #expect(next.usage?.headline?.used == 0.42)
        #expect(next.usage?.headline?.label == "Session")
        #expect(next.usageStale(for: chat) == false)
    }

    @Test func oneFromAnEarlierLaunchIsDatedAndDimmed() {
        let model = launched()
        model.takeLimits(session, for: "claude")
        model.usagesAt["claude"] = .now.addingTimeInterval(-3600)
        #expect(model.usageStale(for: chat))
        #expect(!launched().usageStale(for: chat))
    }

    @Test func aTestModelThatIsntGivenWhereToKeepThemKeepsNothing() {
        AppModel(container: container).takeLimits(session, for: "claude")
        #expect(launched().usage == nil)
    }

    @Test func aProbeThatFoundNoWindowLeavesWhatWasKnown() {
        let model = launched()
        model.takeLimits(session, for: "claude")
        model.takeUsage(["available": true, "plan": "max", "windows": []], for: "claude")
        #expect(model.usage?.headline?.used == 0.42)
        // And with nothing known, it is no reading for the card to draw empty.
        model.usages["claude"] = nil
        model.takeUsage(["available": true, "plan": "max", "windows": []], for: "claude")
        #expect(model.usage == nil)
    }

    @Test func aLoginTheLimitsDontApplyToIsAnAnswer() {
        let model = launched()
        model.takeUsage(["available": false, "plan": .null, "windows": []], for: "claude")
        #expect(model.usage?.says == true)
        #expect(model.usage?.available == false)
    }

    @Test func eachThreadReadsItsOwnAgentsLimits() {
        let model = launched()
        model.takeLimits(session, for: "claude")
        model.takeLimits(["windows": [["id": "30_day", "label": "30-day window", "used": .number(0.1)]]], for: "codex")
        let other = Chat(project: project)
        other.provider = "codex"
        container.mainContext.insert(other)
        #expect(model.usage(for: other)?.headline?.label == "30-day window")
        #expect(model.usage(for: chat)?.headline?.label == "Session")
        #expect(model.usage?.headline?.label == "Session")
    }

    /// A probe's answer, as the engine sends it: the CLI's numbers, dated by when it fetched them.
    private func probe(at: Date, _ windows: [(String, String, Double)]) -> JSON {
        let iso = ISO8601DateFormatter().string(from: resets.addingTimeInterval(86_400))
        return [
            "available": true, "plan": "max", "at": .number(at.timeIntervalSince1970 * 1000),
            "windows": .array(windows.map { ["id": .string($0.0), "label": .string($0.1), "used": .number($0.2), "resetsAt": .string(iso)] }),
        ]
    }

    @Test func aProbeTheCLIAnsweredFromAnEarlierFetchDoesntPutBackWhatAThreadMovedPast() {
        let model = launched()
        model.takeUsage(probe(at: .now.addingTimeInterval(-600), [("five_hour", "Session", 0.31), ("seven_day", "Week", 0.85), ("model:Fable", "Fable week", 0.55)]), for: "claude")
        // A Fable turn's report: the session and the week, and the week of the models extra usage covers.
        model.takeLimits(["windows": [
            ["id": "five_hour", "used": .number(0.45), "resetsAt": .number(resets.timeIntervalSince1970 * 1000)],
            ["id": "seven_day_overage_included", "used": .number(0.56), "resetsAt": .number(resets.timeIntervalSince1970 * 1000)],
        ]], for: "claude")
        // The CLI's kept answer again, four minutes on, still older than the turn's report.
        model.takeUsage(probe(at: .now.addingTimeInterval(-600), [("five_hour", "Session", 0.31), ("seven_day", "Week", 0.85)]), for: "claude")
        let windows = model.usage?.windows.map { "\($0.id) \($0.used ?? -1)" }
        #expect(windows == ["five_hour 0.45", "seven_day 0.85", "model:Fable 0.56"])
        // A fresh one wins.
        model.takeUsage(probe(at: .now, [("five_hour", "Session", 0.47)]), for: "claude")
        #expect(model.usage?.headline?.used == 0.47)
    }

    @Test func aWindowWhoseResetHasPassedShowsNothingUsedUntilItsReadAgain() {
        let model = launched()
        model.takeLimits(["windows": [["id": "five_hour", "used": .number(0.9), "resetsAt": .number(Date.now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)]]], for: "claude")
        #expect(model.usage?.headline?.used == 0)
        #expect(model.usage?.headline?.resetsAt == nil)
        #expect(model.usages["claude"]?.headline?.used == 0.9)
    }

    @Test func aResetTheCardUsedIsGoneFromItAndTheOthersStay() {
        let model = launched()
        model.takeUsage([
            "available": true, "plan": "go", "windows": [["id": "30_day", "label": "30-day window", "used": .number(1)]],
            "resets": [["id": "r1", "title": "Full reset (Monthly)", "expiresAt": "2026-12-18T10:58:42Z"], ["id": "r2", "title": .null, "expiresAt": .null]],
        ], for: "codex")
        #expect(model.usages["codex"]?.resets?.map(\.title) == ["Full reset (Monthly)", nil])
        model.usages["codex"]?.spend("r1")
        #expect(model.usages["codex"]?.resets?.map(\.id) == ["r2"])
    }
}
