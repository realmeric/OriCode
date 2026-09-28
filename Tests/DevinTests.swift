import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Devin as the engine describes it: hello's entry and `models.list` as engine/devin.ts
/// writes them.
@MainActor
struct DevinTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    static func entry(_ state: String = "ready", hint: JSON = .null) -> JSON {
        [
            "id": "devin", "name": "Devin", "agent": "Devin", "state": .string(state), "hint": hint,
            "cli": "/opt/homebrew/bin/devin", "version": "devin 3000.11.3 (9c803229faa4)",
            "capabilities": [
                "steer": false, "resume": true, "modeLive": true, "attachments": true, "heads": false, "stopTask": false, "limits": false,
                "usage": false, "commands": true, "compact": false, "commitMessage": false, "handoff": "devin --resume {session}",
            ],
            "levels": [],
            "modes": ["acceptEdits", "plan", "bypassPermissions"],
        ]
    }

    static let models: JSON = [
        ["id": "swe-1-6-fast", "name": "SWE-1.6 Fast", "description": "", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "adaptive", "name": "Adaptive", "description": "", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project, permissionMode: PermissionModeOption.acceptEdits.rawValue)
        chat.provider = "devin"
        chat.started = true
        chat.sessionId = "mirage-robin"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, try Self.entry().decode(ProviderInfo.self)]
        model.modelsByAgent["devin"] = try Self.models.decode([ModelOption].self)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func acceptEditsPlanAndDontAskWithNoLevels() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes == [.acceptEdits, .plan, .dontAsk])
        #expect(!state.unsupervised)
        #expect(state.option?.efforts == [])
        #expect(model.takesImages)
    }

    @Test func aDraftInAskMovedOntoDevinAcceptsEdits() throws {
        let draft = Chat(project: project)
        container.mainContext.insert(draft)
        try container.mainContext.save()
        model.setModel(ModelRef(provider: "devin", id: "adaptive"), for: draft)
        #expect(draft.providerID == "devin")
        #expect(draft.permissionMode == PermissionModeOption.acceptEdits.rawValue)
    }

    @Test func continueInDevinAndNothingItCantDo() {
        model.engineState = .ready
        let rows = model.paletteSearchable()
        let ids = Set(rows.map(\.id))
        #expect(rows.first { $0.id == "terminal.claude" }?.title == "Continue in Devin")
        for id in ["thread.copySession", "mode.list", "mode.acceptEdits", "mode.plan", "mode.bypassPermissions"] { #expect(ids.contains(id), "\(id) missing") }
        for id in ["thread.compact", "heads", "effort.list", "mode.default", "mode.auto"] { #expect(!ids.contains(id), "\(id) offered") }
    }

    @Test func itsSettingsRowSaysSignedInOrTheLoginLine() throws {
        let registry: JSON = ["id": "devin", "name": "Devin", "agent": "Devin", "route": "ACP", "binary": true, "key": false, "forbidden": []]
        let row = try registry.decode(AgentInfo.self)
        #expect(row.status(model.providerInfo("devin"), on: true, checking: false) == "Signed in.")
        let signedOut = try Self.entry("signedOut", hint: "Run `devin auth login` in Terminal.").decode(ProviderInfo.self)
        #expect(row.status(signedOut, on: true, checking: false) == "Run `devin auth login` in Terminal.")
    }
}
