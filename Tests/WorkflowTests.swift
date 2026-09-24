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
}
