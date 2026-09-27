// A Devin thread against a stand-in `devin` that speaks ACP as devin 3000.11.3 does, through
// main.ts's registration, so nothing reaches a model or Cognition.
import { mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { reach } from "../devin.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

/// Devin as hello lists it, in the state it found it.
function devinEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "devin",
    name: "Devin",
    agent: "Devin",
    state,
    hint,
    cli: cliPath,
    version: cliVersion,
    capabilities: {
      steer: false,
      resume: true,
      modeLive: true,
      attachments: true,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: true,
      compact: false,
      commitMessage: false,
      handoff: "devin --resume {session}",
      workers: true,
    },
    levels: [],
    modes: ["acceptEdits", "plan", "bypassPermissions"],
  };
}

async function logged(file: string): Promise<any[]> {
  return (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
}

test("signed out, Devin says `devin auth login`, and its browser sign-in is never started", async (t) => {
  const { bin, env } = await sandbox();
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-devin-")));
  const log = join(cwd, "devin.log");
  const devin = await standInCli(bin, "devin", "devin-agent.ts", { DEVIN_LOG: log });
  const engine = engineWith(env);
  t.after(engine.kill);

  const hello = await engine.request("hello", { agents: { devin: {} } });
  assert.deepEqual(hello.result.providers[1], devinEntry("unknown", devin, null, null));
  const checked = await engine.request("provider.check", { provider: "devin" });
  assert.deepEqual(checked.result, devinEntry("signedOut", devin, "devin 3000.11.3 (9c803229faa4)", "Run `devin auth login` in Terminal."));

  const from = engine.lines.length;
  await engine.request("send", { threadId: "k185-out", cwd, text: "hello", permissionMode: "acceptEdits", provider: "devin" });
  // Devin's own words send the user to a /login its REPL has; the thread says the Terminal line.
  assert.equal((await engine.until((line) => line.event === "error", from)).message, "Run `devin auth login` in Terminal.");
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "error_during_execution");
  await engine.end();

  const sent = await logged(log);
  assert.deepEqual(sent.filter((message) => message.method === "authenticate"), []);
  // OriCode's own name, which Devin answers.
  assert.deepEqual(sent.find((message) => message.method === "initialize").params.clientInfo.name, "oricode");
});

test("a Devin thread through the engine: checked ready, its models, a turn with an ask and an edit, Stop, and a pick-up", async (t) => {
  const { bin, env } = await sandbox();
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-devin-")));
  await writeFile(join(cwd, "hello.txt"), "zero\none\nend\n");
  const log = join(cwd, "devin.log");
  const devin = await standInCli(bin, "devin", "devin-agent.ts", { DEVIN_LOG: log, DEVIN_LOGIN: "1" });
  const engine = engineWith(env);
  t.after(engine.kill);

  await engine.request("hello", { agents: { devin: {} } });
  const checked = await engine.request("provider.check", { provider: "devin" });
  assert.deepEqual(checked.result, devinEntry("ready", devin, "devin 3000.11.3 (9c803229faa4)", null));
  const told = await engine.until((line) => line.event === "models");
  assert.equal(told.provider, "devin");
  const listed = (await engine.request("models.list", { provider: "devin" })).result.models;
  assert.deepEqual(
    listed.map((model: any) => [model.id, model.name, model.efforts]),
    [
      ["swe-1-6-fast", "SWE-1.6 Fast", []],
      ["adaptive", "Adaptive", []],
      ["claude-opus-4-7", "Claude Opus 4.7", []],
    ],
  );

  let from = engine.lines.length;
  const send = { threadId: "k185", cwd, text: "work", model: "claude-opus-4-7", permissionMode: "acceptEdits", provider: "devin" };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  const run = await engine.until((line) => line.event === "ask", from);
  assert.equal(run.toolKind, "run");
  assert.deepEqual(run.choices.map((choice: { id: string; kind: string }) => [choice.id, choice.kind]), [
    ["allow_once", "allow_once"],
    ["allow_session", "allow_always"],
    ["reject_once", "reject_once"],
  ]);
  await engine.request("answer", { requestId: run.requestId, allow: true, optionId: "allow_session" });
  const done = await engine.until((line) => line.event === "turn.done", from);
  assert.equal(done.stopReason, "end_turn");
  const sessionId = done.sessionId;
  assert.equal(sessionId, "mirage-robin");
  const edit = engine.lines.slice(from).find((line) => line.event === "tool.result" && line.toolUseId === "tc-edit");
  assert.deepEqual(edit.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-one", "+two", " end"] }]);
  assert.equal(engine.lines.slice(from).filter((line) => line.event === "ask").length, 1);
  const plan = engine.lines.slice(from).find((line) => line.event === "tool.use" && line.kind === "plan");
  assert.deepEqual(plan.input.todos.map((todo: { content: string }) => todo.content), ["Run echo", "Edit hello.txt"]);

  // Don't ask reaches the same process as Bypass Permissions, which runs the command unasked; Stop ends it.
  from = engine.lines.length;
  assert.deepEqual((await engine.request("setMode", { threadId: "k185", permissionMode: "bypassPermissions" })).result, { applied: true });
  await engine.request("send", { ...send, sessionId, text: "wait", permissionMode: "bypassPermissions" });
  await engine.until((line) => line.event === "tool.use" && line.toolUseId === "tc-sleep", from);
  await engine.request("interrupt", { threadId: "k185" });
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "interrupted");
  assert.equal(engine.lines.slice(from).filter((line) => line.event === "ask").length, 0);
  await engine.end();

  // After a quit, the thread loads its session, whose replay isn't shown again, in Plan.
  const again = engineWith(env);
  t.after(again.kill);
  await again.request("hello", { agents: { devin: {} } });
  from = again.lines.length;
  await again.request("send", { ...send, sessionId, text: "hello", permissionMode: "plan" });
  assert.equal((await again.until((line) => line.event === "turn.done", from)).sessionId, sessionId);
  assert.deepEqual(again.lines.slice(from).filter((line) => line.event === "text").map((line) => line.delta), ["Hi."]);
  await again.end();

  const sent = await logged(log);
  const starts = sent.filter((message) => message.argv);
  // The models event and models.list each start one; then a process for the first engine's turns and one after the quit.
  assert.equal(starts.length, 4);
  assert.ok(starts.every((start) => start.argv.join(" ") === "acp" && start.claude.length === 0));
  assert.ok(sent.filter((message) => message.method === "initialize").every((message) => message.params.clientInfo.name === "oricode"));
  assert.deepEqual(sent.filter((message) => message.method === "authenticate"), []);
  assert.deepEqual(
    sent.filter((message) => message.method === "session/set_config_option").map((message) => `${message.params.configId}=${message.params.value}`),
    ["model=claude-opus-4-7", "mode=bypass", "mode=plan", "model=claude-opus-4-7"],
  );
  assert.deepEqual(sent.filter((message) => message.method === "session/load").map((message) => message.params.sessionId), [sessionId]);
  assert.deepEqual(sent.filter((message) => message.answered).map((message) => message.answered.outcome.optionId), ["allow_session"]);
  assert.equal(sent.filter((message) => message.method === "session/cancel").length, 1);
});

test("Devin's modes by a thread's", () => {
  assert.deepEqual(["acceptEdits", "plan", "bypassPermissions"].map((mode) => reach(mode).mode), ["accept-edits", "plan", "bypass"]);
});
