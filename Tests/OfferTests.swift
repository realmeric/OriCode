import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread offers only what its agent can do: a stand-in that can do nothing shows how little.
@MainActor
struct OfferTests {
    private let container: ModelContainer
    private let project: Project
    private let chat: Chat
    private let model: AppModel

    /// An agent with no levels, no modes, no steering and no heads, that can't pick up a session,
    /// compact, attach, list commands or be continued anywhere.
    static let standIn = ProviderInfo(
        id: "standin", name: "Stand-in CLI", agent: "Stand-in", state: .ready, hint: nil, cli: "/usr/local/bin/standin", version: "1.0",
        capabilities: ProviderInfo.Capabilities(
            steer: false, resume: false, modeLive: false, attachments: false, heads: false, stopTask: false, limits: false,
            usage: false, commands: false, compact: false, commitMessage: false, handoff: nil),
        levels: [], modes: [])

    static let models = [
        ModelOption(id: "default", name: "Default (recommended)", description: "", efforts: ["low", "medium", "high", "xhigh", "max"],
                    fast: true, defaultEffort: "high", ultra: true, ultraBlocked: nil, more: nil, needs: nil),
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = Self.standIn.id
        // A draft would be cleared as the model starts.
        chat.started = true
        chat.sessionId = "s1"
        chat.effort = "max"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.models = Self.models
        model.modelsByAgent[Self.standIn.id] = Self.models
        model.providers = [.claude, Self.standIn]
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func theStandInHasNoRailAndNoTiles() {
        let state = PickerState(model: model, chat: chat)
        #expect(state.option?.stops == [])
        #expect(state.effort == nil)
        #expect(state.level == nil)
        #expect(state.modes.isEmpty)
        #expect(!state.unsupervised)
        // Claude's thread keeps all of it.
        chat.provider = nil
        let claude = PickerState(model: model, chat: chat)
        #expect(claude.option?.stops == ["low", "medium", "high", "xhigh", "max", Effort.ultracode])
        #expect(claude.effort == "max")
        #expect(claude.modes == PermissionModeOption.allCases)
        #expect(claude.option == Self.models[0])
    }

    @Test func returnQueuesWhenTheAgentCantSteer() {
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        #expect(model.send("And then the lint"))
        #expect(conversation.queue.map(\.text) == ["And then the lint"])
        #expect(conversation.waiting.isEmpty)
    }

    @Test func anUnsupervisedAgentHasNoModesAndSaysSo() throws {
        let reply: JSON = [
            "steer": false, "resume": true, "modeLive": false, "attachments": false, "heads": false, "stopTask": false,
            "limits": false, "usage": false, "commands": false, "compact": false, "commitMessage": false, "handoff": .null,
            "unsupervised": true,
        ]
        let capabilities = try reply.decode(ProviderInfo.Capabilities.self)
        #expect(capabilities.unsupervised == true)
        let pi = ProviderInfo(id: "pi", name: "Pi", agent: "Pi", state: .ready, hint: nil, cli: nil, version: nil,
                              capabilities: capabilities, levels: [], modes: ["default"])
        model.providers = [.claude, pi]
        chat.provider = "pi"
        let state = PickerState(model: model, chat: chat)
        #expect(state.modes.isEmpty)
        #expect(state.unsupervised)
        // Claude Code's, which never sends it, reads as supervised.
        #expect(ProviderInfo.claude.capabilities.unsupervised == nil)
        #expect(model.agent(for: nil).permissionModes == PermissionModeOption.allCases)
    }

    @Test func nothingElseTheStandInCantDoIsOffered() {
        model.engineState = .ready
        let rows = Set(model.paletteSearchable().map(\.id))
        for id in ["thread.compact", "thread.copySession", "heads", "effort.list", "mode.list", "terminal.claude"] {
            #expect(!rows.contains(id), "\(id) offered")
        }
        #expect(!rows.contains { $0.hasPrefix("mode.") || $0.hasPrefix("effort.") })
        model.toggleHeads()
        #expect(!model.headsShown)
        #expect(!model.attach(fileAt: URL(filePath: "/tmp/alpha/picture.png")))
        model.loadCommands(for: chat)
        #expect(model.slashCommands[Self.standIn.id] == nil)
        // Claude's thread has them all.
        chat.provider = nil
        let claude = Set(model.paletteSearchable().map(\.id))
        for id in ["thread.copySession", "heads", "effort.list", "mode.list", "terminal.claude", "mode.plan", "effort.max"] {
            #expect(claude.contains(id), "\(id) missing")
        }
        #expect(model.paletteSearchable().first { $0.id == "terminal.claude" }?.title == "Continue in Claude Code")
    }

    @Test func aThreadNamesItsOwnAgent() {
        let conversation = model.conversation(for: chat)
        conversation.userSent("Hi")
        conversation.receive(EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["event": "text", "delta": "Hello"]))
        conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["stopReason": "end_turn"]))
        #expect(model.threadMarkdown == "**You**\n\nHi\n\n**Stand-in**\n\nHello")
        chat.provider = nil
        #expect(model.threadMarkdown == "**You**\n\nHi\n\n**Claude**\n\nHello")
    }

    @Test func aThreadWhoseAgentCantPickUpIsntSentOnAfterAQuit() {
        model.engineState = .ready
        chat.quitMidTurn = true
        model.pickUpAfterQuit()
        #expect(!chat.quitMidTurn)
        let items = model.conversation(for: chat).items
        #expect(!items.contains { if case .user = $0 { true } else { false } })
        #expect(items.contains { if case .note = $0 { true } else { false } })
    }

    @Test func anAgentHelloDoesntListOffersNothing() {
        chat.provider = "gone"
        let agent = model.agent(for: chat)
        #expect(agent.id == "gone")
        #expect(agent.levels.isEmpty && agent.permissionModes.isEmpty)
        #expect(!agent.capabilities.steer && agent.capabilities.handoff == nil)
        #expect(PickerState(model: model, chat: chat).option == nil)
    }
}
