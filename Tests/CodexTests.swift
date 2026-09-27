import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What a Codex thread needs of the app beyond what every agent gets: its limits' own window
/// names, and its model read when a thread on it is shown after a launch.
@MainActor
struct CodexTests {
    private let container: ModelContainer
    private let project: Project

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
    }

    private static let codex = ProviderInfo(
        id: "codex", name: "Codex", agent: "Codex", state: .unknown, hint: nil, cli: "/usr/local/bin/codex", version: nil,
        capabilities: ProviderInfo.Capabilities(
            steer: true, resume: true, modeLive: false, attachments: true, heads: false, stopTask: false, limits: true,
            usage: true, commands: false, compact: false, commitMessage: false, handoff: "codex resume {session}"),
        levels: ["low", "medium", "high", "xhigh", "max", Effort.ultracode],
        modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"])

    @Test func aCodexLimitsReportKeepsItsWindowsName() {
        let model = AppModel(container: container)
        model.takeLimits([
            "status": "allowed", "rateLimitType": "30_day", "utilization": .number(0.02), "resetsAt": 1792439399000,
            "windows": [["id": "30_day", "label": "30-day window", "used": .number(0.02), "resetsAt": 1792439399000]],
        ], for: "codex")
        let window = model.usages["codex"]?.headline
        #expect(window?.label == "30-day window")
        #expect(window?.used == 0.02)
        #expect(window?.resetsAt == Date(timeIntervalSince1970: 1792439399))
        #expect(model.usages["claude"] == nil)
        // Claude's reports carry no label, and a window it doesn't name is still left out.
        model.takeLimits(["windows": [["id": "odd", "used": .number(0.5)]]], for: "claude")
        #expect(model.usages["claude"]?.windows.isEmpty == true)
    }

    @Test func aCodexThreadShownAfterALaunchAsksCodexAndAClaudeThreadAsksNothing() {
        let model = AppModel(container: container)
        model.providers = [.claude, Self.codex]
        model.engineState = .ready
        let claudeThread = Chat(project: project)
        container.mainContext.insert(claudeThread)
        model.readModels(for: claudeThread)
        #expect(model.checkingAgents.isEmpty)
        let codexThread = Chat(project: project)
        codexThread.provider = "codex"
        container.mainContext.insert(codexThread)
        model.readModels(for: codexThread)
        #expect(model.checkingAgents == ["codex"])
    }
}
