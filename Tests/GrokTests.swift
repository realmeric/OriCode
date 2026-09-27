import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Grok Build as the engine describes it: hello's entry and `models.list` as
/// engine/grok.ts writes them.
@MainActor
struct GrokTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    static func entry(_ state: String = "ready", hint: JSON = .null) -> JSON {
        [
            "id": "grok", "name": "Grok Build", "agent": "Grok", "state": .string(state), "hint": hint,
            "cli": "/Users/me/.local/bin/grok", "version": "grok 1.0.41 (4220f3b224a6)",
            "capabilities": [
                "steer": false, "resume": true, "modeLive": false, "attachments": false, "heads": false, "stopTask": false, "limits": false,
                "usage": false, "commands": true, "compact": false, "commitMessage": false, "handoff": "grok --resume {session}",
            ],
            "levels": ["low", "medium", "high", "xhigh"],
            "modes": ["default", "plan", "bypassPermissions"],
        ]
    }

    static let models: JSON = [
        ["id": "grok-4.6", "name": "Grok 4.6", "description": "SpaceXAI's latest frontier model", "efforts": ["low", "medium", "high", "xhigh"],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "grok-4.5", "name": "Grok 4.5", "description": "", "efforts": ["low", "medium", "high"],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "grok-code-fast-1", "name": "Grok Code Fast", "description": "", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "grok"
        chat.started = true
        chat.sessionId = "019a0e24-0000-7000-8000-000000000001"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, try Self.entry().decode(ProviderInfo.self)]
        model.modelsByAgent["grok"] = try Self.models.decode([ModelOption].self)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func askPlanAndDontAskWithEachModelsOwnLevels() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes == [.ask, .plan, .dontAsk])
        #expect(!state.unsupervised)
        #expect(state.option?.stops == ["low", "medium", "high", "xhigh"])
        chat.model = "grok-4.5"
        #expect(PickerState(model: model, chat: chat).option?.stops == ["low", "medium", "high"])
        chat.model = "grok-code-fast-1"
        #expect(PickerState(model: model, chat: chat).option?.stops == [])
        #expect(!model.takesImages)
    }

    @Test func aDraftInAcceptEditsMovedOntoGrokAsks() throws {
        let draft = Chat(project: project, permissionMode: PermissionModeOption.acceptEdits.rawValue)
        container.mainContext.insert(draft)
        try container.mainContext.save()
        model.setModel(ModelRef(provider: "grok", id: "grok-4.6"), for: draft)
        #expect(draft.providerID == "grok")
        #expect(draft.permissionMode == PermissionModeOption.ask.rawValue)
    }

    @Test func continueInGrokBuildAndNothingItCantDo() {
        model.engineState = .ready
        let rows = model.paletteSearchable()
        let ids = Set(rows.map(\.id))
        #expect(rows.first { $0.id == "terminal.claude" }?.title == "Continue in Grok Build")
        for id in ["thread.copySession", "effort.list", "mode.list", "mode.plan", "mode.bypassPermissions"] { #expect(ids.contains(id), "\(id) missing") }
        for id in ["thread.compact", "heads", "mode.acceptEdits", "mode.auto"] { #expect(!ids.contains(id), "\(id) offered") }
    }

    @Test func itsSettingsRowSaysSignedInOrTheLoginLine() throws {
        let registry: JSON = ["id": "grok", "name": "Grok Build", "agent": "Grok", "route": "ACP", "binary": true, "key": false, "forbidden": []]
        let row = try registry.decode(AgentInfo.self)
        #expect(row.status(model.providerInfo("grok"), on: true, checking: false) == "Signed in.")
        let signedOut = try Self.entry("signedOut", hint: "Run `grok login` in Terminal.").decode(ProviderInfo.self)
        #expect(row.status(signedOut, on: true, checking: false) == "Run `grok login` in Terminal.")
    }
}
