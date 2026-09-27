import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What a Cursor thread needs of the app beyond what every ACP agent gets: the help on its Allow
/// always, which writes into Cursor's own allowlist, and its two modes.
@MainActor
struct CursorTests {
    private let container: ModelContainer
    private let project: Project

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
    }

    private static let cursor = ProviderInfo(
        id: "cursor", name: "Cursor", agent: "Cursor", state: .ready, hint: nil, cli: "/Users/x/.local/bin/cursor-agent", version: "2026.09.02",
        capabilities: ProviderInfo.Capabilities(
            steer: false, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false,
            usage: false, commands: true, compact: false, commitMessage: false, handoff: nil),
        levels: [], modes: ["acceptEdits", "plan"])

    @Test func anAllowAlwaysCarriesWhatCursorDoesWithIt() throws {
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.userSent("Run it")
        let help = "Cursor adds this to its own allowlist, which every Cursor session on this Mac follows."
        conversation.receive(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": "r", "kind": "permission", "tool": "Terminal", "toolKind": "run", "toolUseId": "t", "input": [:],
            "view": ["command": "echo hi"],
            "choices": [
                ["id": "allow-once", "name": "Allow once", "kind": "allow_once"],
                ["id": "allow-always", "name": "Allow always", "kind": "allow_always", "help": .string(help)],
                ["id": "reject-once", "name": "Reject", "kind": "reject_once"],
            ],
        ]))
        let ask = try #require(conversation.waitingAsk)
        #expect(ask.choices.map(\.help) == [nil, help, nil])
    }

    @Test func aDraftMovedOntoCursorTakesItsModeAndOffersOnlyItsTwo() {
        let model = AppModel(container: container)
        model.providers = [.claude, Self.cursor]
        model.modelsByAgent["cursor"] = [
            ModelOption(id: "default[]", name: "Auto", description: "", efforts: [], fast: false, defaultEffort: nil, ultra: false,
                        ultraBlocked: nil, more: nil, needs: nil),
        ]
        let draft = Chat(project: project, permissionMode: "default")
        container.mainContext.insert(draft)
        model.setModel(ModelRef(provider: "cursor", id: "default[]"), for: draft)
        #expect(draft.provider == "cursor")
        #expect(draft.permissionMode == "acceptEdits")
        #expect(model.agent(for: draft).permissionModes == [.acceptEdits, .plan])
        #expect(model.option(for: draft)?.efforts == [])
    }
}
