import Foundation
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

    @Test func aFinishedRunKeepsItsEndAndEachAgentsTimes() {
        let run = WorkflowRun([
            "state": "completed", "name": "review", "phases": ["Review"], "endedAt": 1_792_836_361_000,
            "agents": [[
                "label": "review:a", "phase": "Review", "state": "done", "phaseIndex": 1, "queuedAt": 1_792_836_000_000,
                "startedAt": 1_792_836_000_010, "attempt": 2, "promptPreview": "Review the diff", "promptFramed": true,
            ]],
        ])
        #expect(run.endedAt == Date(timeIntervalSince1970: 1_792_836_361))
        let agent = run.agents[0]
        #expect(agent.phaseIndex == 1 && agent.attempt == 2 && agent.promptPreview == "Review the diff" && agent.promptFramed)
        #expect(agent.startedAt == Date(timeIntervalSince1970: 1_792_836_000.01))
        #expect(WorkflowRun(["state": "running", "agents": [["label": "a"]]]).endedAt == nil)
    }

    @MainActor
    @Test func aTrailKeepsItsAgentsLastStepsAndTaskApartFromTheResults() {
        let stage = StageModel()
        let agent = UUID()
        stage.followed = [agent]
        stage.take(["steps": [["tool": "Read", "input": ["file_path": "/w/a"]]], "task": "Review it"], for: agent)
        stage.take(["steps": [["tool": "Read", "input": ["file_path": "/w/a"]], ["tool": "Bash", "input": ["command": "make"]]]], for: agent)
        let trail = stage.trail(for: agent)
        #expect(trail.steps.map(\.tool) == ["Read", "Bash"] && trail.task == "Review it")
        stage.take(["steps": [], "ended": true], for: agent)
        #expect(stage.followed.isEmpty)
        stage.took(["agentId": "a1", "result": "whole"])
        #expect(stage.results["a1"] == "whole")
    }

    @MainActor
    @Test func aStageStepsIntoAnAgentAcrossAndBackOut() {
        let stage = StageModel()
        let lead = UUID(), fix = UUID(), verify = UUID()
        var left: [UUID?] = []
        stage.steppedMoved = { left.append($0) }
        stage.cue("run", in: lead, grow: true)
        stage.step(into: .init(agent: "a3", thread: fix), in: lead)
        stage.step(into: .init(agent: "a3", thread: fix), in: lead)
        stage.step(into: .init(agent: "a4", thread: verify), in: lead)
        #expect(stage.stepped[lead]?.thread == verify && left == [nil, fix])
        stage.step(into: nil, in: lead)
        #expect(stage.stepped[lead] == nil && stage.shown[lead] == "run" && left == [nil, fix, verify])
        // Folding a stage stepped into an agent steps out of it too.
        stage.step(into: .init(agent: "a3", thread: fix), in: lead)
        #expect(stage.fold(lead) && stage.stepped[lead] == nil && left.last == fix)
    }

    @MainActor
    @Test func aStepKeepsItsPlaceAsNewerOnesPushItDown() {
        let stage = StageModel()
        let agent = UUID()
        func steps(_ names: [String]) -> JSON {
            ["steps": .array(names.map { ["tool": "Read", "input": ["file_path": .string($0)]] })]
        }
        stage.take(steps(["a", "b"]), for: agent)
        #expect(stage.trail(for: agent).first == 0)
        stage.take(steps(["a", "b", "c", "d"]), for: agent)
        #expect(stage.trail(for: agent).first == 0)
        // The oldest dropped as a fifth came: d is still the fourth call.
        stage.take(steps(["b", "c", "d", "e"]), for: agent)
        #expect(stage.trail(for: agent).first == 1)
        stage.take(steps(["d", "e", "f", "g"]), for: agent)
        #expect(stage.trail(for: agent).first == 3)
    }

    @MainActor
    @Test func eachWorkflowAgentKeepsItsOwnRay() {
        let heads = Heads()
        heads.update(["heads": [["id": "w", "kind": "workflow", "toolUseId": "call"]]], agent: "claude")
        func run(_ states: [(String, String)]) {
            heads.workflow(["taskId": "w", "state": "running", "agents": .array(states.map { ["agentId": .string($0.0), "label": .string($0.0), "phase": "P", "state": .string($0.1)] })])
        }
        run([("a1", "running"), ("a2", "running"), ("a3", "queued")])
        let head = heads.liveWorkflow!
        #expect(head.agentRays == ["a1": 0, "a2": 1])
        run([("a1", "done"), ("a2", "running"), ("a3", "running")])
        #expect(head.agentRays == ["a2": 1, "a3": 0])
        #expect(Set(head.rays) == [0, 1] && heads.lit == [0, 1])
    }

    @Test func aLivePhaseTakesWhatTheOthersLeave() {
        func agent(_ state: String) -> WorkflowRun.Agent {
            WorkflowRun(["agents": [["label": "a", "phase": "P", "state": .string(state)]]]).agents[0]
        }
        // 03 at 1180pt: Review's two at work share what Fix's and Verify's labels leave, 400pt a card at most.
        let wide = StageLayout(groups: [("Review", [agent("running"), agent("running")]), ("Fix", []), ("Verify", [])], width: 1116, narrow: false)
        #expect(wide.phases.map(\.state) == [.live, .ahead, .ahead])
        #expect(wide.phases[0].width == 810 && wide.phases[0].sideBySide)
        #expect(wide.phases[1].width < 40 && wide.phases[2].width < 60)
        // 12 at 720pt: still side by side, each over 240pt.
        let narrow = StageLayout(groups: [("Review", [agent("running"), agent("running")]), ("Fix", []), ("Verify", [])], width: 680, narrow: false)
        #expect(narrow.phases[0].sideBySide && narrow.phases[0].width > 500)
        // A finished phase is 250pt; three at work in what's left stack, no wider than one card.
        let later = StageLayout(groups: [("Review", [agent("done")]), ("Fix", [agent("running"), agent("running"), agent("running")])], width: 680, narrow: false)
        #expect(later.phases[0].width == 250 && later.phases[1].width == 396 && !later.phases[1].sideBySide)
        // Beside another thread, three phases that wouldn't fit go narrow: the finished ones to their
        // head rows and the live one to what's left.
        let beside = StageLayout.fitted(groups: [("Review", [agent("done"), agent("done")]), ("Fix", [agent("done")]), ("Verify", [agent("running")])],
                                        width: 550, narrow: false, wide: [], wells: [:])
        #expect(beside.phases.map(\.collapsed) == [true, true, false] && beside.widths.reduce(0, +) <= 550)
        // Past the cap, cards drop calls before anything scrolls.
        let full = wide.height(steps: 4)
        #expect(wide.steps(within: full) == 4 && wide.steps(within: full - 1) == 3 && wide.steps(within: 0) == 0)
    }

    @MainActor
    @Test func restartingTheEngineStopsTheWorkflowsItRan() async throws {
        let container = try TestStore.memory()
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
        #expect(call.workflow?.endedAt != nil)
    }
}
