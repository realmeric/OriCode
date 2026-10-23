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
        model.overview.map { section in [section.project.name] + section.rows.map { String(repeating: "  ", count: $0.depth) + $0.chat.title } }
    }

    @Test func aThreadThatRunsBringsTheThreadsAboveItAndNothingElse() throws {
        let (model, _, _, _, primes, test, _, docs) = try model()
        #expect(model.overview.isEmpty)

        model.route(EngineEvent(name: "turn.started", threadId: test.id.uuidString, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "turn.started", threadId: docs.id.uuidString, body: ["event": "turn.started"]))
        // Each project under its name, in the projects' order; the tree the drawer's; Quiet, which
        // nothing touched, isn't listed, and nor is Sums, Primes's sibling, which didn't run.
        #expect(titles(model) == [["alpha", "Lead", "  Primes", "    Test"], ["beta", "Docs"]])
        #expect(model.status(of: test).state == .working)
        // Lead and Primes are there for Test's sake, with no state of their own.
        #expect(model.status(of: primes).state == .idle && model.status(of: primes).word.isEmpty)
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

    @Test func aWorkflowsAgentsComeUnderItsThreadWithTheirStateAndStep() throws {
        let (model, alpha, _, lead, _, _, _, _) = try model()
        let id = lead.id.uuidString
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "heads", threadId: id, body: ["heads": [["id": "w1", "kind": "workflow", "label": "Echo"]]]))
        let snapshot: JSON = ["taskId": "w1", "state": "running", "name": "Echo", "agents": [
            ["label": "alpha", "agentId": "a1", "state": "running", "lastTool": "Bash", "lastDetail": "echo alpha-3"],
            ["label": "beta", "agentId": "b2", "state": "done", "result": "beta-10"],
            ["label": "gamma", "state": "queued"],
        ]]
        model.route(EngineEvent(name: "workflow", threadId: id, body: snapshot))

        #expect(titles(model) == [["alpha", "Lead", "  alpha", "  beta"]])
        let agents = model.agents(under: lead)
        let first = try #require(agents.first { $0.agentID == "a1" })
        let second = try #require(agents.first { $0.agentID == "b2" })
        #expect(model.status(of: first) == OverviewStatus(state: .working, step: "echo alpha-3"))
        #expect(model.status(of: second) == OverviewStatus(state: .done, step: nil))

        // A relaunch stops the agent the last launch left running, and lists it stopped; the one
        // that had ended, under a thread nothing touched since, isn't listed.
        let again = AppModel(container: alpha.modelContext!.container)
        #expect(titles(again) == [["alpha", "Lead", "  alpha"]])
        #expect(again.status(of: first).state == .stopped)
    }

    @Test func agentsWithOneLabelEachSayTheirOwnStep() throws {
        let (model, _, _, lead, _, _, _, _) = try model()
        let id = lead.id.uuidString
        model.route(EngineEvent(name: "turn.started", threadId: id, body: ["event": "turn.started"]))
        model.route(EngineEvent(name: "heads", threadId: id, body: ["heads": [["id": "w1", "kind": "workflow", "label": "Echo"]]]))
        // A script that names no agent leaves each its type for a label.
        model.route(EngineEvent(name: "workflow", threadId: id, body: ["taskId": "w1", "state": "running", "name": "Echo", "agents": [
            ["label": "general-purpose", "agentId": "a1", "state": "running", "lastTool": "Bash", "lastDetail": "echo one"],
            ["label": "general-purpose", "agentId": "a2", "state": "running", "lastTool": "Read", "lastDetail": "two.txt"],
        ]]))
        let agents = model.agents(under: lead)
        let one = try #require(agents.first { $0.agentID == "a1" })
        let two = try #require(agents.first { $0.agentID == "a2" })
        #expect(model.status(of: one).step == "echo one")
        #expect(model.status(of: two).step == "Read · two.txt")
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
