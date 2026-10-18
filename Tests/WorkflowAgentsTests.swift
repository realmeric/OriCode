import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct WorkflowAgentsTests {
    private func model() throws -> (AppModel, lead: Chat) {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(alpha)
        let lead = Chat(project: alpha, title: "Lead")
        lead.started = true
        context.insert(lead)
        try context.save()
        let model = AppModel(container: container)
        model.selectedProjectID = alpha.id
        model.selectedChatID = lead.id
        return (model, lead)
    }

    private func workflow(_ state: String, folder: String? = "/c/s/subagents/workflows/wf_1", agents: [JSON]) -> JSON {
        var body: [String: JSON] = ["taskId": "w1", "state": .string(state), "agents": .array(agents)]
        if let folder { body["transcriptDir"] = .string(folder) }
        return .object(body)
    }

    private func agent(_ label: String, id: String?, state: String, result: String? = nil, error: String? = nil) -> JSON {
        var body: [String: JSON] = ["label": .string(label), "state": .string(state), "model": "claude-haiku-5-5"]
        if let id { body["agentId"] = .string(id) }
        if let result { body["result"] = .string(result) }
        if let error { body["error"] = .string(error) }
        return .object(body)
    }

    @Test func eachAgentThatStartsIsAThreadUnderItsWorkflowsThread() throws {
        let (model, lead) = try model()

        model.syncAgents(of: lead, workflow("running", folder: nil, agents: [
            agent("alpha", id: "a1", state: "running"),
            agent("beta", id: nil, state: "queued"),
        ]))
        #expect(model.drawerTree.first?.children?.map(\.chat.title) == ["alpha"])
        let alpha = try #require(model.agents(under: lead).first)
        #expect(alpha.agentID == "a1" && alpha.agentTask == "w1" && alpha.agentWorking)
        #expect(alpha.agentTranscript == nil && alpha.model == "claude-haiku-5-5" && alpha.cwd == lead.cwd)

        // The call's result names the folder; beta starts; a snapshot again makes nothing twice.
        model.syncAgents(of: lead, workflow("running", agents: [
            agent("alpha", id: "a1", state: "running"),
            agent("beta", id: "b2", state: "running"),
        ]))
        #expect(model.drawerTree.first?.children?.map(\.chat.title) == ["alpha", "beta"])
        #expect(alpha.agentTranscript == "/c/s/subagents/workflows/wf_1/agent-a1.jsonl")

        // Its end: each with what it returned, one line of it, and one left at work stopped.
        model.syncAgents(of: lead, workflow("stopped", agents: [
            agent("alpha", id: "a1", state: "done", result: "\n  alpha  \nmore"),
            agent("beta", id: "b2", state: "running"),
        ]))
        let beta = try #require(model.agents(under: lead).first { $0.agentID == "b2" })
        #expect(alpha.agentLine == "alpha")
        #expect(beta.agentLine == "Stopped" && !beta.agentWorking)
        model.syncAgents(of: lead, workflow("failed", agents: [agent("beta", id: "b2", state: "failed", error: "Timed out")]))
        #expect(beta.agentLine == "Failed: Timed out")
        #expect(model.agents(under: lead).count == 2)
    }

    @Test func aTranscriptPieceIsTakenOnlyWhereTheStoredCopyEnds() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        let alpha = try #require(model.agents(under: lead).first)
        let piece: JSON = ["from": 0, "offset": 120, "events": [["event": "user", "text": "Run it."], ["event": "text", "delta": "alpha"]]]

        model.transcribed(piece, into: alpha)
        model.transcribed(piece, into: alpha)
        #expect(alpha.agentRead == 120)
        #expect(model.conversation(for: alpha).items.count == 2)
        model.transcribed(["from": 120, "offset": 150, "events": []], into: alpha)
        #expect(alpha.agentRead == 150)
        // Read again after a relaunch, the copy is the store's.
        let read = Conversation(chat: alpha, context: model.context)
        #expect(read.items.count == 2)
    }

    @Test func agentsAtWorkWhenTheEngineWentWereStoppedWithIt() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        model.settleAgents()
        #expect(model.agents(under: lead).first?.agentState == "stopped")
    }

    /// The workflow's head on its thread, as the engine lists it while the run goes.
    private func head(_ running: Bool, on lead: Chat, in model: AppModel) {
        let heads: [JSON] = running ? [["id": "w1", "kind": "workflow", "toolUseId": "call", "label": "Echo"]] : []
        model.conversation(for: lead).receive(EngineEvent(name: "heads", threadId: lead.id.uuidString, body: ["event": "heads", "heads": .array(heads)]))
    }

    @Test func aThreadWhoseWorkflowRunsIsntArchivedAndGoesWithItsAgentsOnceItEnds() throws {
        let (model, lead) = try model()
        head(true, on: lead, in: model)
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        model.archive(lead)
        #expect(!lead.archived)
        // Its agent first, then the thread: neither while the run goes.
        let alpha = try #require(model.agents(under: lead).first)
        model.archive(alpha)
        #expect(!alpha.archived)
        model.archive(lead)
        #expect(!lead.archived)
        // Between agents, with none lit, the run still goes.
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "done", result: "alpha")]))
        model.archive(alpha)
        model.archive(lead)
        #expect(!alpha.archived && !lead.archived)
        model.syncAgents(of: lead, workflow("completed", agents: [agent("alpha", id: "a1", state: "done", result: "alpha")]))
        head(false, on: lead, in: model)
        model.archive(lead)
        #expect(lead.archived && model.agents(under: lead).allSatisfy(\.archived))
    }

    @Test func anAgentsRowStaysWhileItsWorkflowRuns() throws {
        let (model, lead) = try model()
        head(true, on: lead, in: model)
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        let alpha = try #require(model.agents(under: lead).first)
        model.askToDelete(alpha)
        #expect(model.deletingChat == nil)
        model.delete(alpha)
        #expect(model.agents(under: lead).count == 1)
        model.syncAgents(of: lead, workflow("completed", agents: [agent("alpha", id: "a1", state: "done", result: "alpha")]))
        head(false, on: lead, in: model)
        model.delete(alpha)
        #expect(model.agents(under: lead).isEmpty)
    }

    @Test func stopInAnAgentsThreadIsItsWorkflows() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        let alpha = try #require(model.agents(under: lead).first)
        #expect(!model.canStop)
        model.select(alpha)
        #expect(model.canStop)
        model.syncAgents(of: lead, workflow("completed", agents: [agent("alpha", id: "a1", state: "done", result: "alpha")]))
        #expect(!model.canStop)
    }

    @Test func aReadInPiecesIsShownAndSavedWithItsLast() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "running")]))
        let alpha = try #require(model.agents(under: lead).first)
        model.transcribed(["from": 0, "offset": 100, "more": true, "events": [["event": "user", "text": "Run it."]]], into: alpha)
        #expect(alpha.agentRead == 0 && model.conversation(for: alpha).items.isEmpty)
        model.transcribed(["from": 100, "offset": 160, "events": [["event": "text", "delta": "alpha"]]], into: alpha)
        #expect(alpha.agentRead == 160 && model.conversation(for: alpha).items.count == 2)
        // A read cut off between its pieces is dropped, and read again from the stored copy.
        model.transcribed(["from": 160, "offset": 200, "more": true, "events": [["event": "text", "delta": "lost"]]], into: alpha)
        model.heldPieces = [:]
        model.transcribed(["from": 200, "offset": 240, "events": [["event": "text", "delta": "lost"]]], into: alpha)
        #expect(alpha.agentRead == 160 && model.conversation(for: alpha).items.count == 2)
    }

    @Test func anAgentTakesNoMessageAndGoesWithItsWorkflowsThread() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("completed", agents: [agent("alpha", id: "a1", state: "done", result: "alpha")]))
        let alpha = try #require(model.agents(under: lead).first)

        #expect(!model.send("hello", images: [], in: alpha))
        #expect(throws: AppModel.Refused.self) { try model.message(alpha.id.uuidString, text: "hi", reason: "test", from: lead.id) }
        model.delete(lead)
        #expect(model.projects.flatMap(\.chats).isEmpty)
    }
}
