import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread on Z.ai is Claude Code pointed at Z.ai's endpoint: it keeps Claude's thread, and
/// nothing of Claude's plan, its usage, its limits or fast mode, shows on it.
@MainActor
struct MakerEndpointTests {
    private let container: ModelContainer
    private let chat: Chat
    private let model: AppModel

    /// Z.ai as the engine's hello lists it, and its models as models.list gives them.
    static let zaiEntry: JSON = [
        "id": "zai", "name": "Z.ai", "agent": "Z.ai", "state": "ready", "hint": .null, "cli": "/usr/local/bin/claude", "version": .null,
        "capabilities": [
            "steer": true, "resume": true, "modeLive": true, "attachments": true, "heads": false, "stopTask": false, "limits": false,
            "usage": false, "commands": true, "compact": true, "commitMessage": true, "handoff": .null,
        ],
        "levels": [], "modes": ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
    ]
    static let zaiModels: JSON = [
        ["id": "glm-5.3[1m]", "name": "GLM-5.3", "description": "1M context", "efforts": [], "fast": false, "defaultEffort": .null,
         "ultra": false, "ultraBlocked": .null],
        ["id": "glm-5.3-flash[1m]", "name": "GLM-5.3-Flash", "description": "1M context", "efforts": [], "fast": false,
         "defaultEffort": .null, "ultra": false, "ultraBlocked": .null],
    ]

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "zai"
        chat.model = "glm-5.3[1m]"
        chat.started = true
        chat.sessionId = "s1"
        // Carried over from a Claude thread's defaults, it must still not show.
        chat.fastMode = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.models = OfferTests.models
        model.modelsByAgent["zai"] = try Self.zaiModels.decode([ModelOption].self)
        model.providers = [.claude, try Self.zaiEntry.decode(ProviderInfo.self)]
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
    }

    @Test func aZaiThreadHidesUsageLimitsAndFast() {
        model.engineState = .ready
        let agent = model.agent(for: chat)
        #expect(agent.name == "Z.ai")
        // The composer draws the usage glass only for an agent with usage, and asks for none here.
        #expect(!agent.capabilities.usage)
        model.refreshUsage()
        #expect(!model.usageLoading)
        #expect(model.usage == nil)
        // Settings' At a usage limit lists only agents whose limits reach the app, and no reset waits on this one.
        #expect(model.providers.filter { $0.capabilities.limits && $0.capabilities.resume }.map(\.id) == ["claude"])
        // Fast mode: off whatever the thread kept, the picker's bolt unlit, and no ⌘K row.
        let state = PickerState(model: model, chat: chat)
        #expect(state.option?.id == "glm-5.3[1m]")
        #expect(state.option?.fast == false)
        #expect(!state.fastAsked)
        #expect(!model.fastMode(of: chat))
        let rows = Set(model.paletteSearchable().map(\.id))
        #expect(!rows.contains("fast.toggle"))
        // No levels, no Ultracode, and no Continue in, since `claude --resume` would go to Anthropic.
        #expect(state.option?.stops == [])
        #expect(!rows.contains("effort.list") && !rows.contains("terminal.claude"))
        // Claude's thread keeps its glass and its bolt.
        chat.provider = nil
        chat.model = nil
        #expect(model.agent(for: chat).capabilities.usage)
        #expect(model.paletteSearchable().contains { $0.id == "fast.toggle" })
    }

    /// OpenRouter and Meta run in Claude Code the same way. Their levels are each model's own,
    /// with no Ultracode even where a model has xhigh, since that's Claude Code's workflows on
    /// Claude's plan.
    @Test func openRouterAndMetaThreadsHideWhatTheyCantDo() throws {
        model.engineState = .ready
        let cases: [(id: String, name: String, model: String, efforts: [String])] = [
            ("openrouter", "OpenRouter", "openai/gpt-5.6-sol[1m]", ["low", "medium", "high", "xhigh", "max"]),
            ("meta", "Meta", "muse-spark-1.3[1m]", ["low", "medium", "high", "xhigh"]),
        ]
        for maker in cases {
            var entry = Self.zaiEntry
            if case .object(var fields) = entry {
                fields["id"] = .string(maker.id)
                fields["name"] = .string(maker.name)
                fields["agent"] = .string(maker.name)
                fields["levels"] = .array(maker.efforts.map(JSON.string))
                entry = .object(fields)
            }
            let listed: JSON = [
                ["id": .string(maker.model), "name": "A model", "description": "1M context", "efforts": .array(maker.efforts.map(JSON.string)),
                 "fast": false, "defaultEffort": "medium", "ultra": false, "ultraBlocked": .null],
            ]
            model.modelsByAgent[maker.id] = try listed.decode([ModelOption].self)
            model.providers = [.claude, try entry.decode(ProviderInfo.self)]
            chat.provider = maker.id
            chat.model = maker.model
            chat.fastMode = true

            let agent = model.agent(for: chat)
            #expect(agent.name == maker.name)
            #expect(!agent.capabilities.usage && !agent.capabilities.limits && agent.capabilities.handoff == nil)
            model.refreshUsage()
            #expect(model.usage == nil)
            let state = PickerState(model: model, chat: chat)
            #expect(state.option?.id == maker.model)
            #expect(state.option?.stops == maker.efforts)
            #expect(!model.fastMode(of: chat))
            let rows = Set(model.paletteSearchable().map(\.id))
            #expect(!rows.contains("fast.toggle") && !rows.contains("terminal.claude"))
            #expect(rows.contains("effort.list"))
        }
    }
}
