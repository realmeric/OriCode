// A Command Code thread against a stand-in cmd that scripts its frames, so nothing reaches a model.
import { chmod, mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { agentEnvironment } from "../acp.ts";
import { turnOn } from "../agents.ts";
import { CommandCodeSession, availability, listModels, modeFlags, parseModels, stopReason, undo, viewOf, type CommandCodeBinary } from "../commandcode.ts";
import { commandCode } from "../commandcode-provider.ts";

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

/// The stand-in as the user's cmd with a key, a folder of its own holding hello.txt, and the
/// runs it logged.
async function standIn(env: Record<string, string> = { COMMAND_CODE_API_KEY: "test-key" }) {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-cmd-")));
  const logFile = join(cwd, "cmd.log");
  await writeFile(join(cwd, "hello.txt"), "zero\none\nend\n");
  const binary: CommandCodeBinary = { command: process.execPath, args: [new URL("./fixtures/commandcode-cli.ts", import.meta.url).pathname], env: { CMD_LOG: logFile, ...env } };
  const runs = async () => (await readFile(logFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  return { binary, cwd, runs };
}

const sessions: CommandCodeSession[] = [];
after(() => sessions.forEach((session) => session.close()));

async function session(threadId: string, env?: Record<string, string>) {
  const { binary, cwd, runs } = await standIn(env);
  const session = new CommandCodeSession(threadId, binary);
  sessions.push(session);
  return { session, binary, cwd, runs };
}

test("a turn: one cmd in the folder, the prompt on stdin, Ask as dont-ask, its thinking, text and usage, the environment scrubbed", async () => {
  process.env.CLAUDE_CODE_MESSAGING_TOKEN = "not for other agents";
  const { session: cmd, cwd, runs } = await session("hello");
  const from = events.length;
  assert.equal(await cmd.send({ threadId: "hello", cwd, text: "hello", id: "m1", model: "deepseek/deepseek-v4-pro", effort: "high" }), false);
  delete process.env.CLAUDE_CODE_MESSAGING_TOKEN;
  const done = await until(named("turn.done", "hello"), from);
  const said = told("hello", from);
  assert.deepEqual(said.map((event) => event.event), ["message.taken", "turn.started", "thinking", "text", "turn.done"]);
  assert.deepEqual(said[0], { event: "message.taken", threadId: "hello", messageId: "m1", newTurn: true });
  assert.equal(said[1].sessionId, "s-1");
  assert.equal(said[2].delta, "A greeting.");
  assert.equal(said[3].delta, "Hi.");
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "s-1");
  assert.equal(done.waiting, 0);
  assert.deepEqual(done.usage, { input: 10, output: 7, cacheRead: 100, cacheWrite: 10 });
  const [run] = await runs();
  assert.deepEqual(run.args, ["-p", "--output-format", "json", "--permission-mode", "dont-ask", "--tools-enable", "todo_write", "--model", "deepseek/deepseek-v4-pro", "--effort", "high"]);
  assert.equal(run.prompt, "hello");
  assert.equal(run.cwd, cwd);
  assert.deepEqual(run.env, []);
  assert.equal(run.key, "test-key");
});

test("a turn in Don't ask runs with --yolo: a plan, a read, a command and an edit with its hunks", async () => {
  const { session: cmd, cwd, runs } = await session("work");
  const from = events.length;
  await cmd.send({ threadId: "work", cwd, text: "work", permissionMode: "bypassPermissions" });
  const done = await until(named("turn.done", "work"), from);
  assert.equal(done.stopReason, "end_turn");
  const [plan, planResult, read, readResult, ls, lsResult, edit, editResult] = told("work", from).filter((event) => event.event.startsWith("tool."));
  assert.equal(plan.name, "TodoWrite");
  assert.equal(plan.kind, "plan");
  assert.deepEqual(plan.view.todos, [
    { content: "Read the file", activeForm: "Reading the file", status: "completed" },
    { content: "Change it", activeForm: "Change it", status: "in_progress" },
  ]);
  assert.equal(planResult.content, "Todos updated.");
  assert.equal(read.kind, "read");
  assert.deepEqual(read.view, { path: join(cwd, "hello.txt") });
  assert.equal(readResult.content, "1\tone");
  assert.equal(ls.kind, "run");
  assert.deepEqual(ls.view, { command: "ls -la" });
  assert.deepEqual(lsResult, { event: "tool.result", threadId: "work", toolUseId: "t-ls", content: "hello.txt", isError: false });
  assert.equal(edit.name, "edit_file");
  assert.equal(edit.kind, "edit");
  assert.deepEqual(edit.view, { path: join(cwd, "hello.txt") });
  assert.equal(editResult.isError, false);
  assert.deepEqual(editResult.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-one", "+two", " end"] }]);
  const [run] = await runs();
  assert.ok(run.args.includes("--yolo"));
  assert.ok(!run.args.includes("--permission-mode"));
});

test("without --yolo the headless gate refuses the command and the edit, and says so", async () => {
  const { session: cmd, cwd } = await session("gated");
  const from = events.length;
  await cmd.send({ threadId: "gated", cwd, text: "work", permissionMode: "acceptEdits" });
  await until(named("turn.done", "gated"), from);
  const results = told("gated", from).filter((event) => event.event === "tool.result");
  const edit = results.find((event) => event.toolUseId === "t-edit")!;
  assert.equal(edit.isError, true);
  assert.equal(edit.patch, undefined);
  assert.match(edit.content, /requires permissions\. Use --yolo/);
  assert.equal(results.find((event) => event.toolUseId === "t-ls")!.isError, true);
  assert.equal(await readFile(join(cwd, "hello.txt"), "utf8"), "zero\none\nend\n");
});

test("an edit read too late is rebuilt from its own strings", async () => {
  const { session: cmd, cwd } = await session("late");
  await writeFile(join(cwd, "hello.txt"), "zero\ntwo\nend\n");
  const from = events.length;
  await cmd.send({ threadId: "late", cwd, text: "late", permissionMode: "bypassPermissions" });
  await until(named("turn.done", "late"), from);
  const result = told("late", from).find((event) => event.event === "tool.result")!;
  assert.deepEqual(result.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-two", "+three", " end"] }]);
});

test("a resume: the next turn resumes the session, a new session object picks it up after a quit, and a lost one starts afresh", async () => {
  const { session: cmd, binary, cwd, runs } = await session("resume");
  let from = events.length;
  await cmd.send({ threadId: "resume", cwd, text: "hello" });
  await until(named("turn.done", "resume"), from);
  from = events.length;
  await cmd.send({ threadId: "resume", cwd, text: "hello", permissionMode: "plan" });
  assert.equal((await until(named("turn.done", "resume"), from)).sessionId, "s-1");
  const reopened = new CommandCodeSession("resume", binary);
  sessions.push(reopened);
  from = events.length;
  await reopened.send({ threadId: "resume", cwd, text: "hello", sessionId: "s-1" });
  await until(named("turn.done", "resume"), from);
  from = events.length;
  const lost = new CommandCodeSession("resume", binary);
  sessions.push(lost);
  await lost.send({ threadId: "resume", cwd, text: "hello", sessionId: "gone" });
  const done = await until(named("turn.done", "resume"), from);
  assert.deepEqual(told("resume", from).map((event) => event.event), ["session.lost", "turn.started", "thinking", "text", "turn.done"]);
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "s-2");
  const logged = await runs();
  assert.deepEqual(logged.map((run) => (run.args.includes("--resume") ? run.args[run.args.indexOf("--resume") + 1] : null)), [null, "s-1", "s-1", "gone", null]);
  assert.deepEqual(logged[1].args.slice(3, 5), ["--permission-mode", "plan"]);
});

test("a stop sends SIGINT, the turn ends interrupted, and a message waiting on it is let go", async () => {
  const { session: cmd, cwd, runs } = await session("stop");
  const from = events.length;
  await cmd.send({ threadId: "stop", cwd, text: "wait" });
  await until(named("text", "stop"), from);
  assert.equal(await cmd.send({ threadId: "stop", cwd, text: "next", id: "m2" }), true);
  await cmd.interrupt();
  const done = await until(named("turn.done", "stop"), from);
  assert.equal(done.stopReason, "interrupted");
  assert.equal(done.sessionId, "s-1");
  assert.equal(done.waiting, 0);
  const said = told("stop", from);
  assert.deepEqual(said.map((event) => event.event), ["turn.started", "text", "message.cancelled", "turn.done"]);
  assert.ok((await runs()).some((entry) => entry.signal === "SIGINT"));
  assert.equal(cmd.isRunning, false);
});

test("a message sent during a turn runs as the next turn", async () => {
  const { session: cmd, cwd } = await session("queue");
  const from = events.length;
  await cmd.send({ threadId: "queue", cwd, text: "hello", id: "m1" });
  assert.equal(await cmd.send({ threadId: "queue", cwd, text: "hello", id: "m2" }), true);
  const first = await until(named("turn.done", "queue"), from);
  assert.equal(first.waiting, 1);
  await until((event) => named("turn.done", "queue")(event) && event !== first, from);
  const taken = told("queue", from).filter((event) => event.event === "message.taken");
  assert.deepEqual(taken.map((event) => [event.messageId, event.newTurn]), [["m1", true], ["m2", true]]);
});

test("a failed turn says why: cmd's error, no key, a crash with no result, a refused call that ends the run", async () => {
  const { session: limited, cwd } = await session("limit");
  let from = events.length;
  await limited.send({ threadId: "limit", cwd, text: "limit" });
  let done = await until(named("turn.done", "limit"), from);
  assert.equal(done.stopReason, "error_during_execution");
  assert.equal((await until(named("error", "limit"), from)).message, "Rate limit exceeded. Please wait a moment and try again.");

  const { session: keyless, cwd: keylessCwd } = await session("keyless", {});
  from = events.length;
  await keyless.send({ threadId: "keyless", cwd: keylessCwd, text: "hello" });
  done = await until(named("turn.done", "keyless"), from);
  assert.deepEqual(told("keyless", from).map((event) => event.event), ["error", "turn.done"]);
  assert.equal(told("keyless", from)[0].message, "Command Code has no working API key. Add yours in Settings › Agents.");
  assert.equal(done.sessionId, undefined);

  const { session: crashed, cwd: crashCwd } = await session("crash");
  from = events.length;
  await crashed.send({ threadId: "crash", cwd: crashCwd, text: "crash" });
  done = await until(named("turn.done", "crash"), from);
  assert.equal(done.stopReason, "error_during_execution");
  assert.equal((await until(named("error", "crash"), from)).message, "Command Code stopped: boom: the model client fell over");

  const { session: risky, cwd: riskyCwd } = await session("risky");
  from = events.length;
  await risky.send({ threadId: "risky", cwd: riskyCwd, text: "risky", permissionMode: "bypassPermissions" });
  done = await until(named("turn.done", "risky"), from);
  assert.equal(done.stopReason, "error_during_execution");
  const refused = told("risky", from).find((event) => event.event === "tool.result")!;
  assert.deepEqual([refused.toolUseId, refused.isError, refused.content], ["t-rm", true, "Refused in this thread's mode."]);
  assert.equal((await until(named("error", "risky"), from)).message, "Command Code stopped at a call it holds too risky to make unasked.");
});

test("cmd missing: a send says how to install it, and availability says it's missing", async () => {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-cmd-")));
  const binary = { command: join(cwd, "no-such-cmd") };
  const cmd = new CommandCodeSession("missing", binary);
  const from = events.length;
  await cmd.send({ threadId: "missing", cwd, text: "hello" });
  const done = await until(named("turn.done", "missing"), from);
  assert.equal(done.stopReason, "error_during_execution");
  assert.equal(told("missing", from)[0].message, "Command Code isn't installed. Install it with `npm i -g command-code`.");
  assert.deepEqual(await availability(binary), { state: "missing", version: null, hint: "Command Code isn't installed. Install it with `npm i -g command-code`." });
});

test("availability: ready with a key, and the Settings line without one", async () => {
  const { binary } = await standIn();
  assert.deepEqual(await availability(binary), { state: "ready", version: "1.66.0", hint: null });
  const { binary: keyless } = await standIn({});
  assert.deepEqual(await availability(keyless), { state: "signedOut", version: "1.66.0", hint: "Command Code has no working API key. Add yours in Settings › Agents." });
});

test("the model list: each model under its maker, the default marked, the decision models left out", async () => {
  const { binary } = await standIn();
  const models = await listModels(binary);
  assert.deepEqual(models, [
    { id: "deepseek/deepseek-v4-pro", description: "hybrid-attention long-context reasoning", group: "Open Source", isDefault: false },
    { id: "deepseek/deepseek-v4-flash", description: "fast hybrid-attention reasoning", group: "Open Source", isDefault: true },
    { id: "inclusionai/ling-3.0-flash-sante:free", description: "FREE health & medicine tuned lightweight-MoE, still strong on code", group: "Open Source", isDefault: false },
    { id: "claude-sonnet-5", description: "best combo of speed & intelligence (recommended)", group: "Anthropic", isDefault: false },
  ]);
  assert.deepEqual(parseModels(""), []);
});

test("modes, stop reasons, views and an edit undone", () => {
  assert.deepEqual(modeFlags(undefined), ["--permission-mode", "dont-ask"]);
  assert.deepEqual(modeFlags("default"), ["--permission-mode", "dont-ask"]);
  assert.deepEqual(modeFlags("acceptEdits"), ["--permission-mode", "accept-edits"]);
  assert.deepEqual(modeFlags("auto"), ["--permission-mode", "default"]);
  assert.deepEqual(modeFlags("plan"), ["--permission-mode", "plan"]);
  assert.deepEqual(modeFlags("bypassPermissions"), ["--yolo"]);
  assert.equal(stopReason({ subtype: "success", stopReason: "end_turn" }), "end_turn");
  assert.equal(stopReason({ subtype: "success", stopReason: "stop_hook" }), "end_turn");
  assert.equal(stopReason({ subtype: "max_turns", stopReason: "max_turns" }), "error_max_turns");
  assert.equal(stopReason({ subtype: "success", stopReason: "max_tokens" }), "max_tokens");
  assert.equal(stopReason({ subtype: "error" }), "error_during_execution");
  assert.deepEqual(viewOf("read_file", { paths: ["/a.ts", "/b.ts"] }), { path: "/a.ts" });
  assert.deepEqual(viewOf("grep", { pattern: "TODO", path: "/w" }), { path: "/w", pattern: "TODO" });
  assert.deepEqual(viewOf("web_fetch", { url: "https://commandcode.ai" }), { url: "https://commandcode.ai" });
  assert.equal(undo("a $& b", { old_string: "x", new_string: "$&" }), "a x b");
  assert.equal(undo("new new", { old_string: "old", new_string: "new", replace_all: true }), "old old");
  assert.equal(undo("text", { old_string: "a", new_string: "" }), undefined);
});

test("the key Settings keeps reaches each cmd the provider starts, read as it starts, and no other process", async () => {
  const folder = await realpath(await mkdtemp(join(tmpdir(), "oricode-cmd-key-")));
  const logFile = join(folder, "cmd.log");
  const keyFile = join(folder, "key");
  const cmd = join(folder, "cmd");
  await writeFile(cmd, `#!/bin/sh\nexport CMD_LOG='${logFile}'\nexec "${process.execPath}" "${new URL("./fixtures/commandcode-cli.ts", import.meta.url).pathname}" "$@"\n`);
  const security = join(folder, "security");
  // The key as the login Keychain holds it now, which Settings may change between turns.
  await writeFile(security, `#!/bin/sh\ncase "$*" in\n  "find-generic-password -s OriCode.commandcode -a commandcode -w") cat "${keyFile}" ;;\n  *) exit 44 ;;\nesac\n`);
  await Promise.all([chmod(cmd, 0o755), chmod(security, 0o755)]);
  await writeFile(keyFile, "cc-key-190\n");
  turnOn({ commandcode: { key: true, path: cmd } });
  const provider = commandCode({ security });

  assert.deepEqual(await provider.availability(), { state: "ready", cli: cmd, version: "1.66.0", hint: null });
  assert.equal((await provider.listModels!(cmd))[0].id, "deepseek/deepseek-v4-flash");
  await provider.listModels!(cmd);
  const session = provider.session("keyed", cmd);
  sessions.push(session as CommandCodeSession);
  let from = events.length;
  await session.send({ threadId: "keyed", cwd: folder, text: "hello", permissionMode: "default" });
  await until(named("turn.done", "keyed"), from);
  await writeFile(keyFile, "cc-key-190-new\n");
  from = events.length;
  await session.send({ threadId: "keyed", cwd: folder, text: "hello", permissionMode: "default" });
  assert.equal((await until(named("turn.done", "keyed"), from)).stopReason, "end_turn");

  const runs = (await readFile(logFile, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(runs.map((run) => [run.args[0], run.key]), [["--list-models", "cc-key-190"], ["-p", "cc-key-190"], ["-p", "cc-key-190-new"]]);
  assert.equal(process.env.COMMAND_CODE_API_KEY, undefined);
  assert.equal(agentEnvironment().COMMAND_CODE_API_KEY, undefined);
});
