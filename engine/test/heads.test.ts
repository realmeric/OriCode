// A thread's heads through a Thread whose CLI is a stand-in, so nothing reaches Claude.
import { appendFileSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { outputFile, stepOf } from "../heads.ts";
import { Thread } from "../thread.ts";

test("a step is the tool and what it's on, a path from the thread's folder", () => {
  assert.deepEqual(stepOf("Read", { file_path: "/work/app/App/A.swift" }, "/work/app"), { tool: "Read", detail: "App/A.swift" });
  assert.deepEqual(stepOf("Read", { file_path: "/elsewhere/B.swift" }, "/work/app"), { tool: "Read", detail: "/elsewhere/B.swift" });
  assert.deepEqual(stepOf("Bash", { command: "\nmake test\nmake app", description: "Test" }, "/work"), { tool: "Bash", detail: "make test" });
  assert.deepEqual(stepOf("Grep", { pattern: "heads", path: "App" }, "/work"), { tool: "Grep", detail: "heads" });
  assert.deepEqual(stepOf("TodoWrite", { todos: [] }, "/work"), { tool: "TodoWrite", detail: null });
});

test("a command sent to the background says where its output goes", () => {
  assert.equal(
    outputFile("Command running in background with ID: b1. Output is being written to: /tmp/claude/tasks/b1.output."),
    "/tmp/claude/tasks/b1.output",
  );
  assert.equal(outputFile("done"), null);
});

/// The events the thread writes to stdout, kept here instead.
const events: Record<string, any>[] = [];
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) => {
  if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
    events.push(JSON.parse(chunk));
    return true;
  }
  return write(chunk, ...rest);
}) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// A CLI that yields the frames it's fed and remembers the tasks it was asked to stop.
function standIn() {
  const frames: unknown[] = [];
  let wake: (() => void) | undefined;
  const cli = {
    stopped: [] as string[],
    feed(message: unknown) {
      frames.push(message);
      wake?.();
    },
    launch: () => ({
      async *[Symbol.asyncIterator]() {
        while (true) {
          if (frames.length) yield frames.shift();
          else await new Promise<void>((resolve) => (wake = resolve));
        }
      },
      stopTask: async (id: string) => {
        cli.stopped.push(id);
      },
      initializationResult: () => Promise.reject(new Error("no CLI here")),
      close: () => {},
    }),
  };
  return cli;
}

const settle = () => new Promise((resolve) => setImmediate(resolve));
const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const folder = mkdtempSync(join(tmpdir(), "heads-"));
const system = (subtype: string, fields: Record<string, unknown>) => ({ type: "system", subtype, session_id: "s", uuid: "u", ...fields });
const started = (id: string, taskType: string, toolUseId: string, fields: Record<string, unknown> = {}) =>
  system("task_started", { task_id: id, task_type: taskType, tool_use_id: toolUseId, description: `${id}'s work`, ...fields });
const progress = (id: string, tokens: number, tools: number) =>
  system("task_progress", { task_id: id, description: "x", usage: { total_tokens: tokens, tool_uses: tools, duration_ms: 1 } });
const heads = () => events.filter((told) => told.event === "heads").map((told) => told.heads as Record<string, any>[]);

async function thread(cli: ReturnType<typeof standIn>) {
  const found = new Thread("t", "claude", cli.launch as never);
  await found.send({ threadId: "t", cwd: folder, text: "Go", permissionMode: "default" });
  await settle();
  events.length = 0;
  return found;
}

test("heads come and go at once, each kind as the CLI's task says, and nothing ambient", async () => {
  const cli = standIn();
  const found = await thread(cli);
  cli.feed(started("a1", "local_agent", "agent1", { subagent_type: "Explore", spawn_depth: 1 }));
  cli.feed(started("b1", "local_bash", "bash1", { is_backgrounded: true }));
  cli.feed(started("w1", "local_workflow", "wf1", { workflow_name: "review" }));
  cli.feed(started("m1", "monitor_mcp", "mon1"));
  cli.feed(started("x1", "local_agent", "quiet", { ambient: true }));
  await settle();
  const last = heads().at(-1)!;
  assert.deepEqual(last.map((head) => [head.id, head.kind]), [["a1", "agent"], ["b1", "command"], ["w1", "workflow"], ["m1", "command"]]);
  assert.equal(last[0].type, "Explore");
  assert.equal(last[0].toolUseId, "agent1");
  assert.equal(last[1].background, true);
  // Nobody is watching, so no detail.
  assert.equal("step" in last[0], false);
  events.length = 0;
  cli.feed(system("task_notification", { task_id: "a1", status: "completed", output_file: "", summary: "done" }));
  cli.feed(system("task_updated", { task_id: "b1", patch: { status: "killed" } }));
  await settle();
  assert.deepEqual(heads().map((list) => list.map((head) => head.id)), [["b1", "w1", "m1"], ["w1", "m1"]]);
  found.close();
});

test("a subagent's own tool call reaches its head while watched, and never the transcript", async () => {
  const cli = standIn();
  const found = await thread(cli);
  cli.feed(started("a1", "local_agent", "agent1"));
  await settle();
  found.watchHeads(true);
  assert.equal(heads().at(-1)![0].step, null);
  events.length = 0;
  cli.feed({
    type: "assistant",
    parent_tool_use_id: "agent1",
    session_id: "s",
    message: { id: "m", content: [{ type: "tool_use", id: "call1", name: "Read", input: { file_path: join(folder, "App/A.swift") } }] },
  });
  await settle();
  assert.deepEqual(events, []);
  await wait(300);
  assert.equal(events.length, 1);
  assert.deepEqual(heads()[0][0].step, { tool: "Read", detail: "App/A.swift" });
  found.close();
});

test("detail is coalesced into one send in 250ms, and the same list isn't sent twice", async () => {
  const cli = standIn();
  const found = await thread(cli);
  cli.feed(started("a1", "local_agent", "agent1"));
  await settle();
  found.watchHeads(true);
  events.length = 0;
  cli.feed(progress("a1", 100, 1));
  cli.feed(progress("a1", 200, 2));
  cli.feed(progress("a1", 300, 3));
  await wait(300);
  assert.equal(heads().length, 1);
  assert.equal(heads()[0][0].tokens, 300);
  assert.equal(heads()[0][0].tools, 3);
  cli.feed(progress("a1", 300, 3));
  await wait(300);
  assert.equal(heads().length, 1);
  found.close();
});

test("unwatched, detail sends nothing; watching sends it at once, and closing drops it", async () => {
  const cli = standIn();
  const found = await thread(cli);
  cli.feed(started("a1", "local_agent", "agent1"));
  await settle();
  events.length = 0;
  cli.feed(progress("a1", 500, 4));
  await wait(300);
  assert.deepEqual(events, []);
  found.watchHeads(true);
  assert.equal(heads().at(-1)![0].tokens, 500);
  found.watchHeads(false);
  assert.equal("tokens" in heads().at(-1)![0], false);
  events.length = 0;
  cli.feed(progress("a1", 900, 7));
  await wait(300);
  assert.deepEqual(events, []);
  found.close();
});

test("a command's last line comes from its output file, only while watched", async () => {
  const cli = standIn();
  const found = await thread(cli);
  const output = join(folder, "b1.output");
  writeFileSync(output, "starting\n");
  cli.feed(started("b1", "local_bash", "bash1", { is_backgrounded: true }));
  cli.feed({
    type: "user",
    parent_tool_use_id: null,
    session_id: "s",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "bash1", content: `Command running in background with ID: b1. Output is being written to: ${output}.` }] },
  });
  await settle();
  found.watchHeads(true);
  await wait(300);
  assert.equal(heads().at(-1)![0].line, "starting");
  appendFileSync(output, "\x1b[32mready\x1b[0m on :3000\n\n");
  await wait(500);
  assert.equal(heads().at(-1)![0].line, "ready on :3000");
  found.watchHeads(false);
  events.length = 0;
  appendFileSync(output, "GET /\n");
  await wait(400);
  assert.deepEqual(events, []);
  found.close();
});

test("a head stops from the app, and one already gone says so", async () => {
  const cli = standIn();
  const found = await thread(cli);
  cli.feed(started("a1", "local_agent", "agent1"));
  await settle();
  await found.stopTask("a1");
  assert.deepEqual(cli.stopped, ["a1"]);
  await assert.rejects(found.stopTask("gone"), /already stopped/);
  found.close();
});

test("a CLI that goes takes its heads with it", async () => {
  const cli = standIn();
  const found = (await thread(cli)) as any;
  cli.feed(started("a1", "local_agent", "agent1"));
  await settle();
  events.length = 0;
  found.query = (async function* () {})();
  await found.pump(found.query);
  assert.deepEqual(heads(), [[]]);
});
