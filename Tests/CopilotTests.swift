import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A GitHub account signed in to Copilot's CLI with no Copilot plan, Meriç's today: a state of its
/// own, whose line is GitHub's and whose Retry asks again after a sign-up in Terminal.
@MainActor
struct CopilotTests {
    private let container: ModelContainer
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        chat = Chat(project: project)
        chat.provider = "copilot"
        // Started, or the model would clear it as a draft.
        chat.started = true
        container.mainContext.insert(chat)
    }

    private static let line = "You don't currently have a Copilot subscription. Run `copilot` in Terminal to sign up for Copilot Free."

    @Test func noPlanIsItsOwnStateWithGitHubsLine() throws {
        let hello = Data("""
        {"id": "copilot", "name": "GitHub Copilot", "agent": "Copilot", "state": "noPlan", "hint": "\(Self.line)",
         "cli": "/opt/homebrew/bin/copilot", "version": "1.0.86",
         "capabilities": {"steer": false, "resume": true, "modeLive": true, "attachments": true, "heads": false, "stopTask": false,
                          "limits": false, "usage": false, "commands": true, "compact": false, "commitMessage": false,
                          "handoff": "copilot --resume {session}"},
         "levels": ["low", "medium", "high"], "modes": ["default", "plan", "bypassPermissions"]}
        """.utf8)
        let copilot = try JSONDecoder().decode(ProviderInfo.self, from: hello)
        #expect(copilot.state == .noPlan)
        let row = AgentInfo(id: "copilot", name: "GitHub Copilot", agent: "Copilot", route: "ACP", binary: true, key: false, forbidden: [])
        #expect(row.status(copilot, on: true, checking: false) == Self.line)

        let model = AppModel(container: container)
        model.engineState = .ready
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        model.providers = [.claude, copilot]
        #expect(model.agentDown?.hint == Self.line)
        #expect(!model.agentReady(for: chat))
        #expect(model.agent(for: chat).permissionModes == [.ask, .plan, .dontAsk])
    }
}
