// Letting idle CLIs go, on threads whose CLI is a stand-in, so nothing reaches Claude.
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { idleRelease, releaseIdle } from "../idle.ts";
import { Thread } from "../thread.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

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

/// A session whose agent keeps it less than the engine's 90 seconds, as OpenCode's is: idle since
/// `since`, or running.
function brief(limit: number, since: number | undefined, running = false) {
  const log = { closed: 0 };
  const session = {
    isRunning: running,
    idleRelease: limit,
    onIdle: undefined,
    releaseIfIdle: (idleMs: number, now: number) => {
      if (running || since === undefined || now - since < idleMs) return false;
      log.closed += 1;
      return true;
    },
    idleLeft: (idleMs: number, now: number) => (running || since === undefined ? undefined : Math.max(0, since + idleMs - now)),
  };
  return { session: session as never, log };
}

test("an agent that asks for less is let go at its own limit, and one running or not idle isn't", () => {
  const now = 1_000_000;
  const idle = brief(30_000, now - 30_000);
  const soon = brief(30_000, now - 10_000);
  const running = brief(30_000, undefined, true);
  const threads = new Map([
    ["idle", idle.session],
    ["soon", soon.session],
    ["running", running.session],
  ]);
  const { released, next } = releaseIdle(threads, { threadId: "idle", visible: true }, now);
  assert.deepEqual(released, ["idle"]);
  assert.equal(next, 20_000);
  assert.equal(soon.log.closed + running.log.closed, 0);
  assert.equal(idle.log.closed, 1);
});

const workflow = (id: string) => ({ ...started(id), description: "water-041", task_type: "local_workflow", tool_use_id: `call-${id}` });
const listed = (...tasks: { task_id: string; task_type: string }[]) => ({ type: "system", subtype: "background_tasks_changed", tasks: tasks.map((task) => ({ ...task, description: "" })), session_id: "s", uuid: "u" });

test("a CLI with a workflow out stays up when the CLI stops listing it", async () => {
  const { thread, cli, ended } = await finished("a");
  (thread as any).handle(workflow("w1"));
  (thread as any).handle(listed());
  const threads = new Map([["a", thread], ["b", new Thread("b", "claude", standIn().launch as never)]]);
  const select = releaseIdle(threads, { threadId: "b", visible: true }, ended + idleRelease);
  assert.deepEqual(select.released, []);
  const hide = releaseIdle(threads, { threadId: "b", visible: false }, ended + idleRelease);
  assert.deepEqual(hide.released, []);
  assert.equal(cli.closes, 0);
});

test("a workflow ended by an update lets its CLI go at its limit", async () => {
  const { thread, cli, ended } = await finished("a");
  (thread as any).handle(workflow("w1"));
  (thread as any).handle(listed());
  (thread as any).handle({ type: "system", subtype: "task_updated", task_id: "w1", patch: { status: "killed" }, session_id: "s", uuid: "u" });
  const { released } = releaseIdle(new Map([["a", thread]]), { threadId: "a", visible: true }, ended + idleRelease);
  assert.deepEqual(released, ["a"]);
  assert.equal(cli.closes, 1);
});

test("a background command keeps its CLI until the CLI says how it ended", async () => {
  const { thread, cli, ended } = await finished("a");
  (thread as any).handle({ ...started("c1"), task_type: "local_bash", tool_use_id: "call-c1" });
  (thread as any).handle(listed());
  const threads = new Map([["a", thread]]);
  assert.deepEqual(releaseIdle(threads, { threadId: "a", visible: true }, ended + idleRelease).released, []);
  (thread as any).handle({ type: "system", subtype: "task_notification", task_id: "c1", tool_use_id: "call-c1", status: "completed", session_id: "s", uuid: "u" });
  assert.deepEqual(releaseIdle(threads, { threadId: "a", visible: true }, ended + idleRelease).released, ["a"]);
  assert.equal(cli.closes, 1);
});

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const realWait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

test("the engine keeps a CLI with a workflow out through a select, a hide and the sweep, and lets it go when the workflow ends", async () => {
  const { bin, env } = await sandbox();
  const cwd = await mkdtemp(join(tmpdir(), "oricode-workflow-out-"));
  const pidFile = join(cwd, "claude.pid");
  const claude = await standInCli(bin, "claude-code", "claude-cli.ts", { CLAUDE_STAND_IN_PID: pidFile });
  const clock = new URL("./fixtures/fast-clock.ts", import.meta.url).pathname;
  const engine = engineWith({ ...env, ORICODE_CLAUDE: claude, NODE_OPTIONS: `--import ${clock}` });
  try {
    const released = (line: any) => line.event === "released" && line.threadId === "w";
    await engine.request("window", { threadId: "w", visible: true });
    void engine.request("send", { threadId: "w", cwd, text: "Run water-041 in the background", permissionMode: "default" });
    await engine.until((line) => line.event === "turn.done" && line.threadId === "w");
    await engine.until((line) => line.event === "heads" && line.threadId === "w" && line.heads.length === 0);
    const pid = Number(await readFile(pidFile, "utf8"));
    // A hundred times fast, a second is past the 90 s limit, and two more see the sweep twice.
    await realWait(1000);
    await engine.request("window", { threadId: "other", visible: true });
    await engine.request("window", { threadId: "other", visible: false });
    await realWait(2000);
    assert.equal(engine.lines.filter(released).length, 0);
    assert.ok(alive(pid));
    const from = engine.lines.length;
    process.kill(pid, "SIGUSR1");
    await engine.until((line) => line.event === "workflow" && line.threadId === "w" && line.state === "completed", from);
    await engine.until(released, from);
    for (let tries = 0; tries < 40 && alive(pid); tries += 1) await realWait(50);
    assert.ok(!alive(pid));
    await engine.end();
  } finally {
    engine.kill();
  }
});
