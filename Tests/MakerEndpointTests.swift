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
}
