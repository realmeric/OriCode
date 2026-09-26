// A Codex thread against a stand-in app-server that scripts its replies, so nothing reaches a model.
import { mkdtemp, readFile, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { CodexSession, answer, availability, choiceOf, limitsOf, listModels, policy, unifiedHunks, unwrap, type CodexBinary } from "../codex.ts";

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

/// The stand-in as the user's codex, and the file it logs what it's sent to.
async function standIn(env: Record<string, string> = {}) {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-codex-")));
  const logFile = join(cwd, "codex.log");
  const binary: CodexBinary = { command: process.execPath, args: [new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname], env: { CODEX_LOG: logFile, ...env } };
  const sent = async () => (await readFile(logFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  return { binary, cwd, sent };
}

async function session(threadId: string, env: Record<string, string> = {}) {
  const { binary, cwd, sent } = await standIn(env);
  const session = new CodexSession(threadId, binary);
  sessions.push(session);
  return { session, cwd, sent };
}

const sessions: CodexSession[] = [];
after(() => sessions.forEach((session) => session.close()));

test("the handshake: initialize names OriCode, the account is read, a thread starts in the folder, the environment is scrubbed", async () => {
  process.env.CLAUDE_CODE_MESSAGING_TOKEN = "not for other agents";
  const { session: codex, cwd, sent } = await session("hand");
  const from = events.length;
  assert.equal(await codex.send({ threadId: "hand", cwd, text: "hello", id: "m1" }), false);
  delete process.env.CLAUDE_CODE_MESSAGING_TOKEN;
  const done = await until(named("turn.done", "hand"), from);
  const said = told("hand", from);
  assert.deepEqual(said.map((event) => event.event), ["message.taken", "turn.started", "text", "turn.done"]);
  assert.deepEqual(said[0], { event: "message.taken", threadId: "hand", messageId: "m1", newTurn: true });
  assert.equal(said[1].sessionId, "t-1");
  assert.equal(said[2].delta, "Hi.");
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "t-1");
  assert.equal(done.waiting, 0);
  assert.deepEqual(done.context, { used: 103, window: 258400 });
  const log = await sent();
  assert.deepEqual(log[0], { env: [], cwd });
  assert.deepEqual(
    log.flatMap((message) => (message.method ? [message.method] : [])),
    ["initialize", "initialized", "account/read", "thread/start", "turn/start"],
  );
  const initialize = log[1];
  assert.equal(initialize.jsonrpc, "2.0");
  assert.equal(initialize.params.clientInfo.name, "oricode");
  assert.equal(initialize.params.capabilities.experimentalApi, false);
  assert.ok(initialize.params.capabilities.optOutNotificationMethods.includes("item/commandExecution/outputDelta"));
  assert.deepEqual(log.find((message) => message.method === "thread/start").params, { cwd, model: null, approvalPolicy: "untrusted" });
  const start = log.find((message) => message.method === "turn/start").params;
  assert.deepEqual(start.input, [{ type: "text", text: "hello", text_elements: [] }]);
  assert.equal(start.threadId, "t-1");
  assert.equal(start.clientUserMessageId, "m1");
  assert.equal(await codex.setFast(true), false);
});

test("a turn: reasoning, text, a read, a command asked and approved, a plan, a file change with its diff, the usage and the limits", async () => {
  const { session: codex, cwd, sent } = await session("work");
  const from = events.length;
  await codex.send({ threadId: "work", cwd, text: "work", model: "gpt-large", effort: "low", permissionMode: "acceptEdits" });
  const run = await until(named("ask", "work"), from);
  assert.equal(run.kind, "permission");
  assert.equal(run.toolUseId, "exec-2");
  assert.equal(run.toolKind, "run");
  assert.deepEqual(run.view, { command: "make test" });
  assert.deepEqual(run.choices, [
    { id: "accept", name: "Yes", kind: "allow_once" },
    { id: "acceptWithExecpolicyAmendment", name: "Yes, and don't ask again for `make test`", kind: "allow_always" },
    { id: "cancel", name: "No, and stop", kind: "reject_once" },
  ]);
  assert.equal(answer({ requestId: run.requestId, allow: true }), true);
  assert.equal(answer({ requestId: run.requestId, allow: true }), false);
  const edit = await until((event) => named("ask", "work")(event) && event.requestId !== run.requestId, from);
  assert.equal(edit.toolUseId, "patch-1:0");
  assert.equal(edit.toolKind, "edit");
  assert.deepEqual(edit.view, { path: "/w/a.txt" });
  assert.deepEqual(edit.choices.map((choice: { id: string }) => choice.id), ["accept", "acceptForSession", "decline", "cancel"]);
  answer({ requestId: edit.requestId, allow: true, optionId: "acceptForSession" });
  const done = await until(named("turn.done", "work"), from);
  const said = told("work", from);
  assert.deepEqual(said.map((event) => event.event), [
    "turn.started",
    "thinking",
    "thinking",
    "text",
    "tool.use",
    "tool.result",
    "tool.use",
    "tool.result",
    "tool.use",
    "ask",
    "tool.result",
    "tool.use",
    "tool.use",
    "ask",
    "tool.result",
    "tool.result",
    "limits",
    "limits",
    "text",
    "turn.done",
  ]);
  assert.equal(said[1].delta + said[2].delta, "Reading first.\n\nThen the edit.");
  const [read, readResult, plan, , test, testResult, change, added, changeResult, addedResult] = said.filter((event) => event.event.startsWith("tool."));
  assert.equal(read.kind, "read");
  assert.equal(read.name, "Shell");
  assert.deepEqual(read.view, { path: "/w/a.txt", command: "cat a.txt" });
  assert.deepEqual(readResult, { event: "tool.result", threadId: "work", toolUseId: "exec-1", content: "one\ntwo\nthree\n", isError: false });
  assert.equal(plan.name, "TodoWrite");
  assert.equal(plan.kind, "plan");
  assert.deepEqual(plan.view.todos, [
    { content: "Read a.txt", activeForm: "Read a.txt", status: "completed" },
    { content: "Edit a.txt", activeForm: "Edit a.txt", status: "in_progress" },
    { content: "Run the tests", activeForm: "Run the tests", status: "pending" },
  ]);
  assert.equal(test.kind, "run");
  assert.deepEqual(test.input, { command: "make test", cwd });
  assert.deepEqual(testResult, { event: "tool.result", threadId: "work", toolUseId: "exec-2", content: "ok\n", isError: false });
  assert.equal(change.kind, "edit");
  assert.equal(change.name, "Edit");
  assert.equal(added.kind, "write");
  assert.deepEqual(added.view, { path: "/w/b.txt" });
  assert.deepEqual(changeResult.patch, [{ oldStart: 1, newStart: 1, lines: [" one", "-two", "+2", " three"] }]);
  assert.deepEqual(addedResult.patch, [{ oldStart: 0, newStart: 1, lines: ["+new", "+file"] }]);
  const limits = said.filter((event) => event.event === "limits");
  assert.deepEqual(limits[0], {
    event: "limits",
    threadId: "work",
    status: "allowed",
    rateLimitType: "30_day",
    utilization: 0.01,
    resetsAt: 1792439399000,
    surpassedThreshold: null,
    windows: [{ id: "30_day", label: "30-day window", used: 0.01, resetsAt: 1792439399000 }],
    plan: "go",
  });
  assert.equal(limits[1].utilization, 0.02);
  assert.equal(done.stopReason, "end_turn");
  assert.deepEqual(done.usage, { input: 400, output: 50, cacheRead: 1800, cacheWrite: 0 });
  assert.deepEqual(done.context, { used: 1230, window: 258400 });
  const log = await sent();
  assert.deepEqual(log.find((message) => message.method === "thread/start").params, { cwd, model: "gpt-large", approvalPolicy: "on-request", sandbox: "workspace-write" });
  const start = log.find((message) => message.method === "turn/start").params;
  assert.equal(start.model, "gpt-large");
  assert.equal(start.effort, "low");
  const answers = log.filter((message) => message.method === undefined && message.result?.decision);
  assert.deepEqual(answers.map((message) => message.result.decision), ["accept", "acceptForSession"]);
});

test("a send during a turn steers it, and the turn takes it", async () => {
  const { session: codex, cwd, sent } = await session("steer");
  const from = events.length;
  await codex.send({ threadId: "steer", cwd, text: "slow", id: "m1" });
  await until(named("text", "steer"), from);
  assert.equal(await codex.send({ threadId: "steer", cwd, text: "and the tests", id: "m2" }), true);
  const done = await until(named("turn.done", "steer"), from);
  assert.deepEqual(told("steer", from).map((event) => event.event), ["message.taken", "turn.started", "text", "message.taken", "text", "turn.done"]);
  assert.deepEqual(told("steer", from)[3], { event: "message.taken", threadId: "steer", messageId: "m2", newTurn: false });
  assert.equal(done.waiting, 0);
  const steer = (await sent()).find((message) => message.method === "turn/steer").params;
  assert.deepEqual(steer, { threadId: "t-1", input: [{ type: "text", text: "and the tests", text_elements: [] }], expectedTurnId: "turn-1", clientUserMessageId: "m2" });
});

test("Stop interrupts the turn and cancels its ask, and the turn ends interrupted", async () => {
  const { session: codex, cwd, sent } = await session("stop");
  const from = events.length;
  await codex.send({ threadId: "stop", cwd, text: "wait" });
  const ask = await until(named("ask", "stop"), from);
  await codex.interrupt();
  assert.deepEqual(await until(named("ask.cancelled", "stop"), from), { event: "ask.cancelled", threadId: "stop", requestId: ask.requestId });
  const done = await until(named("turn.done", "stop"), from);
  assert.equal(done.stopReason, "interrupted");
  assert.equal(codex.isRunning, false);
  assert.equal(answer({ requestId: ask.requestId, allow: true }), false);
  const log = await sent();
  assert.deepEqual(log.find((message) => message.method === "turn/interrupt").params, { threadId: "t-1", turnId: "turn-1" });
  assert.deepEqual(log.find((message) => message.result?.decision).result, { decision: "cancel" });
});

test("an idle app-server is let go, the next send resumes the thread without its turns, and a new mode reopens it", async () => {
  const { session: codex, cwd, sent } = await session("resume");
  let idle = 0;
  codex.onIdle = () => (idle += 1);
  let from = events.length;
  await codex.send({ threadId: "resume", cwd, text: "hello" });
  await until(named("turn.done", "resume"), from);
  assert.equal(idle, 1);
  const now = Date.now();
  assert.ok(codex.idleLeft(90_000, now)! > 0);
  assert.equal(codex.releaseIfIdle(90_000, now), false);
  assert.equal(codex.releaseIfIdle(0, now), true);
  assert.equal(codex.idleLeft(0, now), undefined);
  from = events.length;
  await codex.send({ threadId: "resume", cwd, text: "hello" });
  assert.equal((await until(named("turn.started", "resume"), from)).sessionId, "t-1");
  await until(named("turn.done", "resume"), from);
  assert.equal(await codex.setMode("plan"), true);
  from = events.length;
  await codex.send({ threadId: "resume", cwd, text: "hello" });
  await until(named("turn.done", "resume"), from);
  const log = await sent();
  assert.deepEqual(
    log.filter((message) => message.method === "thread/resume").map((message) => message.params),
    [
      { threadId: "t-1", excludeTurns: true, cwd, model: null, approvalPolicy: "untrusted" },
      { threadId: "t-1", excludeTurns: true, cwd, model: null, approvalPolicy: "never", sandbox: "read-only" },
    ],
  );
  assert.equal(log.filter((message) => message.env).length, 3);
});

test("a thread Codex no longer has is said to be lost, and the turn goes on in a new one", async () => {
  const { session: codex, cwd } = await session("lost");
  const from = events.length;
  await codex.send({ threadId: "lost", cwd, text: "hello", sessionId: "gone" });
  const done = await until(named("turn.done", "lost"), from);
  assert.deepEqual(told("lost", from).map((event) => event.event), ["session.lost", "turn.started", "text", "turn.done"]);
  assert.equal(done.sessionId, "t-1");
});

test("a signed-out Codex says the Terminal line once and starts no thread", async () => {
  const { binary, cwd, sent } = await standIn({ CODEX_SIGNED_OUT: "1" });
  assert.deepEqual(await availability(binary), { state: "signedOut", plan: null, hint: "Run `codex login` in Terminal and log in." });
  const codex = new CodexSession("out", binary);
  sessions.push(codex);
  const from = events.length;
  await codex.send({ threadId: "out", cwd, text: "hello" });
  const done = await until(named("turn.done", "out"), from);
  const said = told("out", from);
  assert.deepEqual(said.map((event) => event.event), ["error", "turn.done"]);
  assert.equal(said[0].message, "Codex isn't signed in. Run `codex login` in Terminal, then try again.");
  assert.equal(done.stopReason, "error_during_execution");
  assert.equal((await sent()).some((message) => message.method === "thread/start"), false);
  assert.equal(codex.idleLeft(0), undefined);
});

test("a signed-in Codex is ready with its plan, and lists its models with their levels", async () => {
  const { binary } = await standIn();
  assert.deepEqual(await availability(binary), { state: "ready", plan: "go", hint: null });
  assert.deepEqual(await availability({ command: "/nowhere/codex" }), {
    state: "missing",
    plan: null,
    hint: "Codex isn't installed. Install it with `npm install -g @openai/codex`, then run `codex login`.",
  });
  assert.deepEqual(await listModels(binary), [
    { id: "gpt-small", name: "GPT Small", description: "Quick", efforts: ["low", "medium", "high"], defaultEffort: "medium", ultra: false, isDefault: false },
    { id: "gpt-large", name: "GPT Large", description: "Deep", efforts: ["low", "medium", "high", "xhigh", "max"], defaultEffort: "high", ultra: true, isDefault: true },
  ]);
});

test("an app-server that dies mid-turn ends it as the engine stopping, and its ask with it", async () => {
  const { session: codex, cwd } = await session("die");
  const from = events.length;
  await codex.send({ threadId: "die", cwd, text: "die" });
  const ask = await until(named("ask", "die"), from);
  const done = await until(named("turn.done", "die"), from);
  const said = told("die", from);
  assert.deepEqual(said.map((event) => event.event), ["turn.started", "text", "tool.use", "ask", "ask.cancelled", "error", "turn.done"]);
  assert.equal(said[4].requestId, ask.requestId);
  assert.equal(said[5].message, "Codex stopped: codex: out of memory");
  assert.equal(done.stopReason, "engine_stopped");
  assert.equal(answer({ requestId: ask.requestId, allow: true }), false);
  assert.equal(codex.idleLeft(0), undefined);
});

test("a usage limit Codex names a reset for comes as a limit, not an error", async () => {
  const { session: codex, cwd } = await session("limit");
  const from = events.length;
  await codex.send({ threadId: "limit", cwd, text: "limit" });
  const done = await until(named("turn.done", "limit"), from);
  const said = told("limit", from);
  assert.deepEqual(said.map((event) => event.event), ["turn.started", "limits", "limited", "turn.done"]);
  assert.equal(said[1].status, "rejected");
  assert.deepEqual(said[2], { event: "limited", threadId: "limit", resetsAt: 1792439399000, window: "30_day" });
  assert.equal(done.stopReason, "error_during_execution");
});

test("Codex's questions come as AskUserQuestion, and go back by their ids", async () => {
  const { session: codex, cwd, sent } = await session("question");
  const from = events.length;
  await codex.send({ threadId: "question", cwd, text: "question" });
  const ask = await until(named("ask", "question"), from);
  assert.equal(ask.kind, "question");
  assert.equal(ask.tool, "AskUserQuestion");
  assert.deepEqual(ask.input, {
    questions: [{ question: "Which colour?", header: "Colour", options: [{ label: "Red", description: "Warm" }, { label: "Blue", description: "Cool" }], multiSelect: false }],
  });
  answer({ requestId: ask.requestId, allow: true, answers: { "Which colour?": "Blue" } });
  await until(named("turn.done", "question"), from);
  assert.deepEqual((await sent()).find((message) => message.result?.answers).result, { answers: { color: { answers: ["Blue"] } } });
});

test("a send into a folder that's gone is refused, and a mode can't reach a running turn", async () => {
  const { session: codex, cwd } = await session("busy");
  await assert.rejects(codex.send({ threadId: "busy", cwd: join(cwd, "gone"), text: "hello" }), /isn't where it was/);
  const from = events.length;
  await codex.send({ threadId: "busy", cwd, text: "slow" });
  assert.equal(await codex.setMode("plan"), false);
  await until(named("text", "busy"), from);
  await codex.interrupt();
  await until(named("turn.done", "busy"), from);
});

test("modes, decisions, commands, diffs and windows in the app's words", () => {
  assert.deepEqual(["default", "acceptEdits", "auto", "plan", "bypassPermissions", undefined].map(policy), [
    { approvalPolicy: "untrusted" },
    { approvalPolicy: "on-request", sandbox: "workspace-write" },
    { approvalPolicy: "on-request" },
    { approvalPolicy: "never", sandbox: "read-only" },
    { approvalPolicy: "never", sandbox: "danger-full-access" },
    { approvalPolicy: "untrusted" },
  ]);
  assert.deepEqual(choiceOf({ applyNetworkPolicyAmendment: { network_policy_amendment: { host: "npmjs.org", action: "allow" } } }), {
    id: "applyNetworkPolicyAmendment",
    name: "Always allow npmjs.org",
    kind: "allow_always",
  });
  assert.equal(choiceOf("decline").kind, "reject_once");
  assert.equal(unwrap("/bin/zsh -lc 'cat hello.txt'"), "cat hello.txt");
  assert.equal(unwrap(`/bin/bash -lc 'echo '\\''hi'\\'''`), "echo 'hi'");
  assert.equal(unwrap("ls -la"), "ls -la");
  assert.deepEqual(unifiedHunks("--- a/x\n+++ b/x\n@@ -2,2 +2,3 @@\n a\n+b\n c\n@@ -10 +11 @@\n-z\n+Z\n"), [
    { oldStart: 2, newStart: 2, lines: [" a", "+b", " c"] },
    { oldStart: 10, newStart: 11, lines: ["-z", "+Z"] },
  ]);
  const windows = limitsOf({
    primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 10 },
    secondary: { usedPercent: 70, windowDurationMins: 10080, resetsAt: 20 },
    planType: "plus",
    rateLimitReachedType: null,
  });
  assert.deepEqual(windows.windows.map((window) => window.label), ["5-hour window", "7-day window"]);
  assert.equal(windows.rateLimitType, "seven_day");
  assert.equal(windows.utilization, 0.7);
});
