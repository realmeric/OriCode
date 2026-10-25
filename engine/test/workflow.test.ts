// A workflow's snapshot as the CLI sends it in task_progress, shaped for the app.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Thread } from "../thread.ts";
import { stampEnds, workflowProgress, workflowShape } from "../workflow.ts";

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

test("a CLI that exits by itself stops the workflows and heads it had out", async () => {
  const thread = new Thread("t", "/nowhere/claude") as any;
  async function* cli() {
    yield { type: "system", subtype: "task_started", task_id: "w", tool_use_id: "call", description: "Review", task_type: "local_workflow", workflow_name: "review", session_id: "s", uuid: "u" };
  }
  thread.query = cli();
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    await thread.pump(thread.query);
  } finally {
    process.stdout.write = write;
  }
  const events = lines.map((line) => JSON.parse(line));
  assert.deepEqual(events.map((event) => [event.event, event.state ?? event.heads.length]), [
    ["workflow", "running"],
    ["heads", 1],
    ["workflow", "stopped"],
    ["heads", 0],
  ]);
  assert.equal(thread.workflows.size, 0);
  assert.equal(thread.heads.size, 0);
});

test("a run says how far it is by its agents and never a time, since its script starts agents as it goes", () => {
  const agent = (phase: string, state: string) => ({ type: "workflow_agent", phaseTitle: phase, state, startedAt: 1 });
  const ends: number[] = [];
  let shape = workflowShape([agent("Build", "progress"), agent("Build", "progress"), agent("Review", "start")]);
  stampEnds(shape, ends, 100);
  assert.equal(workflowProgress(shape, 0, ends, 100), "0/3");
  shape = workflowShape([agent("Build", "done"), agent("Build", "progress"), agent("Review", "start")]);
  stampEnds(shape, ends, 600);
  assert.equal(workflowProgress(shape, 0, ends, 600), "1/3");
  assert.equal(workflowProgress(workflowShape([]), 0, [], 0), null);
});

test("a turn a workflow's end wakes says nothing of it", async () => {
  const thread = new Thread("t", "/nowhere/claude") as any;
  thread.sessionId = "s";
  async function* cli() {
    yield { type: "system", subtype: "task_started", task_id: "w", tool_use_id: "call", description: "Review", task_type: "local_workflow", workflow_name: "review", session_id: "s", uuid: "u" };
    // A command one of its agents ran ends first.
    yield { type: "system", subtype: "task_started", task_id: "b", tool_use_id: "agent-call", description: "List tests", task_type: "local_bash", is_backgrounded: true, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_notification", task_id: "b", tool_use_id: "agent-call", status: "completed", output_file: "", summary: 'Background command "List tests" completed (exit code 0)', session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_notification", task_id: "w", status: "completed", output_file: "", summary: "", session_id: "s", uuid: "u" };
    yield { type: "assistant", parent_tool_use_id: null, message: { id: "m", content: [] }, session_id: "s", uuid: "u" };
  }
  thread.query = cli();
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    await thread.pump(thread.query);
  } finally {
    process.stdout.write = write;
  }
  const started = lines.map((line) => JSON.parse(line)).find((event) => event.event === "turn.started");
  assert.ok(started);
  assert.equal(started.woke, undefined);
});

test("a background command that wakes the thread names itself, though the CLI said it ended first", async () => {
  const thread = new Thread("t", "/nowhere/claude") as any;
  thread.sessionId = "s";
  async function* cli() {
    yield { type: "system", subtype: "task_started", task_id: "b", tool_use_id: "call", description: "Sleep", task_type: "local_bash", is_backgrounded: true, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_updated", task_id: "b", patch: { status: "completed" }, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_notification", task_id: "b", tool_use_id: "call", status: "completed", output_file: "", summary: 'Background command "Sleep 90" completed (exit code 0)', session_id: "s", uuid: "u" };
    yield { type: "assistant", parent_tool_use_id: null, message: { id: "m", content: [] }, session_id: "s", uuid: "u" };
  }
  thread.query = cli();
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    await thread.pump(thread.query);
  } finally {
    process.stdout.write = write;
  }
  const started = lines.map((line) => JSON.parse(line)).find((event) => event.event === "turn.started");
  assert.equal(started?.woke, "Sleep 90 done");
});
