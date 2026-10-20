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

    @Test func aRowsLineIsTheReplysFirstLineInWords() {
        #expect(AppModel.replyLine("\n- [App/OpenedThreads.swift:520](/Users/m/OriCode/App/OpenedThreads.swift:520): The wait notice is built from `resumeAt`.\nMore") == "App/OpenedThreads.swift:520: The wait notice is built from resumeAt.")
        #expect(AppModel.replyLine("**T1** is done, see e56ef2e") == "T1 is done, see e56ef2e")
        #expect(AppModel.replyLine("## Review") == "Review")
        #expect(AppModel.replyLine("2. Fixed it") == "Fixed it")
        #expect(AppModel.replyLine("2026. A year") == "2026. A year")
        #expect(AppModel.replyLine("3 files changed") == "3 files changed")
        #expect(AppModel.replyLine("Edited __init__.py and `snake_case`, 2*3*4 cases, *all* green") == "Edited __init__.py and snake_case, 2*3*4 cases, all green")
        #expect(AppModel.replyLine("-") == "-")
        #expect(AppModel.replyLine("  \n ") == nil)
        #expect(AppModel.replyLine(String(repeating: "a", count: 900))?.count == 200)
    }

    @Test func aFailedAgentsLineIsItsErrorAsItCame() throws {
        let (model, lead) = try model()
        let error = "No module named __init__ in /Users/m/x/__snapshots__/a.snap, 2*3*4 = 24"
        model.syncAgents(of: lead, workflow("failed", agents: [agent("alpha", id: "a1", state: "failed", error: "\n" + error)]))
        #expect(model.agents(under: lead).first?.agentResult == error)
        #expect(AppModel.oneLine("2026. A year\nmore") == "2026. A year")

        // A worker's error comes as its result, and is kept as it came too.
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "failed", result: error))
        #expect(model.agents(under: lead).first { $0.agentID == "k1" }?.agentResult == error)
    }

    @Test func aFinishedAgentsReplyIsReadOnceThoughEverySnapshotNamesIt() throws {
        let (model, lead) = try model()
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "done", result: "**Done**")]))
        let alpha = try #require(model.agents(under: lead).first)
        #expect(alpha.agentResult == "Done")
        alpha.agentResult = "kept"
        model.syncAgents(of: lead, workflow("running", agents: [agent("alpha", id: "a1", state: "done", result: "**Done**")]))
        #expect(alpha.agentResult == "kept")
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

    private func told(_ id: String, kind: String, state: String, result: String? = nil) -> JSON {
        var body: [String: JSON] = ["agentId": .string(id), "kind": .string(kind), "label": "look around", "state": .string(state)]
        if kind == "subagent" { body["transcript"] = .string("/c/s/subagents/agent-\(id).jsonl") }
        if kind == "worker" { body["task"] = "worker-1"; body["agent"] = "codex"; body["model"] = "gpt-small" }
        if let result { body["result"] = .string(result) }
        return .object(body)
    }

    @Test func aSubagentIsAThreadUnderItsThreadWithAStopOfItsOwn() throws {
        let (model, lead) = try model()
        model.syncAgent(of: lead, told("a7", kind: "subagent", state: "running"))
        let agent = try #require(model.agents(under: lead).first)
        #expect(model.drawerTree.first?.children?.map(\.chat.title) == ["look around"])
        #expect(agent.agentKind == "subagent" && agent.agentTask == "a7" && agent.agentWorking)
        #expect(agent.agentTranscript == "/c/s/subagents/agent-a7.jsonl" && agent.provider == lead.provider)
        #expect(agent.agentStop == "Stop" && agent.agentStopFirst == "the agent")
        model.select(agent)
        #expect(model.canStop)
        // Told again as it ends: the same thread, with the first line of what it returned.
        model.syncAgent(of: lead, told("a7", kind: "subagent", state: "done", result: "the note says hello\nmore"))
        #expect(model.agents(under: lead).count == 1)
        #expect(agent.agentLine == "the note says hello" && !model.canStop)
        #expect(!model.send("hello", images: [], in: agent))
        #expect(throws: AppModel.Refused.self) { try model.message(agent.id.uuidString, text: "hi", reason: "test", from: lead.id) }
        // stop_thread on one that has ended has nothing to stop.
        #expect(throws: AppModel.Refused.self) { try model.stop(agent.id.uuidString, reason: "test", from: lead.id) }
    }

    @Test func aSubagentAtWorkKeepsItsRowAndItsThread() throws {
        let (model, lead) = try model()
        model.syncAgent(of: lead, told("a7", kind: "subagent", state: "running"))
        let agent = try #require(model.agents(under: lead).first)
        model.archive(agent)
        model.archive(lead)
        model.delete(agent)
        #expect(!agent.archived && !lead.archived && model.agents(under: lead).count == 1)
        model.syncAgent(of: lead, told("a7", kind: "subagent", state: "stopped"))
        #expect(agent.agentLine == "Stopped")
        model.archive(lead)
        #expect(lead.archived && agent.archived)
    }

    @Test func aWorkersEventsAreItsThreadsOwn() throws {
        let (model, lead) = try model()
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "running"))
        let worker = try #require(model.agents(under: lead).first)
        #expect(worker.agentKind == "worker" && worker.agentTask == "worker-1" && worker.provider == "codex" && worker.model == "gpt-small")
        let said = { (event: JSON) in model.workerSaid(["agentId": "k1", "said": event]) }
        said(["event": "user", "text": "write greet.test.ts"])
        said(["event": "turn.started"])
        said(["event": "tool.use", "toolUseId": "c1", "name": "Write", "input": ["file_path": "greet.test.ts"]])
        said(["event": "tool.result", "toolUseId": "c1", "content": "ok", "isError": false])
        said(["event": "text", "delta": "Wrote greet.test.ts."])
        let conversation = model.conversation(for: worker)
        #expect(conversation.running)
        said(["event": "turn.done", "stopReason": "end_turn"])
        #expect(!conversation.running)
        // An id this engine never told of is nobody's.
        model.workerSaid(["agentId": "k9", "said": ["event": "user", "text": "lost"]])
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "done", result: "Wrote greet.test.ts."))
        #expect(worker.agentLine == "Wrote greet.test.ts." && worker.title == "look around" && worker.sessionId == nil)
        // A relaunch reads it from the store, as a thread's own transcript.
        let read = Conversation(chat: worker, context: model.context)
        #expect(read.items.count == 4)
        if case .user(_, let text, _, _) = read.items.first { #expect(text == "write greet.test.ts") } else { Issue.record("no message first") }
        #expect(throws: AppModel.Refused.self) { try model.message(worker.id.uuidString, text: "hi", reason: "test", from: lead.id) }
    }

    @Test func aWorkerMessagedAgainKeepsWhatItsHeadSentAndEndsItsTurnHoweverItEnds() throws {
        let (model, lead) = try model()
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "done", result: "Wrote greet.test.ts."))
        let worker = try #require(model.agents(under: lead).first)
        let conversation = model.conversation(for: worker)
        let said = { (event: JSON) in model.workerSaid(["agentId": "k1", "said": event]) }
        // Messaged again: a turn of its own, then a message steered into it, which starts none.
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "running"))
        said(["event": "user", "text": "slow"])
        said(["event": "user", "text": "go on", "midTurn": true])
        #expect(conversation.running)
        if case .user(_, "go on", _, true) = conversation.items.last {} else { Issue.record("not a message taken up mid-turn") }
        said(["event": "turn.done", "stopReason": "end_turn"])
        // A turn that said nothing leaves no earlier reply as its result.
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "done", result: ""))
        #expect(worker.agentLine == "Done")
        // One whose turn never came to its turn.done, its head's thread gone, ends with its state.
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "running"))
        said(["event": "user", "text": "again"])
        #expect(conversation.running)
        model.syncAgent(of: lead, told("k1", kind: "worker", state: "stopped"))
        #expect(!conversation.running && !worker.agentWorking)
    }
}
