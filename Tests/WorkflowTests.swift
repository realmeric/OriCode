import SwiftData
import Testing
@testable import OriCode

struct WorkflowTests {
    private let script = """
        export const meta = {
          name: 'review-changes',
          description: "Review the diff, then verify each finding",
          phases: [{ title: 'Review' }, { title: "Verify", detail: 'one [agent] per finding' }, { title: `Report` }],
        }
        await phase('Review')
        """

    @Test func aScriptNamesItsPhasesAndItself() {
        #expect(WorkflowRun.plannedPhases(in: script) == ["Review", "Verify", "Report"])
        #expect(WorkflowRun.plannedName(in: script) == "review-changes")
        #expect(WorkflowRun.plannedPhases(in: "await agent('go')").isEmpty)
    }

    @Test func theEnginesSnapshotBecomesTheRun() {
        let run = WorkflowRun([
            "state": "running", "name": "review-changes", "phases": ["Review", "Fix"], "summary": .null,
            "agents": [
                ["label": "review:a", "phase": "Review", "state": "done", "tokens": 1200, "tools": 9],
                ["label": "review:b", "phase": "Review", "state": "running", "lastTool": "Read", "lastDetail": "App/A.swift"],
                ["label": "stray", "phase": "", "state": "failed", "error": "Timed out"],
                ["label": "fix:a", "phase": "Fix", "state": "queued"],
            ],
        ])
        #expect(run.state == .running)
        #expect(run.count(.done) == 1 && run.count(.running) == 1 && run.count(.failed) == 1 && run.count(.queued) == 1)
        #expect(run.agents[0].tokens == 1200 && run.agents[0].tools == 9)
        #expect(run.agents[1].lastTool == "Read" && run.agents[1].lastDetail == "App/A.swift")
        #expect(run.agents[2].error == "Timed out")

        // The script's phases first, one the CLI reported that the script didn't name after them,
        // and agents in no phase last.
        let groups = WorkflowRun.groups(run.agents, planned: ["Review", "Verify"], reported: run.phases)
        #expect(groups.map(\.phase) == ["Review", "Verify", "Fix", ""])
        #expect(groups.map(\.agents.count) == [2, 0, 1, 1])
    }

    @MainActor
    @Test func restartingTheEngineStopsTheWorkflowsItRan() async throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
        let conversation = model.conversation(for: chat)
        let thread = chat.id.uuidString
        conversation.receive(EngineEvent(name: "tool.use", threadId: thread, body: [
            "event": "tool.use", "toolUseId": "call", "name": "Workflow", "input": .object([:]),
        ]))
        conversation.receive(EngineEvent(name: "workflow", threadId: thread, body: [
            "event": "workflow", "taskId": "w", "toolUseId": "call", "name": "review-changes", "state": "running",
            "phases": ["Review"], "agents": [], "summary": .null,
        ]))
        conversation.receive(EngineEvent(name: "heads", threadId: thread, body: [
            "event": "heads", "heads": [["id": "w", "kind": "workflow", "toolUseId": "call", "label": "Review"]],
        ]))
        #expect(!conversation.heads.isEmpty)

        // Restart's first half; the second starts a real engine.
        await model.stopEngine()
        #expect(conversation.heads.isEmpty)
        guard case .tool(_, let call) = conversation.items.last else {
            Issue.record("no call")
            return
        }
        #expect(call.workflow?.state == .stopped)
    }
}
