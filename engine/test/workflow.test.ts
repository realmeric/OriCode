// A workflow's snapshot as the CLI sends it in task_progress, shaped for the app.
import { test } from "node:test";
import assert from "node:assert/strict";
import { workflowShape } from "../workflow.ts";

test("phases and agents come in order, each agent in a state the app draws", () => {
  const shape = workflowShape([
    { type: "workflow_agent", index: 3, label: "verify:a", phaseIndex: 2, phaseTitle: "Verify", state: "start", queuedAt: 3 },
    { type: "workflow_phase", index: 2, title: "Verify", kind: "parallel" },
    { type: "workflow_log", message: "starting" },
    { type: "workflow_agent", index: 1, label: "review:a", phaseTitle: "Review", state: "done", tokens: 1200, toolCalls: 9 },
    { type: "workflow_phase", index: 1, title: "Review" },
    { type: "workflow_agent", index: 2, label: "review:b", phaseTitle: "Review", state: "progress", lastToolName: "Read", lastToolSummary: "App/Review/ReviewView.swift" },
    { type: "workflow_agent", index: 4, label: "verify:b", phaseTitle: "Verify", state: "start", startedAt: 5 },
    { type: "workflow_agent", index: 5, agentType: "workflow-subagent", state: "error", error: "Timed out" },
    "junk",
    null,
  ]);
  assert.deepEqual(shape.phases, ["Review", "Verify"]);
  assert.deepEqual(shape.agents.map((agent) => [agent.label, agent.phase, agent.state]), [
    ["review:a", "Review", "done"],
    ["review:b", "Review", "running"],
    ["verify:a", "Verify", "queued"],
    ["verify:b", "Verify", "running"],
    ["workflow-subagent", "", "failed"],
  ]);
  assert.equal(shape.agents[0].tokens, 1200);
  assert.equal(shape.agents[0].tools, 9);
  assert.equal(shape.agents[1].lastTool, "Read");
  assert.equal(shape.agents[1].lastDetail, "App/Review/ReviewView.swift");
  assert.equal(shape.agents[4].error, "Timed out");
});

test("an empty snapshot has no phases and no agents", () => {
  assert.deepEqual(workflowShape([]), { phases: [], agents: [] });
});
