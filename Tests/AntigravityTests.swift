import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Antigravity as the engine describes it: hello's entry, `models.list` and the
/// registry's row as engine/antigravity-provider.ts and agents.ts write them.
@MainActor
struct AntigravityTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    static func entry(_ state: String = "ready", hint: JSON = .null) -> JSON {
        [
            "id": "antigravity", "name": "Antigravity", "agent": "Antigravity", "state": .string(state), "hint": hint,
            "cli": "/Users/meric/.local/bin/agy", "version": "1.2.11",
            "capabilities": [
                "steer": false, "resume": true, "modeLive": false, "attachments": false, "heads": false, "stopTask": false, "limits": false,
                "usage": false, "commands": false, "compact": false, "commitMessage": false, "handoff": "agy --conversation {session}",
                "unsupervised": true,
            ],
            "levels": [],
            "modes": ["default", "acceptEdits", "plan"],
        ]
    }

    static let models: JSON = [
        ["id": "gemini-3.8-flash-high", "name": "Gemini 3.8 Flash (High)", "description": "", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
        ["id": "gemini-3.1-pro-high", "name": "Gemini 3.1 Pro (High)", "description": "", "efforts": [],
         "fast": false, "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
    ]

    static let registry: JSON = [
        "id": "antigravity", "name": "Antigravity", "agent": "Antigravity", "route": "its stream-json mode", "binary": true, "key": true,
        "keyName": "Gemini API key",
        "forbidden": [["id": "google", "title": "Antigravity with a Google account", "maker": "Google", "sentence": "Using third party software…",
                       "url": "https://antigravity.google/terms"]],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "antigravity"
        chat.started = true
        chat.sessionId = "c-1"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, try Self.entry().decode(ProviderInfo.self)]
        model.modelsByAgent["antigravity"] = try Self.models.decode([ModelOption].self)
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func itsThreeModesShowWithTheUnsupervisedLineAndNoRail() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes == [.ask, .acceptEdits, .plan])
        #expect(state.unsupervised)
        #expect(state.option?.efforts == [])
        #expect(model.modelSent(in: chat) == "gemini-3.8-flash-high")
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
        #expect(rows.first { $0.id == "terminal.claude" }?.title == "Continue in Antigravity")
        for id in ["thread.copySession", "mode.list", "mode.acceptEdits", "mode.plan"] { #expect(ids.contains(id), "\(id) missing") }
        for id in ["thread.compact", "heads", "effort.list", "mode.auto", "mode.bypassPermissions"] { #expect(!ids.contains(id), "\(id) offered") }
    }

    @Test func itsRowTakesAGeminiKeyAndKeepsTheGoogleAccountOff() throws {
        let row = try Self.registry.decode(AgentInfo.self)
        #expect(row.key && row.binary)
        #expect(row.keyName == "Gemini API key")
        #expect(row.forbidden.map(\.id) == ["google"])
        #expect(row.status(model.providerInfo("antigravity"), on: true, checking: false) == "Signed in.")
        let google = "Antigravity signs in with a Google account, which Google keeps to its own apps. Set \"modelProvider\": \"gemini\" in ~/.gemini/antigravity-cli/settings.json and add a Gemini API key here, or turn on “Antigravity with a Google account”."
        let refused = try Self.entry("signedOut", hint: .string(google)).decode(ProviderInfo.self)
        #expect(row.status(refused, on: true, checking: false) == google)

        let suite = "OriCodeTests.antigravity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AgentSettings(defaults: defaults)
        model.agentSettings = settings
        model.keychain = Keychain(prefix: "OriCodeTests.\(UUID().uuidString)")
        settings.turn("antigravity", on: true)
        #expect(!settings.allows("antigravity", "google"))
        #expect(model.agentsForHello == .object(["antigravity": .object(["key": .bool(false), "allow": .array([])])]))
        settings.allow("google", for: "antigravity", true)
        #expect(model.agentsForHello == .object(["antigravity": .object(["key": .bool(false), "allow": .array([.string("google")])])]))
    }
}
