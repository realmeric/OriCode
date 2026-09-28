import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Pi as the engine describes it: hello's entry and `models.list` as engine/pi-provider.ts
/// writes them.
@MainActor
struct PiTests {
    private let container: ModelContainer
    private let chat: Chat
    private let model: AppModel

    static let entry: JSON = [
        "id": "pi", "name": "Pi", "agent": "Pi", "state": "ready", "hint": .null, "cli": "/opt/homebrew/bin/pi", "version": "0.87.1",
        "capabilities": [
            "steer": true, "resume": true, "modeLive": false, "attachments": true, "heads": false, "stopTask": false, "limits": false,
            "usage": false, "commands": true, "compact": false, "commitMessage": false, "handoff": "pi --session {session}",
            "unsupervised": true,
        ],
        "levels": ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
        "modes": [],
    ]

    static let models: JSON = [
        ["id": "openai/gpt-5.5", "name": "GPT-5.5", "description": "openai · key", "efforts": ["off", "low", "medium", "high", "xhigh"],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "openai/gpt-4", "name": "GPT-4", "description": "openai · key", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "anthropic/claude-opus", "name": "Claude Opus", "description": "anthropic · login",
         "efforts": ["off", "minimal", "low", "medium", "high", "xhigh", "max"], "fast": false, "defaultEffort": .null, "ultra": false,
         "ultraBlocked": .null, "forbidden": "anthropic"],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "pi"
        chat.started = true
        chat.sessionId = "/Users/me/.pi/agent/sessions/s-1.jsonl"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, try Self.entry.decode(ProviderInfo.self)]
        model.modelsByAgent["pi"] = try Self.models.decode([ModelOption].self)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func aPiThreadAlwaysNamesItsModel() {
        // Nothing picked: the one the composer shows, pi's default, never what pi would choose.
        #expect(model.modelSent(in: chat) == "openai/gpt-5.5")
        chat.model = "openai/gpt-4"
        #expect(model.modelSent(in: chat) == "openai/gpt-4")
        // A Claude thread with none still sends none.
        chat.provider = nil
        chat.model = nil
        #expect(model.modelSent(in: chat) == nil)
    }

    @Test func piRunsUnsupervisedWithItsOwnLevelsAndNoTiles() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes.isEmpty)
        #expect(state.unsupervised)
        #expect(state.option?.efforts == ["off", "low", "medium", "high", "xhigh"])
        chat.model = "openai/gpt-4"
        #expect(PickerState(model: model, chat: chat).option?.efforts == [])
        #expect(model.takesImages)
        // It steers, so Return during a turn goes into it rather than the queue, as Claude's does.
        #expect(model.agent(for: chat).capabilities.steer)
    }

    @Test func piOffersContinueInPiAndNothingItCantDo() {
        model.engineState = .ready
        let rows = model.paletteSearchable()
        let ids = Set(rows.map(\.id))
        #expect(rows.first { $0.id == "terminal.claude" }?.title == "Continue in Pi")
        for id in ["thread.copySession", "effort.list"] { #expect(ids.contains(id), "\(id) missing") }
        for id in ["thread.compact", "heads", "mode.list"] { #expect(!ids.contains(id), "\(id) offered") }
    }

    @Test func aModelBehindClaudeAiIsDimmedAndNamesItsToggle() throws {
        let forbidden = try #require(model.option(ModelRef(provider: "pi", id: "anthropic/claude-opus")))
        #expect(!forbidden.pickable)
        let registry: JSON = ["id": "pi", "name": "Pi", "agent": "Pi", "route": "its RPC mode", "binary": true, "key": false, "forbidden": [
            ["id": "anthropic", "title": "Pi signed into claude.ai", "maker": "Anthropic", "sentence": "…", "url": "https://code.claude.com/docs/en/legal-and-compliance"],
        ]]
        model.agents = [try registry.decode(AgentInfo.self)]
        #expect(model.forbiddenHelp(forbidden, on: "pi") == "Turn on “Pi signed into claude.ai” in Settings › Agents to use Claude Opus")
        #expect(model.agents[0].status(model.providerInfo("pi"), on: true, checking: false) == "Signed in.")
    }
}
