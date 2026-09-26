// Letting idle CLIs go, on threads whose CLI is a stand-in, so nothing reaches Claude.
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { idleRelease, releaseIdle } from "../idle.ts";
import { Thread } from "../thread.ts";

const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) =>
  typeof chunk === "string" && chunk.startsWith('{"event"') ? true : write(chunk, ...rest)) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// A CLI that never says anything and counts its closes.
function standIn() {
  const cli = {
    closes: 0,
    launch: () => ({
      [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }),
      initializationResult: () => Promise.reject(new Error("no CLI here")),
      setPermissionMode: async () => {},
      applyFlagSettings: async () => {},
      close: () => (cli.closes += 1),
    }),
  };
  return cli;
}

const result = {
  type: "result",
  subtype: "success",
  session_id: "s",
  uuid: "u",
  num_turns: 1,
  duration_ms: 10,
  total_cost_usd: 0,
  usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  modelUsage: {},
};

/// A thread whose turn has just ended, with its CLI still up.
async function finished(id: string, cli = standIn()) {
  const thread = new Thread(id, "claude", cli.launch as never);
  let idle = 0;
  thread.onIdle = () => (idle += 1);
  await thread.send({ threadId: id, cwd: tmpdir(), text: "Hi", permissionMode: "default" });
  (thread as any).handle(result);
  assert.equal(idle, 1);
  return { thread, cli, ended: Date.now() };
}

test("an idle CLI goes after 90 seconds, and not before", async () => {
  const { thread, cli, ended } = await finished("a");
  const threads = new Map([["a", thread]]);
  const early = releaseIdle(threads, { threadId: "a", visible: true }, ended + idleRelease - 1000);
  assert.deepEqual(early.released, []);
  assert.ok(early.next! <= 1000 && early.next! > 0);
  assert.equal(cli.closes, 0);
  const due = releaseIdle(threads, { threadId: "a", visible: true }, ended + idleRelease);
  assert.deepEqual(due.released, ["a"]);
  assert.equal(due.next, undefined);
  assert.equal(cli.closes, 1);
});

test("while the window can't be seen, a thread that isn't open goes at once and the open one waits", async () => {
  const open = await finished("open");
  const other = await finished("other");
  const threads = new Map([
    ["open", open.thread],
    ["other", other.thread],
  ]);
  const { released, next } = releaseIdle(threads, { threadId: "open", visible: false }, other.ended);
  assert.deepEqual(released, ["other"]);
  assert.ok(next! > 0 && next! <= idleRelease);
  assert.equal(open.cli.closes, 0);
});

const started = (id: string) => ({ type: "system", subtype: "task_started", task_id: id, description: "Explore", task_type: "local_agent", is_backgrounded: true, session_id: "s", uuid: "u" });

test("a CLI with agents still out stays, and is looked at again later", async () => {
  const { thread, cli, ended } = await finished("a");
  (thread as any).handle(started("t1"));
  const { released, next } = releaseIdle(new Map([["a", thread]]), { threadId: null, visible: false }, ended + idleRelease);
  assert.deepEqual(released, []);
  assert.equal(next, idleRelease);
  assert.equal(cli.closes, 0);
});

test("a CLI let go leaves no heads, watcher or timer behind", async () => {
  const { thread, cli, ended } = await finished("a");
  thread.watchHeads(true);
  const heads = (thread as any).heads;
  (thread as any).handle(started("t1"));
  const head = heads.live.get("t1");
  const output = join(await mkdtemp(join(tmpdir(), "oricode-idle-")), "t1.output");
  await writeFile(output, "working\n");
  head.output = output;
  heads.tail(head);
  assert.ok(head.tail && heads.timer);
  // Its agent ends, and before the heads' next send the CLI is let go.
  (thread as any).handle({ type: "system", subtype: "task_notification", task_id: "t1", status: "completed", session_id: "s", uuid: "u" });
  const { released } = releaseIdle(new Map([["a", thread]]), { threadId: "a", visible: true }, ended + idleRelease);
  assert.deepEqual(released, ["a"]);
  assert.equal(cli.closes, 1);
  assert.equal(heads.size, 0);
  assert.equal(heads.timer, undefined);
  assert.equal(head.tail, null);
});

test("a turn running, or no CLI at all, needs no look until the turn ends", async () => {
  const running = new Thread("r", "claude", standIn().launch as never);
  await running.send({ threadId: "r", cwd: tmpdir(), text: "Hi", permissionMode: "default" });
  const none = new Thread("n", "claude", standIn().launch as never);
  const { released, next } = releaseIdle(new Map([["r", running], ["n", none]]), { threadId: null, visible: false });
  assert.deepEqual(released, []);
  assert.equal(next, undefined);
});
