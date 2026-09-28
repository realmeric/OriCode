import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Command Code as the engine describes it: hello's entry and `models.list` as
/// engine/commandcode-provider.ts writes them.
@MainActor
struct CommandCodeTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    static func entry(_ state: String = "ready", hint: JSON = .null) -> JSON {
        [
            "id": "commandcode", "name": "Command Code", "agent": "Command Code", "state": .string(state), "hint": hint,
            "cli": "/opt/homebrew/bin/cmd", "version": "1.66.0",
            "capabilities": [
                "steer": false, "resume": true, "modeLive": false, "attachments": false, "heads": false, "stopTask": false, "limits": false,
                "usage": false, "commands": false, "compact": false, "commitMessage": false, "handoff": "cmd --resume {session}",
                "unsupervised": true,
            ],
            "levels": [],
            "modes": ["default", "plan", "bypassPermissions"],
        ]
    }

    static let models: JSON = [
        ["id": "deepseek/deepseek-v4-flash", "name": "deepseek-v4-flash", "description": "fast hybrid-attention reasoning", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "claude-sonnet-5", "name": "claude-sonnet-5", "description": "best combo of speed & intelligence (recommended)", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "commandcode"
        chat.started = true
        chat.sessionId = "s-1"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, try Self.entry().decode(ProviderInfo.self)]
        model.modelsByAgent["commandcode"] = try Self.models.decode([ModelOption].self)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func itsThreeModesShowWithTheUnsupervisedLine() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes == [.ask, .plan, .dontAsk])
        #expect(state.unsupervised)
        #expect(state.option?.efforts == [])
        #expect(model.modelSent(in: chat) == "deepseek/deepseek-v4-flash")
    }

    @Test func aDraftMovedOntoCommandCodeLeavesAModeItCantRun() throws {
        let draft = Chat(project: project, permissionMode: PermissionModeOption.acceptEdits.rawValue)
        container.mainContext.insert(draft)
        try container.mainContext.save()
        model.setModel(ModelRef(provider: "commandcode", id: "claude-sonnet-5"), for: draft)
        #expect(draft.providerID == "commandcode")
        #expect(draft.permissionMode == PermissionModeOption.ask.rawValue)
    }

    @Test func returnQueuesAndNothingItCantDoIsOffered() {
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        #expect(model.send("And then the lint"))
        #expect(conversation.queue.map(\.text) == ["And then the lint"])
        #expect(!model.takesImages)
        model.engineState = .ready
        let rows = model.paletteSearchable()
        let ids = Set(rows.map(\.id))
        #expect(rows.first { $0.id == "terminal.claude" }?.title == "Continue in Command Code")
        for id in ["thread.copySession", "mode.list", "mode.plan", "mode.bypassPermissions"] { #expect(ids.contains(id), "\(id) missing") }
        for id in ["thread.compact", "heads", "effort.list", "mode.acceptEdits", "mode.auto"] { #expect(!ids.contains(id), "\(id) offered") }
    }

    @Test func itsSettingsRowSaysSignedInOrWhereTheKeyGoes() throws {
        let registry: JSON = ["id": "commandcode", "name": "Command Code", "agent": "Command Code", "route": "its headless JSON",
                              "binary": true, "key": true, "forbidden": []]
        let row = try registry.decode(AgentInfo.self)
        #expect(row.status(model.providerInfo("commandcode"), on: true, checking: false) == "Signed in.")
        let hint = "Command Code has no working API key. Add yours in Settings › Agents."
        let signedOut = try Self.entry("signedOut", hint: .string(hint)).decode(ProviderInfo.self)
        #expect(row.status(signedOut, on: true, checking: false) == hint)
    }
}
