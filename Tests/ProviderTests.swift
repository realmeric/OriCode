import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Which agent a thread is on, and how the defaults name a model with its agent.
@MainActor
struct ProviderTests {
    private let container: ModelContainer
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        container.mainContext.insert(chat)
    }

    @Test func aBareIdIsClaudesAndAnotherAgentsCarriesItsName() {
        let claude = ModelRef(stored: "opus")
        #expect(claude == ModelRef(provider: "claude", id: "opus"))
        #expect(claude.stored == "opus")
        let codex = ModelRef(stored: "codex/gpt-6-luna")
        #expect(codex == ModelRef(provider: "codex", id: "gpt-6-luna"))
        #expect(codex.stored == "codex/gpt-6-luna")
        // OpenRouter's ids have a slash of their own.
        let routed = ModelRef(stored: "openrouter/anthropic/claude-sonnet-4.5")
        #expect(routed == ModelRef(provider: "openrouter", id: "anthropic/claude-sonnet-4.5"))
        #expect(routed.stored == "openrouter/anthropic/claude-sonnet-4.5")
        let arn = "arn:aws:bedrock:us-east-1:1234:application-inference-profile/abc"
        #expect(ModelRef(stored: arn) == ModelRef(provider: "claude", id: arn))
    }

    @Test func theLastModelIsReadAndWrittenWithItsAgent() {
        let defaults = UserDefaults.standard
        let kept = defaults.object(forKey: "lastModel")
        defer { defaults.set(kept, forKey: "lastModel") }
        let model = AppModel(container: container)

        defaults.set("haiku", forKey: "lastModel")
        #expect(model.lastModel == ModelRef(provider: "claude", id: "haiku"))
        #expect(model.startingModel == "haiku")
        // Another agent's model isn't one a Claude thread starts on.
        defaults.set("codex/gpt-6-luna", forKey: "lastModel")
        #expect(model.lastModel == ModelRef(provider: "codex", id: "gpt-6-luna"))
        #expect(model.startingModel == nil)

        model.lastModel = ModelRef(provider: "claude", id: "opus")
        #expect(defaults.string(forKey: "lastModel") == "opus")
        model.lastModel = ModelRef(provider: "codex", id: "gpt-6-luna")
        #expect(defaults.string(forKey: "lastModel") == "codex/gpt-6-luna")
    }

    @Test func aThreadFromBeforeIsClaudesAndClaudeIsAssumedUntilHello() {
        let model = AppModel(container: container)
        #expect(chat.provider == nil)
        #expect(model.provider(for: chat) == .claude)
        #expect(model.startingProvider == "claude")
        chat.provider = "codex"
        #expect(model.providerID(for: chat) == "codex")
        #expect(model.provider(for: chat) == nil)
    }

    @Test func onlyAnotherAgentsRequestsNameIt() {
        let params: [String: JSON] = ["threadId": "t", "cwd": "/tmp/alpha"]
        #expect(params.naming("claude") == params)
        #expect(params.naming("codex") == ["threadId": "t", "cwd": "/tmp/alpha", "provider": "codex"])
    }

    @Test func helloListsTheAgents() throws {
        let reply: JSON = [
            "version": "0.2.0", "models": [], "claude": "/usr/local/bin/claude", "loggedIn": false,
            "providers": [[
                "id": "claude", "name": "Claude Code", "agent": "Claude", "state": "signedOut",
                "hint": "Run `claude` in Terminal and log in.", "cli": "/usr/local/bin/claude", "version": "2.1.282 (Claude Code)",
                "capabilities": [
                    "steer": true, "resume": true, "modeLive": true, "attachments": true, "heads": true, "stopTask": true,
                    "limits": true, "usage": true, "commands": true, "compact": true, "commitMessage": true,
                    "handoff": "claude --resume {session}",
                ],
                "levels": ["low", "medium", "high", "xhigh", "max", "ultracode"],
                "modes": ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
            ]],
        ]
        let hello = try reply.decode(Hello.self)
        let claude = try #require(hello.providers.first)
        #expect(claude.state == .signedOut)
        #expect(claude.hint == "Run `claude` in Terminal and log in.")
        #expect(claude.version == "2.1.282 (Claude Code)")
        // Assumed before hello the way hello describes it.
        #expect(claude.capabilities == ProviderInfo.claude.capabilities)
        #expect(claude.levels == ProviderInfo.claude.levels)
        #expect(claude.modes == ProviderInfo.claude.modes)
    }
}
