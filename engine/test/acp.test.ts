// An ACP thread against a stand-in agent that scripts its replies, so nothing reaches a model.
import { chmod, mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { AcpSession, answer, listModels, modes, type AcpAgent } from "../acp.ts";
import { hunks, stopReason, toolKind, toolView } from "../acp-map.ts";
import { acpProvider } from "../acp-provider.ts";
import { availability, copilot, noPlan } from "../copilot.ts";
import { auto, cursor, named as cursorNamed, onPlan, sessionFolder } from "../cursor.ts";
import type { Model } from "../models.ts";
import { listed, preferred, reach } from "../opencode.ts";
import { answer as answerThroughRegistry, asks } from "../provider.ts";

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
async function standIn(threadId: string, env: Record<string, string> = {}, quirks: Partial<AcpAgent> = {}) {
  const cwd = await folder();
  const logFile = join(cwd, "agent.log");
  const agent: AcpAgent = {
    name: "Stand-in",
    command: process.execPath,
    args: [new URL("./fixtures/acp-agent.ts", import.meta.url).pathname],
    env: { ACP_LOG: logFile, ACP_EXTRA: "passed", ...env },
    ...quirks,
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

test("an answer through the app's registry picks the agent's own option by its id", async () => {
  const { session, cwd, sent } = await standIn("choice");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "choice", cwd, text: "work" });
  const ask = await until(named("ask", "choice"), from);
  assert.equal(ask.toolKind, "edit");
  assert.ok(asks.has(ask.requestId));
  answerThroughRegistry({ requestId: ask.requestId, allow: true, optionId: "always" });
  assert.equal(asks.has(ask.requestId), false);
  assert.equal(answer({ requestId: ask.requestId, allow: true }), false);
  await until(named("turn.done", "choice"), from);
  const log = await sent();
  assert.deepEqual(log.find((message) => message.id === 100).result, { outcome: { outcome: "selected", optionId: "always" } });
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

test("OpenCode's calls: a command told once it has one, its todo list as the plan, an edit at its own lines", async () => {
  const { session, cwd } = await standIn("oc");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "oc", cwd, text: "opencode" });
  await until(named("turn.done", "oc"), from);
  const told = events.slice(from).filter((event) => event.event.startsWith("tool."));
  assert.deepEqual(
    told.map((event) => [event.event, event.toolUseId]),
    [
      ["tool.use", "oc-run"],
      ["tool.result", "oc-run"],
      ["tool.use", "oc-todo"],
      ["tool.result", "oc-todo"],
      ["tool.use", "oc-edit"],
      ["tool.result", "oc-edit"],
    ],
  );
  const [run, , plan, , , edited] = told;
  assert.deepEqual([run.kind, run.view.command], ["run", "echo hi"]);
  assert.deepEqual([plan.name, plan.kind], ["TodoWrite", "plan"]);
  assert.deepEqual(plan.view.todos, [
    { content: "Draft the README", activeForm: "Draft the README", status: "in_progress" },
    { content: "Check it", activeForm: "Check it", status: "pending" },
  ]);
  assert.deepEqual(edited.patch, [{ oldStart: 1, newStart: 1, lines: [" one", "-two", "+2", " three"] }]);
});

test("a mode the process wasn't started for starts another, which picks the session up; a level goes to thought_level, and none to its default", async () => {
  const { session, cwd, sent } = await standIn("reach");
  sessions.push(session);
  (session as any).agent.permissions = (mode: string) => (mode === "auto" ? { mode: "agent" } : { mode: mode === "plan" ? "plan" : "agent", env: { ACP_EXTRA: "asks" } });
  let from = events.length;
  await session.send({ threadId: "reach", cwd, text: "hello", permissionMode: "default", effort: "high" });
  await until(named("turn.done", "reach"), from);
  // Plan is started with what Ask is, so it's taken now; Auto is started without it, so the
  // next turn starts another process.
  assert.equal(await session.setMode("plan"), true);
  assert.equal(await session.setMode("auto"), true);
  from = events.length;
  await session.send({ threadId: "reach", cwd, text: "hello", permissionMode: "auto" });
  assert.equal((await until(named("turn.done", "reach"), from)).sessionId, "s-1");
  const log = await sent();
  assert.deepEqual(log.filter((message) => message.env).map((message) => message.extra), ["asks", "passed"]);
  assert.deepEqual(log.filter((message) => message.method === "session/load").map((message) => message.params.sessionId), ["s-1"]);
  assert.deepEqual(
    log.filter((message) => message.method === "session/set_config_option").map((message) => message.params),
    [
      { sessionId: "s-1", configId: "effort", value: "high" },
      { sessionId: "s-1", configId: "effort", value: "default" },
    ],
  );
  assert.deepEqual(log.filter((message) => message.method === "session/set_mode").map((message) => message.params.modeId), ["plan"]);
});

test("a provider from an agent's entry offers what the entry says, and lists its models from a session it then forgets", async () => {
  const cwd = await folder();
  const logFile = join(cwd, "agent.log");
  const forgotten: string[] = [];
  const provider = acpProvider({
    id: "cursor",
    args: [new URL("./fixtures/acp-agent.ts", import.meta.url).pathname],
    env: { ACP_LOG: logFile, ACP_MODEL: "large" },
    resume: true,
    images: false,
    modeLive: true,
    handoff: "cursor-agent --resume {session}",
    levels: ["low", "medium", "high"],
    modes: ["default", "plan"],
    forget: async (_cli, sessionId) => forgotten.push(sessionId),
  });
  assert.deepEqual([provider.id, provider.name, provider.agent], ["cursor", "Cursor", "Cursor"]);
  assert.deepEqual(provider.capabilities, {
    steer: false,
    resume: true,
    modeLive: true,
    attachments: false,
    heads: false,
    stopTask: false,
    limits: false,
    usage: false,
    commands: true,
    compact: false,
    commitMessage: false,
    handoff: "cursor-agent --resume {session}",
    workers: true,
  });
  assert.deepEqual(provider.levels, ["low", "medium", "high"]);
  assert.deepEqual(await provider.models({ state: "ready", cli: null, version: null, hint: null }, () => {}), []);
  // Off in Settings, it isn't looked for.
  await assert.rejects(provider.availability(), /Cursor is off in Settings › Agents/);
  const models = await provider.listModels!(process.execPath);
  // The agent's own current model comes first.
  assert.deepEqual(
    models.map((model) => [model.id, model.name, model.efforts]),
    [
      ["large", "Large", ["low", "medium", "high"]],
      ["small", "Small", ["low", "medium", "high"]],
    ],
  );
  assert.deepEqual(forgotten, ["s-1"]);
  const methods = (await readFile(logFile, "utf8")).trim().split("\n").flatMap((line) => JSON.parse(line).method ?? []);
  assert.deepEqual(methods, ["initialize", "session/new"]);
});

test("OpenCode's permissions for each of a thread's modes", () => {
  const permission = (mode: string) => {
    const { mode: agent, env } = reach(mode);
    return [agent, env && JSON.parse(env.OPENCODE_PERMISSION)];
  };
  assert.deepEqual(permission("default"), ["build", { read: "ask", edit: "ask", bash: "ask", webfetch: "ask" }]);
  assert.deepEqual(permission("acceptEdits"), ["build", { edit: "allow", bash: "ask" }]);
  assert.deepEqual(permission("auto"), ["build", undefined]);
  assert.deepEqual(permission("plan"), ["plan", undefined]);
  assert.deepEqual(permission("bypassPermissions"), ["build", { "*": "allow" }]);
});

test("OpenCode starts on its own pick among its first provider's models", () => {
  const models = listed(
    ["zen/aa-free", "zen/big-pickle", "zen/zz-free", "router/gpt-5"].map((id) => `${id}\n{\n  "providerID": "${id.split("/")[0]}",\n  "name": "${id}"\n}`).join("\n") + "\nbroken\n{\n  nope\n}\n",
  );
  assert.deepEqual(
    models.map((model) => model.id),
    ["zen/aa-free", "zen/big-pickle", "zen/zz-free", "router/gpt-5"],
  );
  // Its favourites rank first, and only the first provider's count; then ids from the end.
  assert.equal(preferred(models), "zen/big-pickle");
  assert.equal(preferred(models.filter((model) => model.id !== "zen/big-pickle")), "zen/zz-free");
  assert.equal(preferred([]), undefined);
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

test("Copilot's error as the turn's only text is the turn's error; text that goes on after one is the reply", async () => {
  const { session, cwd } = await standIn("refused", {}, { textErrors: true });
  sessions.push(session);
  let from = events.length;
  await session.send({ threadId: "refused", cwd, text: "refused" });
  const done = await until(named("turn.done", "refused"), from);
  const told = events.slice(from).filter((event) => event.threadId === "refused");
  assert.deepEqual(told.map((event) => event.event), ["turn.started", "error", "turn.done"]);
  assert.equal(told[1].message, "Authorization error. Your credentials may be expired or invalid. (Request ID: 1)");
  assert.equal(done.stopReason, "error_during_execution");
  assert.deepEqual(done.context, { used: 11617, window: 128000 });
  from = events.length;
  await session.send({ threadId: "refused", cwd, text: "quote" });
  await until(named("turn.done", "refused"), from);
  const quoted = events.slice(from).filter((event) => event.threadId === "refused");
  assert.deepEqual(quoted.map((event) => event.event), ["turn.started", "text", "text", "turn.done"]);
  assert.equal(quoted[1].delta + quoted[2].delta, "Error: is what it printed, and then it stopped.");
  // An agent that doesn't send its errors that way has them shown as it sent them.
  const plain = await standIn("plain");
  sessions.push(plain.session);
  from = events.length;
  await plain.session.send({ threadId: "plain", cwd: plain.cwd, text: "refused" });
  assert.equal((await until(named("turn.done", "plain"), from)).stopReason, "end_turn");
  assert.ok(events.slice(from).some((event) => event.event === "text" && event.threadId === "plain" && event.delta.startsWith("Error:")));
});

test("Cursor's command shows what it printed, and an ask it sends after Stop is refused unseen", async () => {
  const { session, cwd, sent } = await standIn("late");
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "late", cwd, text: "cursor" });
  const printed = await until((event) => event.event === "tool.result" && event.toolUseId === "cu-run", from);
  assert.equal(printed.content, "hi\n");
  await until((event) => event.event === "tool.use" && event.toolUseId === "cu-sleep", from);
  await session.interrupt();
  assert.equal((await until(named("turn.done", "late"), from)).stopReason, "interrupted");
  let late: any;
  for (let tries = 0; tries < 40 && !late; tries += 1) {
    await new Promise((resolve) => setTimeout(resolve, 25));
    late = (await sent()).find((message) => message.late)?.late;
  }
  assert.deepEqual(late, { outcome: { outcome: "cancelled" } });
  assert.equal(events.slice(from).some((event) => event.event === "ask" && event.threadId === "late"), false);
});

test("an ask's allow always says what the agent does with it", async () => {
  const { session, cwd } = await standIn("always", {}, { allowAlways: "Into the agent's own allowlist." });
  sessions.push(session);
  const from = events.length;
  await session.send({ threadId: "always", cwd, text: "work" });
  const ask = await until(named("ask", "always"), from);
  assert.deepEqual(ask.choices, [
    { id: "once", name: "Allow once", kind: "allow_once" },
    { id: "always", name: "Always allow", kind: "allow_always", help: "Into the agent's own allowlist." },
    { id: "reject", name: "Reject", kind: "reject_once" },
  ]);
  answer({ requestId: ask.requestId, allow: false });
  await until(named("turn.done", "always"), from);
});

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

async function ended(pid: number): Promise<boolean> {
  for (let tries = 0; tries < 40 && alive(pid); tries += 1) await new Promise((resolve) => setTimeout(resolve, 50));
  return !alive(pid);
}

test("what an agent leaves behind in a folder ends with the last of its sessions there, and no sooner", async () => {
  const cwd = await folder();
  const agent = (name: string): AcpAgent => ({
    name: "Stand-in",
    command: process.execPath,
    args: [new URL("./fixtures/acp-agent.ts", import.meta.url).pathname],
    env: { ACP_STRAY: join(cwd, `${name}.pid`) },
    strays: true,
  });
  const first = new AcpSession("stray-1", agent("first"));
  const second = new AcpSession("stray-2", agent("second"));
  sessions.push(first, second);
  for (const [session, threadId] of [
    [first, "stray-1"],
    [second, "stray-2"],
  ] as const) {
    const from = events.length;
    await session.send({ threadId, cwd, text: "hello" });
    await until(named("turn.done", threadId), from);
  }
  const workers = await Promise.all(["first", "second"].map(async (name) => Number(await readFile(join(cwd, `${name}.pid`), "utf8"))));
  assert.ok(workers.every(alive));
  first.close();
  await new Promise((resolve) => setTimeout(resolve, 300));
  // The second session in the folder may be using what the first left.
  assert.ok(workers.every(alive));
  second.close();
  assert.ok(await ended(workers[0]));
  assert.ok(await ended(workers[1]));
});

test("Cursor's models as Cursor names them, only Auto on the Free plan, and where it keeps a session", () => {
  const model = (id: string, name: string): Model => ({ id, name, description: "", efforts: [], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null });
  const listed = [model(auto, "Auto"), model("gpt-5.5[context=272k,reasoning=medium,fast=false]", "gpt-5.5"), model("gemini-3.1-pro[]", "gemini-3.1-pro")];
  assert.deepEqual(
    onPlan("Pro")(listed).map((model) => [model.id, model.name, model.description, model.efforts]),
    [
      [auto, "Auto", "", []],
      ["gpt-5.5[context=272k,reasoning=medium,fast=false]", "gpt-5.5", "context=272k, reasoning=medium, fast=false", []],
      ["gemini-3.1-pro[]", "gemini-3.1-pro", "", []],
    ],
  );
  assert.deepEqual(onPlan("Free")(listed).map((model) => model.name), ["Auto"]);
  assert.equal(onPlan(null)(listed).length, 3);
  assert.equal(cursorNamed(model("composer-2.5[fast=true]", "composer-2.5")).description, "fast=true");
  assert.equal(sessionFolder("9df7c551-c34e-427e-b2b3-5bbbb2837e10", "/Users/x"), "/Users/x/.cursor/acp-sessions/9df7c551-c34e-427e-b2b3-5bbbb2837e10");
  assert.throws(() => sessionFolder("../chats"), /isn't a session id/);
  assert.deepEqual([cursor.modes, cursor.levels, cursor.capabilities.modeLive, cursor.capabilities.resume], [["acceptEdits", "plan"], [], true, true]);
  assert.deepEqual([copilot.modes, copilot.levels], [["default", "plan", "bypassPermissions"], ["low", "medium", "high"]]);
});

test("Copilot's headless server says whether it's signed in and whether the account has a plan, and a token login isn't asked", async () => {
  const bin = await folder();
  const cli = join(bin, "copilot");
  const logFile = join(bin, "asked");
  await writeFile(cli, `#!/bin/sh\nexec "${process.execPath}" "${new URL("./fixtures/copilot-headless.ts", import.meta.url).pathname}" "$@"\n`);
  await chmod(cli, 0o755);
  const reading = async (account: string) => {
    await writeFile(logFile, "");
    const found = await availability(cli, { COPILOT_ACCOUNT: account, COPILOT_LOG: logFile });
    return [found, (await readFile(logFile, "utf8")).trim().split("\n")];
  };
  assert.deepEqual(await reading("noPlan"), [{ state: "noPlan", version: "1.0.86", hint: noPlan }, ["connect", "auth.getStatus", "account.getCurrentAuth"]]);
  assert.deepEqual(await reading("signedOut"), [{ state: "signedOut", version: "1.0.86", hint: "Run `copilot login` in Terminal." }, ["connect", "auth.getStatus"]]);
  assert.deepEqual(await reading("plan"), [{ state: "ready", version: "1.0.86", hint: null }, ["connect", "auth.getStatus", "account.getCurrentAuth"]]);
  // A login from a token in the environment comes back with its token, so it's never asked for.
  assert.deepEqual(await reading("token"), [{ state: "ready", version: "1.0.86", hint: null }, ["connect", "auth.getStatus"]]);
});
