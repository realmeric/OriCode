// An ACP thread against a stand-in agent that scripts its replies, so nothing reaches a model.
import { mkdtemp, readFile, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { AcpSession, answer, listModels, modes, type AcpAgent } from "../acp.ts";
import { hunks, stopReason, toolKind, toolView } from "../acp-map.ts";

/// The events sessions write to stdout, kept here instead, and whoever waits on the next one.
const events: Record<string, any>[] = [];
const waiters: (() => void)[] = [];
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) => {
  if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
    events.push(JSON.parse(chunk));
    for (const wake of waiters.splice(0)) wake();
    return true;
  }
  return write(chunk, ...rest);
}) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// The first event from `from` on that `matches`, waiting for it if it hasn't come.
async function until(matches: (event: Record<string, any>) => boolean, from = 0): Promise<Record<string, any>> {
  const deadline = Date.now() + 5000;
  while (true) {
    const found = events.slice(from).find(matches);
    if (found) return found;
    if (Date.now() > deadline) throw new Error(`no such event among ${JSON.stringify(events.slice(from).map((event) => event.event))}`);
    await new Promise<void>((resolve) => {
      waiters.push(resolve);
      setTimeout(resolve, 100);
    });
  }
}

const named = (name: string, threadId: string) => (event: Record<string, any>) => event.event === name && event.threadId === threadId;

async function folder(): Promise<string> {
  return realpath(await mkdtemp(join(tmpdir(), "oricode-acp-")));
}

/// A session on the stand-in, and the file it logs what it's sent to.
async function standIn(threadId: string, env: Record<string, string> = {}) {
  const cwd = await folder();
  const logFile = join(cwd, "agent.log");
  const agent: AcpAgent = {
    name: "Stand-in",
    command: process.execPath,
    args: [new URL("./fixtures/acp-agent.ts", import.meta.url).pathname],
    env: { ACP_LOG: logFile, ACP_EXTRA: "passed", ...env },
  };
  const session = new AcpSession(threadId, agent);
  const sent = async () => (await readFile(logFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  return { session, cwd, sent };
}

const sessions: AcpSession[] = [];
after(() => sessions.forEach((session) => session.close()));

test("the handshake: initialize with nothing offered, a new session in the folder, a scrubbed environment", async () => {
  process.env.CLAUDE_CODE_MESSAGING_TOKEN = "not for other agents";
  const { session, cwd, sent } = await standIn("hand");
  sessions.push(session);
  delete process.env.CLAUDE_CODE_MESSAGING_TOKEN;
  const from = events.length;
  assert.equal(await session.send({ threadId: "hand", cwd, text: "hello", id: "m1" }), false);
  const done = await until(named("turn.done", "hand"), from);
  const told = events.slice(from).filter((event) => event.threadId === "hand");
  assert.deepEqual(
    told.map((event) => event.event),
    ["message.taken", "turn.started", "text", "turn.done"],
  );
  assert.deepEqual(told[0], { event: "message.taken", threadId: "hand", messageId: "m1", newTurn: true });
  assert.equal(told[1].sessionId, "s-1");
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "s-1");
  const log = await sent();
  assert.deepEqual(log[0], { env: [], extra: "passed", cwd });
  const initialize = log.find((message) => message.method === "initialize");
  assert.equal(initialize.params.protocolVersion, 1);
  assert.deepEqual(initialize.params.clientCapabilities, { fs: { readTextFile: false, writeTextFile: false }, terminal: false });
  assert.deepEqual(log.find((message) => message.method === "session/new").params, { cwd, mcpServers: [] });
  // No sign-in was named, so none was run.
  assert.equal(log.some((message) => message.method === "authenticate"), false);
  // The agent lists its commands once the session is open, in its own time.
  while (!(await session.commands())) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.deepEqual(await session.commands(), [{ name: "review", description: "Review the changes", argumentHint: "branch" }]);
  assert.deepEqual(listModels(session), {
    current: "small",
    models: [
      { id: "small", name: "Small", description: null },
      { id: "large", name: "Large", description: null },
    ],
  });
  assert.equal(modes(session).current, "agent");
  assert.deepEqual(modes(session).modes.map((mode) => mode.id), ["agent", "plan"]);
  assert.equal(await session.setFast(true), false);
  assert.equal(await session.setMode("plan"), true);
  assert.equal(modes(session).current, "plan");
  assert.equal(await session.setMode("bypassPermissions"), false);
});

test("a turn: thinking, text, a read, an edit with its diff after an ask, a plan and the usage", async () => {
  const { session, cwd, sent } = await standIn("work");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "work", cwd, text: "work", model: "large" });
  const ask = await until(named("ask", "work"), from);
  assert.equal(ask.kind, "permission");
  assert.equal(ask.toolUseId, "edit-1");
  assert.deepEqual(ask.view, { path: "/w/a.txt" });
  assert.deepEqual(ask.choices, [
    { id: "once", name: "Allow once", kind: "allow_once" },
    { id: "always", name: "Always allow", kind: "allow_always" },
    { id: "reject", name: "Reject", kind: "reject_once" },
  ]);
  assert.equal(answer({ requestId: ask.requestId, allow: true }), true);
  assert.equal(answer({ requestId: ask.requestId, allow: true }), false);
  const done = await until(named("turn.done", "work"), from);
  const told = events.slice(from).filter((event) => event.threadId === "work");
  assert.deepEqual(
    told.map((event) => event.event),
    ["turn.started", "thinking", "text", "tool.use", "tool.result", "tool.use", "ask", "tool.result", "tool.use", "tool.result", "text", "turn.done"],
  );
  const [read, readResult, edit, editResult, plan] = told.filter((event) => event.event.startsWith("tool."));
  // The read is told once its input has come, under the id Cursor gave it, newline and all.
  assert.equal(read.toolUseId, "call-1-0\nfc_1_0");
  assert.equal(read.kind, "read");
  assert.deepEqual(read.input, { path: "/w/a.txt" });
  assert.deepEqual(read.view, { path: "/w/a.txt" });
  assert.deepEqual(readResult, { event: "tool.result", threadId: "work", toolUseId: read.toolUseId, content: "one\ntwo\n", isError: false });
  assert.equal(edit.kind, "edit");
  assert.deepEqual(editResult.patch, [{ oldStart: 1, newStart: 1, lines: [" one", "-two", "+2", " three"] }]);
  assert.equal(plan.name, "TodoWrite");
  assert.equal(plan.kind, "plan");
  assert.deepEqual(plan.view.todos, [
    { content: "Read a.txt", activeForm: "Read a.txt", status: "completed" },
    { content: "Edit a.txt", activeForm: "Edit a.txt", status: "in_progress" },
    { content: "Check it", activeForm: "Check it", status: "pending" },
  ]);
  assert.deepEqual(plan.input, { todos: plan.view.todos });
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.costUSD, 0.25);
  assert.deepEqual(done.context, { used: 1200, window: 200000 });
  assert.deepEqual(done.usage, { input: 10, output: 5, cacheRead: 1185, cacheWrite: 0 });
  const log = await sent();
  assert.deepEqual(log.find((message) => message.method === "session/set_config_option").params, { sessionId: "s-1", configId: "model", value: "large" });
  assert.deepEqual(log.find((message) => message.id === 100).result, { outcome: { outcome: "selected", optionId: "once" } });
  assert.equal(listModels(session).current, "large");
});

test("Stop mid-turn cancels the session and its ask, and the turn ends interrupted", async () => {
  const { session, cwd, sent } = await standIn("stop");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "stop", cwd, text: "wait" });
  const ask = await until(named("ask", "stop"), from);
  assert.equal((await until(named("tool.use", "stop"), from)).kind, "run");
  assert.deepEqual(ask.view, { command: "make test" });
  await session.interrupt();
  assert.deepEqual(await until(named("ask.cancelled", "stop"), from), { event: "ask.cancelled", threadId: "stop", requestId: ask.requestId });
  const done = await until(named("turn.done", "stop"), from);
  assert.equal(done.stopReason, "interrupted");
  assert.equal(session.isRunning, false);
  const log = await sent();
  assert.ok(log.some((message) => message.method === "session/cancel" && message.params.sessionId === "s-1"));
  assert.deepEqual(log.find((message) => message.permission).permission, { outcome: { outcome: "cancelled" } });
});

test("an idle agent is let go, and the next send loads its session without replaying it", async () => {
  const { session, cwd, sent } = await standIn("load");
  sessions.push(session);
  let idle = 0;
  session.onIdle = () => (idle += 1);
  let from = events.length;
  await session.send({ threadId: "load", cwd, text: "hello" });
  await until(named("turn.done", "load"), from);
  assert.equal(idle, 1);
  const now = Date.now();
  assert.ok(session.idleLeft(90_000, now)! > 0);
  assert.equal(session.releaseIfIdle(90_000, now), false);
  assert.equal(session.releaseIfIdle(0, now), true);
  assert.equal(session.idleLeft(0, now), undefined);
  from = events.length;
  await session.send({ threadId: "load", cwd, text: "hello" });
  const started = await until(named("turn.started", "load"), from);
  await until(named("turn.done", "load"), from);
  assert.equal(started.sessionId, "s-1");
  const loads = (await sent()).filter((message) => message.method === "session/load");
  assert.deepEqual(loads.map((message) => message.params), [{ sessionId: "s-1", cwd, mcpServers: [] }]);
  const told = events.slice(from).filter((event) => event.threadId === "load");
  assert.deepEqual(told.map((event) => event.event), ["turn.started", "text", "turn.done"]);
  assert.equal(told[1].delta, "Hi.");
});

test("a session the agent no longer has is said to be lost, and the turn goes on in a new one", async () => {
  const { session, cwd } = await standIn("lost");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "lost", cwd, text: "hello", sessionId: "gone" });
  const done = await until(named("turn.done", "lost"), from);
  assert.deepEqual(
    events.slice(from).filter((event) => event.threadId === "lost").map((event) => event.event),
    ["session.lost", "turn.started", "text", "turn.done"],
  );
  assert.equal(done.sessionId, "s-1");
});

test("an agent that wants a sign-in says the agent's own words once, and the turn ends", async () => {
  const { session, cwd } = await standIn("auth", { ACP_AUTH: "required" });
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "auth", cwd, text: "hello" });
  const done = await until(named("turn.done", "auth"), from);
  const told = events.slice(from).filter((event) => event.threadId === "auth");
  assert.deepEqual(told.map((event) => event.event), ["error", "turn.done"]);
  assert.equal(told[0].message, "Run `stand-in login` in Terminal, then try again.");
  assert.equal(done.stopReason, "error_during_execution");
  assert.equal(session.isRunning, false);
});

test("a sign-in the provider names runs through authenticate before the session", async () => {
  const { session, cwd, sent } = await standIn("login");
  sessions.push(session);
  (session as any).agent.authMethod = "stand_in_login";
  const from = events.length;
  await session.send({ threadId: "login", cwd, text: "hello" });
  await until(named("turn.done", "login"), from);
  const methods = (await sent()).flatMap((message) => (message.method ? [message.method] : []));
  assert.deepEqual(methods.slice(0, 3), ["initialize", "authenticate", "session/new"]);
});

test("an agent that dies mid-turn ends it as the engine stopping, and its ask with it", async () => {
  const { session, cwd } = await standIn("die");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "die", cwd, text: "die" });
  const ask = await until(named("ask", "die"), from);
  const done = await until(named("turn.done", "die"), from);
  const told = events.slice(from).filter((event) => event.threadId === "die");
  assert.deepEqual(told.map((event) => event.event), ["turn.started", "text", "tool.use", "ask", "ask.cancelled", "error", "turn.done"]);
  assert.equal(told[4].requestId, ask.requestId);
  assert.equal(told[5].message, "Stand-in stopped: stand-in: out of memory");
  assert.equal(done.stopReason, "engine_stopped");
  assert.equal(answer({ requestId: ask.requestId, allow: true }), false);
  assert.equal(session.idleLeft(0), undefined);
});

test("a send during a turn, or into a folder that's gone, is refused", async () => {
  const { session, cwd } = await standIn("busy");
  sessions.push(session);
  await assert.rejects(session.send({ threadId: "busy", cwd: join(cwd, "gone"), text: "hello" }), /isn't where it was/);
  const from = events.length;
  await session.send({ threadId: "busy", cwd, text: "hello" });
  await assert.rejects(session.send({ threadId: "busy", cwd, text: "hello" }), /already running/);
  await until(named("turn.done", "busy"), from);
});

test("a send from another folder starts the agent there, and its turn still ends", async () => {
  const { session, cwd, sent } = await standIn("moved");
  sessions.push(session);
  let from = events.length;
  await session.send({ threadId: "moved", cwd, text: "hello" });
  await until(named("turn.done", "moved"), from);
  const elsewhere = await folder();
  from = events.length;
  await session.send({ threadId: "moved", cwd: elsewhere, text: "hello" });
  assert.equal((await until(named("turn.done", "moved"), from)).stopReason, "end_turn");
  assert.deepEqual((await sent()).filter((message) => message.env).map((message) => message.cwd), [cwd, elsewhere]);
});

test("a diff becomes git's hunks, three lines of context around each change", () => {
  const before = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"].join("\n");
  const after = ["a", "B", "c", "d", "e", "f", "g", "h", "i", "j", "k", "L"].join("\n");
  assert.deepEqual(hunks(before, after), [
    { oldStart: 1, newStart: 1, lines: [" a", "-b", "+B", " c", " d", " e"] },
    { oldStart: 9, newStart: 9, lines: [" i", " j", " k", "-l", "+L"] },
  ]);
  assert.deepEqual(hunks(null, "x\ny"), [{ oldStart: 0, newStart: 1, lines: ["+x", "+y"] }]);
  assert.deepEqual(hunks("same", "same"), []);
  // Lines moved around are matched where they still agree, not taken out wholesale.
  assert.deepEqual(hunks("1\n2\n3\n4", "1\n3\n2\n4")[0].lines.filter((line) => line[0] !== " ").length, 2);
});

test("ACP's kinds, arguments and stop reasons in the app's words", () => {
  assert.deepEqual(["read", "edit", "delete", "move", "search", "execute", "think", "fetch", "switch_mode", "other", undefined].map(toolKind), [
    "read",
    "edit",
    "delete",
    "move",
    "search",
    "run",
    "think",
    "fetch",
    "planning",
    "other",
    "other",
  ]);
  assert.deepEqual(toolView({ filePath: "/w/b.ts" }, [], null), { path: "/w/b.ts" });
  assert.deepEqual(toolView({ pattern: "TODO", url: "https://x.dev", query: "q", description: "Look" }, null, null), {
    pattern: "TODO",
    url: "https://x.dev",
    query: "q",
    description: "Look",
  });
  assert.deepEqual(toolView({}, null, [{ type: "diff", path: "/w/c.ts", newText: "" }]), { path: "/w/c.ts" });
  assert.deepEqual(["end_turn", "max_tokens", "max_turn_requests", "refusal", "cancelled"].map(stopReason), ["end_turn", "max_tokens", "error_max_turns", "refusal", "interrupted"]);
});
