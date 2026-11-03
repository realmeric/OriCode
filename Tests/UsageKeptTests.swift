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

    private let session: JSON = ["windows": [["id": "five_hour", "used": .number(0.42), "resetsAt": 1792439399000]]]

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
}
