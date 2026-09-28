// A Grok Build thread against a stand-in `grok` that speaks ACP as grok 1.0.41 does, through
// main.ts's registration, so nothing reaches a model or xAI.
import { mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { AcpSession, listModels } from "../acp.ts";
import { diffHunks } from "../acp-map.ts";
import { reach } from "../grok.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

/// Grok Build as hello lists it, in the state it found it.
function grokEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "grok",
    name: "Grok Build",
    agent: "Grok",
    state,
    hint,
    cli: cliPath,
    version: cliVersion,
    capabilities: {
      steer: false,
      resume: true,
      modeLive: false,
      attachments: false,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: true,
      compact: false,
      commitMessage: false,
      handoff: "grok --resume {session}",
      workers: false,
    },
    levels: ["low", "medium", "high", "xhigh"],
    modes: ["default", "plan", "bypassPermissions"],
  };
}

async function logged(file: string): Promise<any[]> {
  return (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
}

test("signed out, Grok Build says `grok login` and never takes a key, even with XAI_API_KEY set", async (t) => {
  const { bin, env } = await sandbox();
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-grok-")));
  const log = join(cwd, "grok.log");
  const grok = await standInCli(bin, "grok", "grok-agent.ts", { GROK_LOG: log });
  const engine = engineWith({ ...env, XAI_API_KEY: "xai-from-the-shell" });
  t.after(engine.kill);

  const hello = await engine.request("hello", { agents: { grok: {} } });
  assert.deepEqual(hello.result.providers[1], grokEntry("unknown", grok, null, null));
  const checked = await engine.request("provider.check", { provider: "grok" });
  assert.deepEqual(checked.result, grokEntry("signedOut", grok, "grok 1.0.41 (4220f3b224a6)", "Run `grok login` in Terminal."));

  const from = engine.lines.length;
  await engine.request("send", { threadId: "k184-out", cwd, text: "hello", permissionMode: "default", provider: "grok" });
  const error = await engine.until((line) => line.event === "error", from);
  assert.equal(error.message, "Run `grok login` in Terminal.");
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "error_during_execution");
  await engine.end();

  const sent = await logged(log);
  // Offered only grok.com, which would open a browser, OriCode asks for no sign-in at all.
  assert.deepEqual(sent.filter((message) => message.method === "authenticate"), []);
  assert.ok(sent.filter((message) => message.argv).every((start) => start.disabled === "1"));
});

test("a Grok Build thread through the engine: checked ready, its models, a turn with asks and an edit, Stop, and a pick-up", async (t) => {
  const { bin, env } = await sandbox();
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-grok-")));
  await writeFile(join(cwd, "hello.txt"), "zero\none\nend\n");
  const log = join(cwd, "grok.log");
  const grok = await standInCli(bin, "grok", "grok-agent.ts", { GROK_LOG: log, GROK_LOGIN: "1" });
  const engine = engineWith(env);
  t.after(engine.kill);

  await engine.request("hello", { agents: { grok: {} } });
  const checked = await engine.request("provider.check", { provider: "grok" });
  assert.deepEqual(checked.result, grokEntry("ready", grok, "grok 1.0.41 (4220f3b224a6)", null));
  const told = await engine.until((line) => line.event === "models");
  assert.equal(told.provider, "grok");
  const listed = (await engine.request("models.list", { provider: "grok" })).result.models;
  // Grok's default first, each with the levels its model says, and none for one without reasoning.
  assert.deepEqual(
    listed.map((model: any) => [model.id, model.name, model.efforts]),
    [
      ["grok-4.6", "Grok 4.6", ["low", "medium", "high", "xhigh"]],
      ["grok-4.5", "Grok 4.5", ["low", "medium", "high"]],
      ["grok-code-fast-1", "Grok Code Fast", []],
    ],
  );

  let from = engine.lines.length;
  const send = { threadId: "k184", cwd, text: "work", model: "grok-4.5", effort: "medium", permissionMode: "default", provider: "grok" };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  const run = await engine.until((line) => line.event === "ask", from);
  assert.equal(run.toolKind, "run");
  assert.equal(run.view.command, "echo hi");
  assert.deepEqual(run.choices.map((choice: { id: string }) => choice.id), ["always-allow", "allow-once", "reject-once", "reject-always"]);
  await engine.request("answer", { requestId: run.requestId, allow: true });
  const edit = await engine.until((line) => line.event === "ask" && line.requestId !== run.requestId, from);
  assert.equal(edit.toolKind, "edit");
  assert.equal(edit.view.path, join(cwd, "hello.txt"));
  await engine.request("answer", { requestId: edit.requestId, allow: true, optionId: "allow-edits-session" });
  const done = await engine.until((line) => line.event === "turn.done", from);
  assert.equal(done.stopReason, "end_turn");
  const sessionId = done.sessionId;
  assert.equal(sessionId, "019a0e24-0000-7000-8000-000000000001");
  const result = engine.lines.slice(from).find((line) => line.event === "tool.result" && line.toolUseId === "call_edit");
  // At the line Grok says it matched, not line 1.
  assert.deepEqual(result.patch, [{ oldStart: 2, newStart: 2, lines: ["-one", "+two"] }]);
  const plan = engine.lines.slice(from).find((line) => line.event === "tool.use" && line.kind === "plan");
  assert.deepEqual(plan.input.todos.map((todo: { content: string }) => todo.content), ["Run echo", "Edit hello.txt"]);

  // Don't ask starts Grok again as always-approve, which runs the command unasked; Stop ends it.
  from = engine.lines.length;
  await engine.request("send", { ...send, sessionId, text: "wait", permissionMode: "bypassPermissions" });
  await engine.until((line) => line.event === "tool.use" && line.toolUseId === "call_sleep", from);
  await engine.request("interrupt", { threadId: "k184" });
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "interrupted");
  assert.equal(engine.lines.slice(from).filter((line) => line.event === "ask").length, 0);
  await engine.end();

  // After a quit, the thread picks up its session without it being replayed, in Plan.
  const again = engineWith(env);
  t.after(again.kill);
  await again.request("hello", { agents: { grok: {} } });
  from = again.lines.length;
  await again.request("send", { ...send, sessionId, text: "hello", permissionMode: "plan" });
  const picked = await again.until((line) => line.event === "turn.done", from);
  assert.equal(picked.sessionId, sessionId);
  assert.deepEqual(again.lines.slice(from).filter((line) => line.event === "text").map((line) => line.delta), ["Hi."]);
  await again.end();

  const sent = await logged(log);
  const starts = sent.filter((message) => message.argv);
  // The check, the models event and models.list each start one to read; then the three turns.
  assert.deepEqual(
    starts.slice(-3).map((start) => start.argv),
    [
      ["--permission-mode", "default", "--no-auto-update", "agent", "stdio"],
      ["--permission-mode", "bypassPermissions", "--no-auto-update", "agent", "stdio"],
      ["--permission-mode", "default", "--no-auto-update", "agent", "stdio"],
    ],
  );
  assert.ok(starts.every((start) => start.disabled === "1" && start.claude.length === 0));
  assert.deepEqual([...new Set(sent.filter((message) => message.method === "authenticate").map((message) => message.params.methodId))], ["cached_token"]);
  // Each process starts on Grok's default, so each turn sets the thread's model and level.
  const configured = sent.filter((message) => message.method === "session/set_config_option").map((message) => `${message.params.configId}=${message.params.value}`);
  assert.deepEqual(configured, ["model=grok-4.5", "reasoning_effort=medium", "model=grok-4.5", "reasoning_effort=medium", "model=grok-4.5", "reasoning_effort=medium"]);
  // Picked up by the always-approve process and after the quit.
  assert.deepEqual(sent.filter((message) => message.method === "session/resume").map((message) => message.params.sessionId), [sessionId, sessionId]);
  assert.deepEqual(sent.filter((message) => message.method === "session/set_mode").map((message) => message.params.modeId), ["default", "default", "plan"]);
  assert.deepEqual(sent.filter((message) => message.answered).map((message) => message.answered.outcome.optionId), ["allow-once", "allow-edits-session"]);
  assert.equal(sent.filter((message) => message.method === "session/cancel").length, 1);
});

test("Grok's catalog notification reaches the models a thread lists", async (t) => {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-grok-")));
  const session = new AcpSession("catalog", {
    name: "Grok Build",
    command: process.execPath,
    args: [new URL("./fixtures/grok-agent.ts", import.meta.url).pathname],
    env: { GROK_LOGIN: "1" },
    authMethod: "cached_token",
    unlistedModes: ["default", "plan"],
  });
  t.after(() => session.close());
  // The session's events go to stdout, where the test runner reports too; this test reads none.
  const write = process.stdout.write.bind(process.stdout);
  process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) =>
    typeof chunk === "string" && chunk.startsWith('{"event"') ? true : write(chunk, ...rest)) as typeof process.stdout.write;
  t.after(() => (process.stdout.write = write));
  await session.send({ threadId: "catalog", cwd, text: "catalog" });
  while (session.isRunning) await new Promise((resolve) => setTimeout(resolve, 10));
  const { current, models } = listModels(session);
  assert.equal(current, "grok-4.6");
  assert.deepEqual(
    models.map((model) => [model.id, model.levels]),
    [
      ["grok-4.7", ["xhigh", "high", "low"]],
      ["grok-4.6", ["xhigh", "high", "medium", "low"]],
      ["grok-4.5", ["high", "medium", "low"]],
      ["grok-code-fast-1", []],
    ],
  );
});

test("Grok's modes: Ask and Plan share a process, Don't ask starts it as always-approve", () => {
  assert.deepEqual(reach("default"), { mode: "default", args: ["--permission-mode", "default"] });
  assert.deepEqual(reach("plan"), { mode: "plan", args: ["--permission-mode", "default"] });
  assert.deepEqual(reach("bypassPermissions"), { mode: "default", args: ["--permission-mode", "bypassPermissions"] });
});

test("an edit Grok places in its _meta starts at that line; one in several places, or none, from line 1", () => {
  const diff = { type: "diff" as const, path: "/w/a.swift", oldText: "let a = 1", newText: "let a = 2" };
  assert.deepEqual(diffHunks({ ...diff, _meta: { details: [{ old_line: 40, new_line: 41, line_prefix: "    " }] } }), [
    { oldStart: 40, newStart: 41, lines: ["-    let a = 1", "+    let a = 2"] },
  ]);
  const twice = { details: [{ old_line: 3, new_line: 3 }, { old_line: 9, new_line: 9 }] };
  assert.deepEqual(diffHunks({ ...diff, _meta: twice }), [{ oldStart: 1, newStart: 1, lines: ["-let a = 1", "+let a = 2"] }]);
  assert.deepEqual(diffHunks(diff), [{ oldStart: 1, newStart: 1, lines: ["-let a = 1", "+let a = 2"] }]);
});
