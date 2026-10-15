import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Sessions from other tools coming in as threads: on the agent that ran them, picking the session
/// up, where that agent is turned on and can be given a session by its id, and otherwise on the
/// agent a new thread starts on, which the next message hands the transcript over to.
@MainActor
struct ImportSessionsTests {
    private let container: ModelContainer
    private let project: Project
    private let model: AppModel
    private let events: [JSON] = [
        ["event": "user", "text": "Why does the drawer flicker?"],
        ["event": "text", "delta": "It redraws on every scroll."],
    ]

    /// Codex as hello gives it when it's turned on: it picks a thread up by its id.
    static let codex = ProviderInfo(
        id: "codex", name: "Codex", agent: "Codex", state: .ready, hint: nil, cli: "/usr/local/bin/codex", version: "0.157.1",
        capabilities: ProviderInfo.Capabilities(
            steer: true, resume: true, modeLive: false, attachments: true, heads: false, stopTask: false, limits: true,
            usage: true, commands: false, compact: false, commitMessage: false, handoff: "codex resume --no-daemon {session}"),
        levels: ["low", "medium", "high"], modes: ["default", "plan"])

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.providers = [.claude, Self.codex]
        model.selectedProjectID = project.id
    }

    private func session(_ source: String, _ id: String, agent: String?, sessionId: String?) -> OutsideSession {
        OutsideSession(source: source, sourceName: source, id: id, agent: agent, sessionId: sessionId, title: "The drawer", modified: 0, branch: nil)
    }

    @Test func aT3CodeThreadOnCodexComesInOnCodexWithItsSession() {
        let found = session("t3code", "t-1", agent: "codex", sessionId: "019a-tui")
        #expect(model.resumes(found))
        let chat = model.adopt(found, events: events, in: project)
        #expect(chat.providerID == "codex" && chat.sessionId == "019a-tui")
        #expect(chat.importedFrom == "t3code/t-1" && !chat.handover && chat.started)
        #expect(model.handover(for: chat) == nil)
        // Its next message resumes Codex's thread.
        let params = model.sendParams(in: chat, text: "Go on", images: [])
        #expect(params["provider"]?.string == "codex" && params["sessionId"]?.string == "019a-tui")
    }

    @Test func aSessionNoAgentHereCanPickUpComesInOnTheStartingAgentWithAHandover() {
        for found in [session("cursor", "chat-1", agent: "cursor", sessionId: nil), session("copilot", "c-1", agent: "copilot", sessionId: "c-1")] {
            #expect(!model.resumes(found))
            let chat = model.adopt(found, events: events, in: project)
            #expect(chat.providerID == "claude" && chat.sessionId == nil && chat.handover)
            #expect(chat.importedFrom == found.key)
            #expect(model.conversation(for: chat).items.count == 2)
            // The next message goes with the transcript, for the agent it's handed over to.
            model.conversation(for: chat).userSent("Go on")
            #expect(model.handover(for: chat)?.contains("User: Why does the drawer flicker?\nAssistant: It redraws on every scroll.") == true)
        }
    }

    @Test func aThreadOnAnotherAgentTakesAModeThatAgentHas() {
        let codex = Self.codex
        model.providers = [.claude, ProviderInfo(id: codex.id, name: codex.name, agent: codex.agent, state: .ready, hint: nil, cli: codex.cli, version: codex.version,
                                                 capabilities: codex.capabilities, levels: codex.levels, modes: ["acceptEdits"])]
        let chat = model.adopt(session("codex", "019a-app", agent: "codex", sessionId: "019a-app"), events: events, in: project)
        #expect(chat.providerID == "codex" && chat.permissionMode == "acceptEdits")
    }
}
