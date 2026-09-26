// A Pi thread against a stand-in `pi --mode rpc` that scripts its runs, so nothing reaches a model.
import { mkdtemp, readFile, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { PiSession, availability, capabilities, efforts, listModels, modelRef, toolCall, type PiBinary } from "../pi.ts";

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

const told = (threadId: string, from: number) => events.slice(from).filter((event) => event.threadId === threadId);

/// The stand-in as the user's pi, and the file it logs what it's sent to.
async function standIn(env: Record<string, string> = {}) {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-pi-")));
  const logFile = join(cwd, "pi.log");
  const binary: PiBinary = { command: process.execPath, args: [new URL("./fixtures/pi-rpc.ts", import.meta.url).pathname], env: { PI_LOG: logFile, ...env } };
  const sent = async () => (await readFile(logFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  return { binary, cwd, sent };
}

async function session(threadId: string, env: Record<string, string> = {}) {
  const { binary, cwd, sent } = await standIn(env);
  const session = new PiSession(threadId, binary);
  sessions.push(session);
  return { session, cwd, sent };
}

const sessions: PiSession[] = [];
after(() => sessions.forEach((session) => session.close()));

const commands = (log: Record<string, any>[]) => log.flatMap((message) => (message.type ? [message.type] : []));

test("a turn: thinking, text, a read, an edit with its diff, a write, a failed command, the usage, cost and context", async () => {
  process.env.CLAUDE_CODE_MESSAGING_TOKEN = "not for other agents";
  const { session: pi, cwd, sent } = await session("work");
  const from = events.length;
  assert.equal(await pi.send({ threadId: "work", cwd, text: "work", model: "anthropic/claude-opus", effort: "high", id: "m1" }), false);
  delete process.env.CLAUDE_CODE_MESSAGING_TOKEN;
  const done = await until(named("turn.done", "work"), from);
  const said = told("work", from);
  assert.deepEqual(said.map((event) => event.event), [
    "message.taken",
    "turn.started",
    "thinking",
    "thinking",
    "text",
    "tool.use",
    "tool.result",
    "tool.use",
    "tool.result",
    "tool.use",
    "tool.result",
    "tool.use",
    "tool.result",
    "text",
    "turn.done",
  ]);
  assert.deepEqual(said[0], { event: "message.taken", threadId: "work", messageId: "m1", newTurn: true });
  assert.equal(said[1].sessionId, done.sessionId);
  assert.ok(done.sessionId.startsWith(join(cwd, "sessions")));
  assert.equal(said[2].delta + said[3].delta, "Reading first. Then the edit.");
  const [read, readResult, edit, editResult, written, writeResult, bash, bashResult] = said.filter((event) => event.event.startsWith("tool."));
  assert.deepEqual(read, { event: "tool.use", threadId: "work", toolUseId: "call-1", name: "Read", input: { path: "a.txt" }, kind: "read", view: { path: "a.txt" } });
  assert.deepEqual(readResult, { event: "tool.result", threadId: "work", toolUseId: "call-1", content: "one\ntwo\nthree\n", isError: false });
  assert.equal(edit.kind, "edit");
  assert.deepEqual(edit.view, { path: "a.txt" });
  assert.deepEqual(editResult.patch, [{ oldStart: 1, newStart: 1, lines: [" one", "-two", "+2", " three"] }]);
  assert.equal(written.kind, "write");
  assert.deepEqual(writeResult.patch, [{ oldStart: 0, newStart: 1, lines: ["+new", "+file"] }]);
  assert.equal(bash.kind, "run");
  assert.deepEqual(bash.view, { command: "make test" });
  assert.deepEqual(bashResult, { event: "tool.result", threadId: "work", toolUseId: "call-4", content: "boom", isError: true });
  assert.equal(said[13].delta, "Done.");
  assert.equal(done.stopReason, "end_turn");
  assert.deepEqual(done.usage, { input: 2200, output: 50, cacheRead: 1800, cacheWrite: 0 });
  assert.equal(Math.round(done.costUSD * 1000), 30);
  assert.deepEqual(done.context, { used: 2230, window: 200000 });
  assert.equal(done.waiting, 0);
  const log = await sent();
  assert.deepEqual(log[0], { args: ["--mode", "rpc"], env: [], cwd });
  assert.deepEqual(log.find((message) => message.type === "set_model"), { id: "1", type: "set_model", provider: "anthropic", modelId: "claude-opus" });
  assert.deepEqual(log.find((message) => message.type === "set_thinking_level").level, "high");
  assert.deepEqual(log.find((message) => message.type === "prompt"), { id: "3", type: "prompt", message: "work" });
  // An extension's dialog is answered, so its run isn't held.
  assert.deepEqual(log.find((message) => message.type === "extension_ui_response"), { type: "extension_ui_response", id: "ui-1", cancelled: true });
  assert.equal(pi.isRunning, false);
});

test("a send during a run steers it, and one queued goes as a follow-up", async () => {
  for (const [threadId, followUp, how] of [["steer", false, "steer"], ["follow", true, "followUp"]] as const) {
    const { session: pi, cwd, sent } = await session(threadId);
    const from = events.length;
    await pi.send({ threadId, cwd, text: "slow", id: "m1" });
    await until(named("text", threadId), from);
    assert.equal(await pi.send({ threadId, cwd, text: "and the tests", id: "m2", followUp }), true);
    const done = await until(named("turn.done", threadId), from);
    assert.deepEqual(told(threadId, from).map((event) => event.event), ["message.taken", "turn.started", "text", "message.taken", "text", "turn.done"]);
    assert.deepEqual(told(threadId, from)[3], { event: "message.taken", threadId, messageId: "m2", newTurn: false });
    assert.equal(done.waiting, 0);
    const prompts = (await sent()).filter((message) => message.type === "prompt");
    assert.deepEqual(prompts[1], { id: prompts[1].id, type: "prompt", message: "and the tests", streamingBehavior: how });
  }
});

test("Stop takes what's waiting off Pi's queue, then aborts, and the turn ends interrupted", async () => {
  const { session: pi, cwd, sent } = await session("stop");
  const from = events.length;
  await pi.send({ threadId: "stop", cwd, text: "wait", id: "m1" });
  await until(named("text", "stop"), from);
  assert.equal(await pi.send({ threadId: "stop", cwd, text: "later", id: "m2" }), true);
  await pi.interrupt();
  const done = await until(named("turn.done", "stop"), from);
  assert.deepEqual(told("stop", from).map((event) => event.event), ["message.taken", "turn.started", "text", "message.cancelled", "turn.done"]);
  assert.equal(told("stop", from)[3].messageId, "m2");
  assert.equal(done.stopReason, "interrupted");
  assert.equal(pi.isRunning, false);
  const log = commands(await sent());
  assert.ok(log.indexOf("clear_queue") < log.indexOf("abort"));
});

test("an idle Pi is let go, and the next send resumes its session file; a file that's gone is lost, and an id goes by --session-id", async () => {
  const { session: pi, cwd, sent } = await session("resume");
  let idle = 0;
  pi.onIdle = () => (idle += 1);
  let from = events.length;
  await pi.send({ threadId: "resume", cwd, text: "hello" });
  const first = await until(named("turn.done", "resume"), from);
  // U+2028 is a line separator to readline, and only a character to Pi's framing.
  assert.equal((await until(named("text", "resume"), from)).delta, "Hi. There");
  assert.equal(idle, 1);
  const now = Date.now();
  assert.ok(pi.idleLeft(90_000, now)! > 0);
  assert.equal(pi.releaseIfIdle(90_000, now), false);
  assert.equal(pi.releaseIfIdle(0, now), true);
  assert.equal(pi.idleLeft(0, now), undefined);
  from = events.length;
  await pi.send({ threadId: "resume", cwd, text: "hello" });
  assert.equal((await until(named("turn.started", "resume"), from)).sessionId, first.sessionId);
  await until(named("turn.done", "resume"), from);
  const starts = (await sent()).filter((message) => message.args);
  assert.deepEqual(starts.map((start) => start.args), [["--mode", "rpc"], ["--mode", "rpc", "--session", first.sessionId]]);

  const lost = await session("lost");
  from = events.length;
  await lost.session.send({ threadId: "lost", cwd: lost.cwd, text: "hello", sessionId: "/nowhere/gone.jsonl" });
  const done = await until(named("turn.done", "lost"), from);
  assert.deepEqual(told("lost", from).map((event) => event.event), ["session.lost", "turn.started", "text", "turn.done"]);
  assert.notEqual(done.sessionId, "/nowhere/gone.jsonl");
  assert.deepEqual((await lost.sent())[0].args, ["--mode", "rpc"]);

  const byId = await session("id");
  from = events.length;
  await byId.session.send({ threadId: "id", cwd: byId.cwd, text: "hello", sessionId: "abc-1" });
  assert.equal((await until(named("turn.done", "id"), from)).sessionId, join(byId.cwd, "sessions", "abc-1.jsonl"));
  assert.deepEqual((await byId.sent())[0].args, ["--mode", "rpc", "--session-id", "abc-1"]);
});

test("models come grouped by pi's provider, each saying key or login, and the logins other makers forbid are marked", async () => {
  const { binary, sent } = await standIn({ PI_AUTH: JSON.stringify({ anthropic: "oauth", openai: "api_key", xai: "oauth", meta: "api_key", openrouter: "oauth" }) });
  const groups = await listModels(binary);
  assert.deepEqual(groups.map((group) => group.provider), ["anthropic", "openai", "xai", "meta", "openrouter"]);
  const all = groups.flatMap((group) => group.models);
  assert.deepEqual(
    all.map((model) => [model.id, model.auth, model.forbidden ?? null]),
    [
      ["anthropic/claude-opus", "login", "anthropic"],
      ["openai/gpt-5.5", "key", null],
      ["openai/gpt-4", "key", null],
      ["xai/grok-5", "login", "xai"],
      ["meta/muse-1", "key", null],
      ["openrouter/anthropic/claude-haiku", "login", null],
    ],
  );
  assert.deepEqual(all[1], {
    id: "openai/gpt-5.5",
    name: "GPT-5.5",
    provider: "openai",
    auth: "key",
    efforts: ["off", "low", "medium", "high", "xhigh"],
    images: true,
    contextWindow: 272000,
    isDefault: true,
  });
  assert.deepEqual(all[0].efforts, ["off", "minimal", "low", "medium", "high", "xhigh", "max"]);
  assert.deepEqual(all[2].efforts, ["off"]);
  assert.equal(all.filter((model) => model.isDefault).length, 1);
  // Asked offline and without a session, so listing them reaches nothing and writes nothing.
  assert.deepEqual((await sent())[0].args, ["--mode", "rpc", "--no-session", "--offline"]);

  const meta = await standIn({ PI_AUTH: JSON.stringify({ meta: "oauth" }) });
  const muse = (await listModels(meta.binary)).find((group) => group.provider === "meta")!.models[0];
  assert.equal(muse.forbidden, "meta");
});

test("Pi is ready with its version when it holds a model, signed out when it holds none, and missing when it isn't there", async () => {
  const { binary } = await standIn();
  assert.deepEqual(await availability(binary), { state: "ready", cli: process.execPath, version: "0.87.1", hint: null });
  const empty = await standIn({ PI_EMPTY: "1" });
  assert.deepEqual(await availability(empty.binary), { state: "signedOut", cli: process.execPath, version: "0.87.1", hint: "Run `pi` in Terminal, then /login." });
  assert.deepEqual(await availability({ command: "/nowhere/pi" }), {
    state: "missing",
    cli: null,
    version: null,
    hint: "Pi isn't installed. Install it with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`, then run `pi` and /login.",
  });
});

test("a Pi that dies mid-run ends the turn as the engine stopping, and what was sent to it with it", async () => {
  const { session: pi, cwd } = await session("die");
  const from = events.length;
  await pi.send({ threadId: "die", cwd, text: "die" });
  await until(named("text", "die"), from);
  await pi.send({ threadId: "die", cwd, text: "too late", id: "m2" });
  const done = await until(named("turn.done", "die"), from);
  const said = told("die", from);
  assert.deepEqual(said.map((event) => event.event), ["turn.started", "text", "message.cancelled", "error", "turn.done"]);
  assert.equal(said[3].message, "Pi stopped: pi: out of memory");
  assert.equal(done.stopReason, "engine_stopped");
  assert.equal(pi.idleLeft(0), undefined);
});

test("a model's error, a prompt Pi refuses and an extension command each end the turn", async () => {
  const { session: pi, cwd } = await session("errors");
  let from = events.length;
  await pi.send({ threadId: "errors", cwd, text: "fail" });
  let done = await until(named("turn.done", "errors"), from);
  assert.equal((await until(named("error", "errors"), from)).message, "401 invalid x-api-key");
  assert.equal(done.stopReason, "error_during_execution");

  from = events.length;
  await pi.send({ threadId: "errors", cwd, text: "nokey" });
  done = await until(named("turn.done", "errors"), from);
  assert.match((await until(named("error", "errors"), from)).message, /^No API key found for anthropic/);
  assert.equal(done.stopReason, "error_during_execution");

  from = events.length;
  await pi.send({ threadId: "errors", cwd, text: "/llama" });
  done = await until(named("turn.done", "errors"), from);
  assert.deepEqual(told("errors", from).map((event) => event.event), ["turn.started", "turn.done"]);
  assert.equal(done.stopReason, "end_turn");

  assert.deepEqual(await pi.commands(), [
    { name: "fix-tests", description: "Fix failing tests", argumentHint: "" },
    { name: "llama", description: "", argumentHint: "" },
  ]);
  await assert.rejects(pi.send({ threadId: "errors", cwd: join(cwd, "gone"), text: "hello" }), /isn't where it was/);
});

test("model ids, levels and tools in the app's words", () => {
  assert.deepEqual(modelRef("openrouter/anthropic/claude-haiku"), { provider: "openrouter", modelId: "anthropic/claude-haiku" });
  assert.deepEqual(efforts({ reasoning: true }), ["off", "minimal", "low", "medium", "high"]);
  assert.deepEqual(
    ["read", "bash", "edit", "write", "grep", "find", "ls", "todo"].map((tool) => [toolCall(tool, {}).name, toolCall(tool, {}).kind]),
    [
      ["Read", "read"],
      ["Bash", "run"],
      ["Edit", "edit"],
      ["Write", "write"],
      ["Grep", "search"],
      ["Glob", "search"],
      ["LS", "list"],
      ["todo", "other"],
    ],
  );
  assert.deepEqual(toolCall("grep", { pattern: "TODO", path: "src" }).view, { path: "src", pattern: "TODO" });
  assert.equal(capabilities.unsupervised, true);
  assert.equal(capabilities.steer, true);
});
