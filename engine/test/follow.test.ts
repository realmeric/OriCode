// A workflow agent's transcript, read from where Claude Code writes it, and a workflow's agents as
// the app hears of them: their ids, the folder their transcripts go to, and what each returned.
import { test } from "node:test";
import assert from "node:assert/strict";
import { appendFileSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Follow, lineEvents, unframed } from "../follow.ts";
import { Thread } from "../thread.ts";

const prompt = {
  type: "user",
  isSidechain: true,
  agentId: "a1",
  message: {
    role: "user",
    content:
      "[Workflow harness — computed task] The task text below was computed at runtime by a workflow script. The computed task text follows:\n  Run `echo alpha`.\n  Then reply with it.",
  },
};
const call = { type: "assistant", agentId: "a1", message: { content: [{ type: "thinking", thinking: "", signature: "x" }, { type: "tool_use", id: "c1", name: "Bash", input: { command: "echo alpha" } }] } };
const result = { type: "user", agentId: "a1", message: { content: [{ type: "tool_result", tool_use_id: "c1", content: "alpha", is_error: false }] } };
const edit = {
  type: "user",
  message: { content: [{ type: "tool_result", tool_use_id: "c2", content: "ok" }] },
  toolUseResult: { structuredPatch: [{ oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: ["-a", "+b"] }] },
};
const reply = { type: "assistant", agentId: "a1", message: { content: [{ type: "text", text: "alpha" }] } };
const context = { type: "attachment", attachment: { type: "credential_org", email: "someone@example.com" } };

test("an agent's lines become a thread's events, its task without the harness's frame", () => {
  assert.deepEqual(lineEvents(JSON.stringify(prompt)), [{ event: "user", text: "Run `echo alpha`.\nThen reply with it." }]);
  assert.deepEqual(lineEvents(JSON.stringify(call)), [{ event: "tool.use", toolUseId: "c1", name: "Bash", input: { command: "echo alpha" } }]);
  assert.deepEqual(lineEvents(JSON.stringify(result)), [{ event: "tool.result", toolUseId: "c1", content: "alpha", isError: false }]);
  assert.deepEqual(lineEvents(JSON.stringify(edit))[0].patch, [{ oldStart: 1, newStart: 1, lines: ["-a", "+b"] }]);
  assert.deepEqual(lineEvents(JSON.stringify(reply)), [{ event: "text", delta: "alpha" }]);
  assert.deepEqual(lineEvents(JSON.stringify(context)), []);
  assert.deepEqual(lineEvents("{not json"), []);
  const stopped = { type: "user", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } };
  assert.deepEqual(lineEvents(JSON.stringify(stopped)), [{ event: "note", text: "Stopped with its workflow." }]);
  assert.equal(unframed("A task of the user's own"), "A task of the user's own");
});

/// The engine's events while `body` runs, then until `settled` holds or a second has passed.
async function told(body: () => void | Promise<void>, settled: (events: any[]) => boolean): Promise<any[]> {
  const events: any[] = [];
  const write = process.stdout.write;
  // The test runner writes here too; only the engine's events are taken.
  process.stdout.write = ((chunk: unknown, ...rest: unknown[]) => {
    if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
      events.push(...chunk.split("\n").filter(Boolean).map((line) => JSON.parse(line)));
      return true;
    }
    return (write as (...args: unknown[]) => boolean).call(process.stdout, chunk, ...rest);
  }) as typeof process.stdout.write;
  try {
    await body();
    for (let waited = 0; waited < 1000 && !settled(events); waited += 10) await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    process.stdout.write = write;
  }
  return events;
}

test("a follow reads what's there past the app's copy, then each line as it's written, and only whole lines", async () => {
  const dir = join(mkdtempSync(join(tmpdir(), "follow-")), "subagents", "workflows", "wf_1");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "agent-a1.jsonl");
  const first = JSON.stringify(prompt) + "\n" + JSON.stringify(context) + "\n";
  writeFileSync(path, first + JSON.stringify(call) + "\n");
  const follow = new Follow("t", path, first.length - JSON.stringify(context).length - 1);
  const read = await told(() => follow.start(), (events) => events.length > 0);
  assert.equal(read.length, 1);
  assert.equal(read[0].event, "agent.lines");
  assert.equal(read[0].from, first.length - JSON.stringify(context).length - 1);
  assert.deepEqual(read[0].events.map((told: any) => told.event), ["tool.use"]);
  const end = read[0].offset;
  // Half a line, then the rest: nothing until it's whole.
  const line = JSON.stringify(reply) + "\n";
  const more = await told(
    async () => {
      appendFileSync(path, line.slice(0, 10));
      await new Promise((resolve) => setTimeout(resolve, 100));
      appendFileSync(path, line.slice(10));
    },
    (events) => events.length > 0,
  );
  follow.stop();
  assert.equal(more.length, 1);
  assert.equal(more[0].from, end);
  assert.equal(more[0].offset, end + Buffer.byteLength(line));
  assert.deepEqual(more[0].events, [{ event: "text", delta: "alpha" }]);
});

test("a long transcript comes in pieces, each but the last saying more follows", async () => {
  const dir = join(mkdtempSync(join(tmpdir(), "follow-")), "subagents", "workflows", "wf_3");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "agent-a3.jsonl");
  // 450 lines of one event each, and half a line the CLI is still writing.
  writeFileSync(path, (JSON.stringify(reply) + "\n").repeat(450) + JSON.stringify(reply).slice(0, 10));
  const follow = new Follow("t", path, 0);
  const read = await told(() => follow.start(), (events) => events.length === 3);
  follow.stop();
  assert.deepEqual(read.map((piece) => piece.events.length), [200, 200, 50]);
  assert.deepEqual(read.map((piece) => piece.more), [true, true, undefined]);
  assert.equal(read[1].from, read[0].offset);
  assert.equal(read[2].from, read[1].offset);
});

test("a follow of an agent not written yet waits for its file", async () => {
  const dir = join(mkdtempSync(join(tmpdir(), "follow-")), "subagents", "workflows", "wf_2");
  mkdirSync(dir, { recursive: true });
  const path = join(dir, "agent-a2.jsonl");
  const follow = new Follow("t", path, 0);
  const read = await told(
    async () => {
      follow.start();
      await new Promise((resolve) => setTimeout(resolve, 50));
      writeFileSync(path, JSON.stringify(prompt) + "\n");
    },
    (events) => events.length > 0,
  );
  follow.stop();
  assert.equal(read[0].events[0].event, "user");
});

test("a workflow tells its agents' ids, their transcripts' folder, and at its end what each returned", async () => {
  const root = mkdtempSync(join(tmpdir(), "workflow-"));
  const transcriptDir = join(root, "session", "subagents", "workflows", "wf_9");
  const outputFile = join(root, "w.output");
  const agent = (state: string, extra = {}) => ({ type: "workflow_agent", index: 1, label: "alpha", phaseTitle: "Toy", agentId: "a1", model: "claude-haiku-5-5", state, ...extra });
  writeFileSync(outputFile, JSON.stringify({ result: { a: "alpha" }, workflowProgress: [{ type: "workflow_phase", index: 1, title: "Toy" }, agent("done", { resultPreview: "alpha" })] }));
  const thread = new Thread("t", "/nowhere/claude") as any;
  async function* cli() {
    yield { type: "system", subtype: "task_started", task_id: "w", tool_use_id: "call", description: "Toy", task_type: "local_workflow", workflow_name: "toy", session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_progress", task_id: "w", tool_use_id: "call", description: "Toy: alpha", usage: { total_tokens: 0, tool_uses: 0, duration_ms: 1 }, workflow_progress: [agent("start", { startedAt: 1 })], session_id: "s", uuid: "u" };
    yield { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "call", content: "Workflow launched in background." }] }, parent_tool_use_id: null, tool_use_result: { taskId: "w", runId: "wf_9", transcriptDir }, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_updated", task_id: "w", patch: { status: "completed" }, session_id: "s", uuid: "u" };
    yield { type: "system", subtype: "task_notification", task_id: "w", tool_use_id: "call", status: "completed", output_file: outputFile, summary: "done", session_id: "s", uuid: "u" };
    await new Promise(() => {});
  }
  thread.query = cli();
  const events = await told(
    () => void thread.pump(thread.query),
    (events) => events.filter((event) => event.event === "workflow").length >= 5,
  );
  const workflows = events.filter((event) => event.event === "workflow");
  assert.deepEqual(workflows.map((event) => [event.state, event.transcriptDir, event.agents[0]?.agentId ?? null, event.agents[0]?.result ?? null]), [
    ["running", null, null, null],
    ["running", null, "a1", null],
    ["running", transcriptDir, "a1", null],
    ["completed", transcriptDir, "a1", null],
    ["completed", transcriptDir, "a1", "alpha"],
  ]);
  assert.equal(thread.workflows.size, 0);
});

test("a stopped workflow's last snapshot comes from the run's record beside the session", async () => {
  const root = mkdtempSync(join(tmpdir(), "workflow-"));
  const transcriptDir = join(root, "session", "subagents", "workflows", "wf_8");
  mkdirSync(join(root, "session", "workflows"), { recursive: true });
  const outputFile = join(root, "empty.output");
  writeFileSync(outputFile, "");
  writeFileSync(
    join(root, "session", "workflows", "wf_8.json"),
    JSON.stringify({ status: "killed", workflowProgress: [{ type: "workflow_agent", index: 1, label: "one", agentId: "a1", state: "progress", startedAt: 1 }] }),
  );
  const { finalShape } = await import("../workflow.ts");
  const shape = await finalShape(outputFile, transcriptDir);
  assert.deepEqual(shape?.agents.map((agent) => [agent.agentId, agent.state]), [["a1", "running"]]);
  assert.equal(await finalShape(null, null), undefined);
});
