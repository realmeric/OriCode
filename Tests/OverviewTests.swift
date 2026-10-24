import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct OverviewTests {
    /// Two projects: in alpha, Lead opened Primes and Sums, Primes opened Test, and Quiet is a
    /// thread of its own; in beta, Docs. Nothing has run yet.
    private func model() throws -> (AppModel, alpha: Project, beta: Project, lead: Chat, primes: Chat, test: Chat, quiet: Chat, docs: Chat) {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(alpha)
        context.insert(beta)
        let start = Date(timeIntervalSince1970: 1_000)
        func thread(_ title: String, in project: Project, after seconds: Double, openedBy opener: Chat? = nil) -> Chat {
            let chat = Chat(project: project, title: title)
            chat.started = true
            chat.createdAt = start.addingTimeInterval(seconds)
            chat.openedBy = opener?.id
            context.insert(chat)
            return chat
        }
        let quiet = thread("Quiet", in: alpha, after: 0)
        let lead = thread("Lead", in: alpha, after: 1)
        let primes = thread("Primes", in: alpha, after: 2, openedBy: lead)
        let test = thread("Test", in: alpha, after: 3, openedBy: primes)
        _ = thread("Sums", in: alpha, after: 3.5, openedBy: lead)
        let docs = thread("Docs", in: beta, after: 4)
        try context.save()
        let model = AppModel(container: container)
        model.selectedProjectID = alpha.id
        return (model, alpha, beta, lead, primes, test, quiet, docs)
    }

    private func titles(_ model: AppModel) -> [[String]] {
        model.overview.map { section in [section.project.name] + section.rows.map(\.chat.title) }
    }

    @Test func aThreadThatRunsIsListedAloneWithNoneUnderAnother() throws {
        let (model, _, _, _, _, test, _, docs) = try model()
        #expect(model.overview.isEmpty)

        model.route(EngineEvent(name: "turn.started", threadId: test.id.uuidString, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "turn.started", threadId: docs.id.uuidString, body: ["event": "turn.started"]))
        // Each project under its name, in the projects' order; Lead and Primes, which opened Test,
        // aren't brought along, and nor is Quiet, which nothing touched.
        #expect(titles(model) == [["alpha", "Test"], ["beta", "Docs"]])
        #expect(model.status(of: test).state == .working)
    }

    @Test func theRowsAreTheSameWhicheverThreadIsOpen() throws {
        let (model, _, _, _, primes, _, quiet, _) = try model()

        // Nothing run leaves the screen empty, whichever thread is open, one with threads under
        // it or one on its own.
        model.select(quiet)
        #expect(model.overview.isEmpty)
        model.select(primes)
        #expect(model.overview.isEmpty)
    }

    @Test func eachTurnSaysHowItEnded() throws {
        let (model, _, _, lead, _, _, quiet, docs) = try model()
        let id = { (chat: Chat) in chat.id.uuidString }

        model.route(EngineEvent(name: "turn.started", threadId: id(lead), body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "text", threadId: id(lead), body: ["event": "text", "delta": "All three passed.\nMore."]))
        model.route(EngineEvent(name: "turn.done", threadId: id(lead), body: ["event": "turn.done", "stopReason": "end_turn"]))
        model.route(EngineEvent(name: "turn.started", threadId: id(quiet), body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "turn.done", threadId: id(quiet), body: ["event": "turn.done", "stopReason": "interrupted"]))
        model.route(EngineEvent(name: "turn.started", threadId: id(docs), body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "turn.done", threadId: id(docs), body: ["event": "turn.done", "stopReason": "error_during_execution"]))

        #expect(model.status(of: lead) == OverviewStatus(state: .done, step: nil))
        #expect(model.status(of: quiet).state == .stopped)
        #expect(model.status(of: docs).state == .failed)
        #expect(titles(model) == [["alpha", "Lead", "Quiet"], ["beta", "Docs"]])

        // A thread waiting for its limit waits, whatever its last turn said.
        quiet.resumeAt = Date.now.addingTimeInterval(600)
        #expect(model.status(of: quiet).state == .waiting)

        // A turn stopped before it wrote anything says nothing, not the turn before's reply.
        model.conversation(for: lead).userSent("Again", previews: [], id: UUID())
        model.route(EngineEvent(name: "turn.started", threadId: id(lead), body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "turn.done", threadId: id(lead), body: ["event": "turn.done", "stopReason": "interrupted"]))
        #expect(model.status(of: lead) == OverviewStatus(state: .stopped, step: nil))
    }

    @Test func aTurnTheEngineTookWithItIsStopped() throws {
        let (model, _, _, lead, _, _, _, _) = try model()
        let id = lead.id.uuidString
        model.conversation(for: lead).userSent("Count", previews: [], id: UUID())
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "text", threadId: id, body: ["event": "text", "delta": "One, two"]))
        model.engineStopped()
        #expect(model.status(of: lead) == OverviewStatus(state: .stopped, step: "One, two"))
        #expect(titles(model) == [["alpha", lead.title]])
    }

    @Test func aRunIsItsThreadsLineAndNotItsAgentsRowsAcrossARelaunch() throws {
        let (model, alpha, _, lead, _, _, _, _) = try model()
        let id = lead.id.uuidString
        model.conversation(for: lead).userSent("Review it", previews: [], id: UUID())
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "tool.use", threadId: id, body: ["event": "tool.use", "toolUseId": "call", "name": "Workflow", "input": .object([:])]))
        // Claude Code answers the call as the run starts in the background.
        model.route(EngineEvent(name: "tool.result", threadId: id, body: ["event": "tool.result", "toolUseId": "call", "content": "Started", "isError": false]))
        model.route(EngineEvent(name: "heads", threadId: id, body: ["heads": [["id": "w1", "kind": "workflow", "toolUseId": "call", "label": "Echo"]]]))
        model.route(EngineEvent(name: "workflow", threadId: id, body: ["taskId": "w1", "toolUseId": "call", "state": "running", "name": "Echo", "agents": [
            ["label": "alpha", "agentId": "a1", "state": "running", "lastTool": "Bash", "lastDetail": "echo alpha-3"],
            ["label": "beta", "agentId": "b2", "state": "done", "result": "beta-10"],
        ]]))
        #expect(model.agents(under: lead).count == 2)
        #expect(titles(model) == [["alpha", lead.title]])
        guard case .run(let call) = model.stageLine(of: lead) else {
            Issue.record("no run line")
            return
        }
        #expect(call.toolUseId == "call")

        // Quit and relaunched, the thread cut off is sent on with the quit's line, and its run,
        // read from the store, is still its line; a click opens it with the run's stage up.
        model.markCutOffTurns()
        #expect(lead.quitMidTurn)
        let again = AppModel(container: alpha.modelContext!.container)
        again.conversation(for: lead).userSent(AppModel.quitLine, previews: [], id: UUID())
        again.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started"]))
        #expect(titles(again) == [["alpha", lead.title]])
        let line = try #require(again.stageLine(of: lead))
        guard case .run(let stored) = line else {
            Issue.record("no run line after the relaunch")
            return
        }
        #expect(stored.toolUseId == "call")
        again.toggleOverview()
        again.openStage(of: lead, line: line, beside: false)
        #expect(again.selectedChatID == lead.id && !again.overviewShown)
        #expect(again.stage.shown[lead.id] == "call")

        // Something said since is the thread's latest, and the run's line goes.
        again.conversation(for: lead).userSent("Thanks", previews: [], id: UUID())
        #expect(again.stageLine(of: lead) == nil)
    }

    @Test func aRowsClickOpensItsThreadAndTheScreenGoes() throws {
        let (model, _, _, _, _, test, _, _) = try model()
        model.route(EngineEvent(name: "turn.started", threadId: test.id.uuidString, body: ["event": "turn.started"]))
        model.toggleOverview()
        #expect(model.overviewShown)
        // One surface at a time out of the capsule.
        model.openInIsland(.command)
        #expect(!model.overviewShown && model.commandCenterShown)
        model.toggleOverview()
        #expect(model.overviewShown && !model.commandCenterShown)

        model.openFromOverview(test, beside: false)
        #expect(model.selectedChatID == test.id && !model.overviewShown)

        model.toggleOverview()
        #expect(model.escape())
        #expect(!model.overviewShown)
    }
}
