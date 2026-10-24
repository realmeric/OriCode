// What the stage stands on, from a recorded run's folder: each agent's last calls as its card's
// trail, followed four at once, what each returned whole from the run's journal, and the run's
// last shape with its end.
import { test } from "node:test";
import assert from "node:assert/strict";
import { appendFileSync, cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { followSteps, stepsFollowed } from "../follow.ts";
import { Thread } from "../thread.ts";

const ids = ["a1", "a2", "a3", "a4"];
const last = {
  a1: ["Read", "Bash", "Read", "Grep"],
  a2: ["Read", "Grep", "Bash", "Read"],
  a3: ["Edit", "Bash", "Edit", "Bash"],
  a4: ["Bash", "Read", "Bash", "Grep"],
};
const tasks = {
  a1: "Review the diff in App/Stage.swift for logic errors.\nSay each finding with its file and line.",
  a2: "Review the engine's new agent.steps event against the wire protocol.\nSay each finding with its file and line.",
  a3: "Fix what the reviewers found.\nThe reviews follow.",
  a4: "Run make test and say what failed.",
};

/// A copy of the recorded run, which the tests write to as its agents would.
function run(): { root: string; folder: string; path: (id: string) => string } {
  const root = mkdtempSync(join(tmpdir(), "stage-"));
  cpSync(join(import.meta.dirname, "fixtures", "stage-run"), root, { recursive: true });
  const folder = join(root, "session", "subagents", "workflows", "wf_k324");
  return { root, folder, path: (id) => join(folder, `agent-${id}.jsonl`) };
}

/// The engine's events while `body` runs, then until `settled` holds or two seconds have passed.
async function told(body: () => void | Promise<void>, settled: (events: any[]) => boolean): Promise<any[]> {
  const events: any[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: unknown, ...rest: unknown[]) => {
    if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
      events.push(...chunk.split("\n").filter(Boolean).map((line) => JSON.parse(line)));
      return true;
    }
    return (write as (...args: unknown[]) => boolean).call(process.stdout, chunk, ...rest);
  }) as typeof process.stdout.write;
  try {
    await body();
    for (let waited = 0; waited < 2000 && !settled(events); waited += 10) await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    process.stdout.write = write;
  }
  return events;
}

const steps = (events: any[]) => events.filter((event) => event.event === "agent.steps");

/// A call and its result as the CLI appends them.
function step(path: string, id: string, tool: string, input: Record<string, unknown>): void {
  const call = { type: "assistant", agentId: id, message: { content: [{ type: "tool_use", id: `${id}-${tool}`, name: tool, input }] } };
  const result = { type: "user", agentId: id, message: { content: [{ type: "tool_result", tool_use_id: `${id}-${tool}`, content: "ok" }] } };
  appendFileSync(path, JSON.stringify(call) + "\n" + JSON.stringify(result) + "\n");
}

test("four agents followed at once each send their last four calls, the task once with the first", async () => {
  const { path } = run();
  const first = await told(
    () => ids.forEach((id) => followSteps(`t-${id}`, path(id), true)),
    (events) => steps(events).length >= 4,
  );
  assert.equal(stepsFollowed(), 4);
  for (const id of ids) {
    const told = steps(first).filter((event) => event.threadId === `t-${id}`);
    assert.equal(told.length, 1);
    assert.deepEqual(told[0].steps.map((step: any) => step.tool), last[id as keyof typeof last], id);
    assert.equal(told[0].task, tasks[id as keyof typeof tasks]);
  }
  // a1's last calls lie on both sides of a 70 KB result, read back across two pieces.
  assert.deepEqual(steps(first).find((event) => event.threadId === "t-a1").steps.at(-1).input, { pattern: "agent.steps", path: "/w/engine" });
  // A long word of a call's input is cut.
  assert.equal(steps(first).find((event) => event.threadId === "t-a3").steps[2].input.old_string.length, 200);

  // A call each, as they're written: the oldest step drops, and the task isn't sent again.
  const next = await told(
    () => ids.forEach((id) => step(path(id), id, "Glob", { pattern: `${id}/**` })),
    (events) => steps(events).length >= 4,
  );
  for (const id of ids) {
    const told = steps(next).filter((event) => event.threadId === `t-${id}`);
    assert.equal(told.length, 1);
    assert.deepEqual(told[0].steps.map((step: any) => step.tool), [...last[id as keyof typeof last].slice(1), "Glob"]);
    assert.equal(told[0].task, undefined);
  }

  // Told to stop, a follow reads nothing more.
  for (const id of ids) followSteps(`t-${id}`, "", false);
  assert.equal(stepsFollowed(), 0);
  const after = await told(() => step(path("a1"), "a1", "Read", { file_path: "/w/a" }), () => false);
  assert.equal(steps(after).length, 0);
});

test("a follow of an agent not written yet starts with its first line", async () => {
  const { folder } = run();
  const path = join(folder, "agent-a5.jsonl");
  const events = await told(
    async () => {
      followSteps("t-a5", path, true);
      await new Promise((resolve) => setTimeout(resolve, 50));
      writeFileSync(path, readFileSync(join(folder, "agent-a4.jsonl"), "utf8").split("\n")[0] + "\n");
    },
    (events) => steps(events).length >= 1,
  );
  followSteps("t-a5", "", false);
  assert.deepEqual(steps(events).map((event) => [event.steps.length, event.task]), [[0, tasks.a4]]);
});

test("each agent's end ends its trail and sends its whole result from the journal, and the run's end ends the rest", async () => {
  const { root, folder, path } = run();
  const journal = new Map(
    readFileSync(join(folder, "journal.jsonl"), "utf8")
      .split("\n")
      .filter(Boolean)
      .map((line) => JSON.parse(line))
      .filter((entry) => entry.type === "result")
      .map((entry) => [entry.agentId, typeof entry.result === "string" ? entry.result : JSON.stringify(entry.result)]),
  );
  assert.ok([...journal.values()].some((result) => result.length > 400));
  const record = JSON.parse(readFileSync(join(root, "session", "workflows", "wf_k324.json"), "utf8"));
  const snapshot = (done: string[]) => [
    ...record.workflowProgress.filter((entry: any) => entry.type === "workflow_phase"),
    ...record.workflowProgress
      .filter((entry: any) => entry.type === "workflow_agent")
      .map((agent: any) => (done.includes(agent.agentId) ? agent : { ...agent, state: "progress", resultPreview: undefined })),
  ];
  const empty = join(root, "empty.output");
  writeFileSync(empty, "");

  await told(
    () => ids.forEach((id) => followSteps(`t-${id}`, path(id), true)),
    (events) => steps(events).length >= 4,
  );
  const thread = new Thread("lead", "/nowhere/claude") as any;
  let next: (value: string) => void = () => {};
  async function* cli() {
    yield { type: "system", subtype: "task_started", task_id: "w", tool_use_id: "call", description: "Review", task_type: "local_workflow", workflow_name: "review-fix-test", session_id: "s", uuid: "u" };
    yield { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "call", content: "Workflow launched in background." }] }, parent_tool_use_id: null, tool_use_result: { taskId: "w", runId: "wf_k324", transcriptDir: folder }, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_progress", task_id: "w", tool_use_id: "call", description: "Review", usage: { total_tokens: 0, tool_uses: 0, duration_ms: 1 }, workflow_progress: snapshot(["a1", "a2"]), session_id: "s", uuid: "u" };
    await new Promise((resolve) => (next = resolve));
    // The same snapshot again sends nothing twice.
    yield { type: "system", subtype: "task_progress", task_id: "w", tool_use_id: "call", description: "Review", usage: { total_tokens: 0, tool_uses: 0, duration_ms: 1 }, workflow_progress: snapshot(["a1", "a2"]), session_id: "s", uuid: "u" };
    await new Promise((resolve) => (next = resolve));
    yield { type: "system", subtype: "task_notification", task_id: "w", tool_use_id: "call", status: "completed", output_file: empty, summary: "done", session_id: "s", uuid: "u" };
    await new Promise(() => {});
  }
  thread.query = cli();
  const reviewed = await told(
    () => void thread.pump(thread.query),
    (events) => events.filter((event) => event.event === "agent.result").length >= 2 && steps(events).filter((event) => event.ended).length >= 2,
  );
  assert.deepEqual(steps(reviewed).filter((event) => event.ended).map((event) => event.threadId).sort(), ["t-a1", "t-a2"]);
  assert.deepEqual(
    reviewed.filter((event) => event.event === "agent.result").map((event) => [event.threadId, event.taskId, event.agentId, event.result]).sort(),
    [["lead", "w", "a1", journal.get("a1")], ["lead", "w", "a2", journal.get("a2")]],
  );
  assert.equal(stepsFollowed(), 2);

  const again = await told(() => next(""), () => false);
  assert.equal(again.filter((event) => event.event === "agent.result").length, 0);

  const ended = await told(
    () => next(""),
    (events) => events.some((event) => event.event === "workflow" && event.state === "completed") && steps(events).filter((event) => event.ended).length >= 2,
  );
  assert.deepEqual(ended.filter((event) => event.event === "agent.result").map((event) => [event.agentId, event.result]).sort(), [["a3", journal.get("a3")], ["a4", journal.get("a4")]]);
  assert.deepEqual(steps(ended).filter((event) => event.ended).map((event) => event.threadId).sort(), ["t-a3", "t-a4"]);
  assert.equal(stepsFollowed(), 0);
  const shape = ended.find((event) => event.event === "workflow" && event.state === "completed");
  assert.equal(shape.endedAt, 1792836361000);
  assert.deepEqual(shape.agents.map((agent: any) => [agent.agentId, agent.phaseIndex, agent.queuedAt, agent.startedAt, agent.attempt, agent.promptFramed]), [
    ["a1", 1, 1792836000000, 1792836000010, 1, true],
    ["a2", 1, 1792836001000, 1792836001010, 1, true],
    ["a3", 2, 1792836002000, 1792836002010, 1, true],
    ["a4", 3, 1792836003000, 1792836003010, 1, true],
  ]);
  assert.equal(shape.agents[2].promptPreview, tasks.a3);
});
