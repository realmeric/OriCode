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
            usage: true, commands: false, compact: false, commitMessage: false, handoff: "codex resume --no-daemon {session}"),
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

    /// Codex refuses a turn with usageLimitExceeded, which the engine sends as a limit on its 30-day
    /// window: the card names that window, waits only when told to, and goes on at the reset.
    @Test func aCodexLimitNamesItsWindowAndGoesOnWhenAsked() async throws {
        let model = AppModel(container: container)
        let codex = Self.codex
        model.providers = [.claude, ProviderInfo(
            id: codex.id, name: codex.name, agent: codex.agent, state: .ready, hint: nil, cli: codex.cli, version: "0.157.1",
            capabilities: codex.capabilities, levels: codex.levels, modes: codex.modes)]
        model.engineState = .ready
        let chat = Chat(project: project)
        chat.provider = "codex"
        chat.sessionId = "codex-thread"
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        let reset = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 20 * 86_400).rounded())
        model.conversation(for: chat).receive(EngineEvent(name: "limited", threadId: chat.id.uuidString, body: [
            "event": "limited", "resetsAt": .number(reset.timeIntervalSince1970 * 1000), "window": "30_day",
        ]))
        #expect(Limit.name(of: "30_day") == "30-day limit")
        #expect(Limit.span(of: "30_day") == "the 30-day window")
        #expect(Limit.time(reset) == reset.formatted(.dateTime.day().month(.abbreviated)) + " " + reset.formatted(date: .omitted, time: .shortened))
        #expect(chat.resumeAt == nil)
        model.goOn(true, at: reset)
        #expect(chat.resumeAt == reset)
        #expect(AppModel.limitLine(model.conversation(for: chat).lastLimitWindow) == "The 30-day limit has reset. Please continue from where you left off.")
        chat.resumeAt = .now.addingTimeInterval(-30)
        model.scheduleResumes()
        try await Task.sleep(for: .milliseconds(1600))
        let conversation = model.conversation(for: chat)
        let sent = conversation.items.contains { if case .user(_, let text, _, _) = $0 { text.hasPrefix("The 30-day limit") } else { false } }
        #expect(sent)
        #expect(chat.resumeAt == nil)
        // No engine runs here, so the send fails; its note lands before the store goes.
        for _ in 0..<60 where conversation.running { try await Task.sleep(for: .milliseconds(50)) }
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

    /// Codex's own ultra and OriCode's on Rays both sit at the top of the rail, each saying what
    /// it does; Claude's still says workflows.
    @Test func eachUltracodeSaysWhoseItIs() throws {
        let model = AppModel(container: container)
        model.providers = [.claude, Self.codex]
        let listed = """
        [{"id": "gpt-6-luna", "name": "GPT-6-Luna", "description": "", "efforts": ["low", "medium", "high", "xhigh", "max"], "fast": false,
          "defaultEffort": "medium", "ultra": true, "ultraBlocked": null, "ultraRays": true},
         {"id": "gpt-5.6-terra", "name": "GPT-5.6-Terra", "description": "", "efforts": ["low", "medium", "high", "xhigh", "max"], "fast": false,
          "defaultEffort": "medium", "ultra": true, "ultraBlocked": null}]
        """
        model.modelsByAgent["codex"] = try JSONDecoder().decode([ModelOption].self, from: Data(listed.utf8))
        let chat = Chat(project: project)
        chat.provider = "codex"
        chat.model = "gpt-6-luna"
        container.mainContext.insert(chat)
        let rays = try #require(model.option(for: chat))
        #expect(rays.stops.last == Effort.ultracode)
        #expect(EffortScale.line(Effort.ultracode, on: rays, agent: "codex").words == "Workers on every task")
        chat.model = "gpt-5.6-terra"
        let own = try #require(model.option(for: chat))
        #expect(own.ultraRays == nil)
        #expect(EffortScale.line(Effort.ultracode, on: own, agent: "codex").words == "Max, delegating itself")
        #expect(EffortScale.line(Effort.ultracode).words == "Workflows on every task")
    }
}
