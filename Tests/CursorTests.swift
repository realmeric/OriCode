import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What a Cursor thread needs of the app beyond what every ACP agent gets: the help on its Allow
/// always, which writes into Cursor's own allowlist, and its three modes.
@MainActor
struct CursorTests {
    private let container: ModelContainer
    private let project: Project

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
    }

    private static let cursor = ProviderInfo(
        id: "cursor", name: "Cursor", agent: "Cursor", state: .ready, hint: nil, cli: "/Users/x/.local/bin/cursor-agent", version: "2026.09.02",
        capabilities: ProviderInfo.Capabilities(
            steer: false, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false,
            usage: false, commands: true, compact: false, commitMessage: false, handoff: nil),
        levels: [], modes: ["acceptEdits", "plan", "bypassPermissions"])

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

    /// Don't ask picked while Cursor waited: the engine answers the ask, and the card says it went ahead.
    @Test func anAskTheThreadsModeAnsweredReadsAsAllowed() {
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        let conversation = Conversation(chat: chat, context: container.mainContext)
        conversation.userSent("Run it")
        conversation.receive(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": "r", "kind": "permission", "tool": "Terminal", "toolKind": "run", "toolUseId": "t", "input": [:],
            "view": ["command": "echo hi"],
            "choices": [["id": "allow-once", "name": "Allow once", "kind": "allow_once"]],
        ]))
        #expect(conversation.waitingAsk != nil)
        conversation.receive(EngineEvent(name: "ask.answered", threadId: chat.id.uuidString, body: [
            "event": "ask.answered", "requestId": "r", "allow": true,
        ]))
        #expect(conversation.waitingAsk == nil)
        let states = conversation.items.compactMap { item -> PendingAsk.State? in
            if case .ask(_, let ask) = item { ask.state } else { nil }
        }
        #expect(states == [.allowed])
    }

    @Test func aDraftMovedOntoCursorTakesItsModeAndOffersOnlyItsThree() {
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
        #expect(model.agent(for: draft).permissionModes == [.acceptEdits, .plan, .dontAsk])
        #expect(model.option(for: draft)?.efforts == [])
    }
}
