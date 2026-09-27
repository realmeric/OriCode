// An Antigravity thread against a stand-in agy that scripts its stream, so nothing reaches Google.
import { chmod, mkdir, mkdtemp, readFile, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import { agentEnvironment } from "../acp.ts";
import { change } from "../agents.ts";
import { AntigravitySession, deniedOf, modeFlags, parseModels, route, stopReason, undo, viewOf, type AntigravityBinary } from "../antigravity.ts";
import { antigravityProvider } from "../antigravity-provider.ts";

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

const fixture = new URL("./fixtures/antigravity-cli.ts", import.meta.url).pathname;

/// A home whose agy settings choose `provider`, a folder holding hello.txt, and the stand-in's log.
async function standIn(provider?: string) {
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-agy-")));
  const home = join(cwd, "home");
  const settings = join(home, ".gemini/antigravity-cli/settings.json");
  await mkdir(join(home, ".gemini/antigravity-cli"), { recursive: true });
  await writeFile(settings, JSON.stringify(provider ? { colorScheme: "dark", modelProvider: provider } : { colorScheme: "dark" }));
  await writeFile(join(cwd, "hello.txt"), "zero\none\nend\n");
  const logFile = join(cwd, "agy.log");
  const logged = async () => {
    const text = await readFile(logFile, "utf8").catch(() => "");
    return text.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
  };
  return { cwd, home, settings, logFile, logged };
}

const sessions: AntigravitySession[] = [];
after(() => sessions.forEach((session) => session.close()));

/// A session on the stand-in, on the Gemini API with a key, as the provider would start it.
async function session(threadId: string) {
  const { cwd, home, logged } = await standIn("gemini");
  const binary: AntigravityBinary = { command: process.execPath, args: [fixture], env: { AGY_LOG: join(cwd, "agy.log"), HOME: home }, launch: async () => ({ GEMINI_API_KEY: "test-key" }) };
  const agy = new AntigravitySession(threadId, binary);
  sessions.push(agy);
  return { agy, binary, cwd, logged };
}

const starts = (logged: Record<string, any>[]) => logged.filter((entry) => entry.args);

test("a turn: one agy in the folder with stream-json both ways, its thinking, text and usage, the environment scrubbed", async () => {
  process.env.CLAUDE_CODE_MESSAGING_TOKEN = "not for other agents";
  const { agy, cwd, logged } = await session("hello");
  let from = events.length;
  assert.equal(await agy.send({ threadId: "hello", cwd, text: "hello", id: "m1", model: "gemini-3.8-flash-high" }), false);
  delete process.env.CLAUDE_CODE_MESSAGING_TOKEN;
  let done = await until(named("turn.done", "hello"), from);
  assert.deepEqual(told("hello", from).map((event) => event.event), ["message.taken", "turn.started", "thinking", "text", "text", "turn.done"]);
  const [, started, thinking, first, second] = told("hello", from);
  assert.equal(started.sessionId, "c-1");
  assert.equal(thinking.delta, "A greeting.");
  assert.equal(first.delta + second.delta, "Hi there.");
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "c-1");
  assert.deepEqual(done.usage, { input: 200, output: 10, cacheRead: 800, cacheWrite: 0 });

  // The next turn goes to the same agy, and counts only what it added.
  from = events.length;
  assert.equal(await agy.send({ threadId: "hello", cwd, text: "hello", id: "m2", model: "gemini-3.8-flash-high" }), false);
  done = await until(named("turn.done", "hello"), from);
  assert.deepEqual(told("hello", from).map((event) => event.event).slice(0, 2), ["message.taken", "turn.started"]);
  assert.deepEqual(done.usage, { input: 200, output: 10, cacheRead: 800, cacheWrite: 0 });
  const [start, ...rest] = starts(await logged());
  assert.equal(rest.length, 0);
  assert.deepEqual(start.args, ["--input-format", "stream-json", "--output-format", "stream-json", "--model", "gemini-3.8-flash-high"]);
  assert.equal(start.cwd, cwd);
  assert.deepEqual(start.env, []);
  assert.equal(start.key, "test-key");
  assert.equal(start.route, "gemini");
});

test("a turn in Accept edits starts agy with --mode accept-edits: a read, a refused command, an edit and a write with their hunks, and the refusal as a note", async () => {
  const { agy, cwd, logged } = await session("work");
  let from = events.length;
  await agy.send({ threadId: "work", cwd, text: "hello" });
  await until(named("turn.done", "work"), from);
  from = events.length;
  await agy.send({ threadId: "work", cwd, text: "work", permissionMode: "acceptEdits" });
  const done = await until(named("turn.done", "work"), from);
  assert.equal(done.stopReason, "end_turn");
  const said = told("work", from);
  const [read, readResult, run, runResult, edit, editResult, write, writeResult] = said.filter((event) => event.event.startsWith("tool."));
  assert.equal(read.kind, "read");
  assert.deepEqual(read.view, { path: join(cwd, "hello.txt") });
  assert.equal(readResult.content, "zero\none\nend\n");
  assert.equal(run.kind, "run");
  assert.deepEqual(run.view, { command: "npm test" });
  assert.deepEqual([runResult.isError, runResult.content], [true, "run_command requires approval that headless mode cannot prompt for."]);
  assert.equal(edit.kind, "edit");
  assert.deepEqual(edit.view, { path: join(cwd, "hello.txt") });
  assert.deepEqual(editResult.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-one", "+two", " end"] }]);
  assert.equal(write.kind, "write");
  assert.deepEqual(writeResult.patch, [{ oldStart: 0, newStart: 1, lines: ["+fresh"] }]);
  assert.equal(
    said.find((event) => event.event === "note")!.text,
    "Antigravity turned down run_command(npm test), since it can't ask in print mode. An allow rule under permissions.allow in ~/.gemini/antigravity-cli/settings.json lets it through.",
  );
  assert.equal(said.filter((event) => event.event === "text").map((event) => event.delta).join(""), "Done.");
  // The mode is a flag, so the second turn picked the conversation up in a new agy.
  const [first, second] = starts(await logged());
  assert.ok(!first.args.includes("--mode"));
  assert.deepEqual(second.args.slice(4), ["--mode", "accept-edits", "--conversation", "c-1"]);
});

test("an edit read too late is rebuilt from its own replacement", async () => {
  const { agy, cwd } = await session("late");
  await writeFile(join(cwd, "hello.txt"), "zero\ntwo\nend\n");
  const from = events.length;
  await agy.send({ threadId: "late", cwd, text: "late" });
  await until(named("turn.done", "late"), from);
  const result = told("late", from).find((event) => event.event === "tool.result")!;
  assert.deepEqual(result.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-two", "+three", " end"] }]);
});

test("a resume: a new session after a quit opens agy on the thread's conversation, and a lost one says so", async () => {
  const { agy, binary, cwd, logged } = await session("resume");
  let from = events.length;
  await agy.send({ threadId: "resume", cwd, text: "hello" });
  await until(named("turn.done", "resume"), from);
  agy.close();
  const reopened = new AntigravitySession("resume", binary);
  sessions.push(reopened);
  from = events.length;
  await reopened.send({ threadId: "resume", cwd, text: "hello", sessionId: "c-1" });
  assert.equal((await until(named("turn.done", "resume"), from)).sessionId, "c-1");
  assert.ok(!told("resume", from).some((event) => event.event === "session.lost"));
  const lost = new AntigravitySession("resume", binary);
  sessions.push(lost);
  from = events.length;
  await lost.send({ threadId: "resume", cwd, text: "hello", sessionId: "gone" });
  const done = await until(named("turn.done", "resume"), from);
  assert.deepEqual(told("resume", from).map((event) => event.event).slice(0, 2), ["session.lost", "turn.started"]);
  assert.equal(done.sessionId, "c-2");
  assert.deepEqual(starts(await logged()).map((start) => start.args.at(-1)), ["stream-json", "c-1", "gone"]);
});

test("a stop sends SIGINT, the turn ends interrupted, a message waiting on it is let go, and the next turn starts a new agy", async () => {
  const { agy, cwd, logged } = await session("stop");
  let from = events.length;
  await agy.send({ threadId: "stop", cwd, text: "wait" });
  await until(named("text", "stop"), from);
  assert.equal(await agy.send({ threadId: "stop", cwd, text: "next", id: "m2" }), true);
  await agy.interrupt();
  const done = await until(named("turn.done", "stop"), from);
  assert.equal(done.stopReason, "interrupted");
  assert.equal(done.waiting, 0);
  assert.deepEqual(told("stop", from).map((event) => event.event), ["turn.started", "text", "message.cancelled", "turn.done"]);
  assert.ok((await logged()).some((entry) => entry.signal === "SIGINT"));
  from = events.length;
  await agy.send({ threadId: "stop", cwd, text: "hello" });
  assert.equal((await until(named("turn.done", "stop"), from)).stopReason, "end_turn");
  assert.deepEqual(starts(await logged()).map((start) => start.args.at(-1)), ["stream-json", "c-1"]);
});

test("a message sent during a turn runs as the next one", async () => {
  const { agy, cwd } = await session("queue");
  const from = events.length;
  await agy.send({ threadId: "queue", cwd, text: "hello", id: "m1" });
  assert.equal(await agy.send({ threadId: "queue", cwd, text: "hello", id: "m2" }), true);
  const first = await until(named("turn.done", "queue"), from);
  assert.equal(first.waiting, 1);
  await until((event) => named("turn.done", "queue")(event) && event !== first, from);
  assert.deepEqual(told("queue", from).filter((event) => event.event === "message.taken").map((event) => event.messageId), ["m1", "m2"]);
});

test("a failed turn says why once: an AGY_ERROR and its ERROR result, an AGY_ERROR as agy exits 3, and agy missing", async () => {
  const { agy, cwd } = await session("fail");
  let from = events.length;
  await agy.send({ threadId: "fail", cwd, text: "fail" });
  let done = await until(named("turn.done", "fail"), from);
  assert.equal(done.stopReason, "error_during_execution");
  assert.deepEqual(told("fail", from).filter((event) => event.event === "error").map((event) => event.message), ["Gemini API quota exhausted for today."]);
  // agy warns and goes on in a stream-json session, so the next turn runs in the same one.
  from = events.length;
  await agy.send({ threadId: "fail", cwd, text: "hello" });
  assert.equal((await until(named("turn.done", "fail"), from)).stopReason, "end_turn");

  from = events.length;
  await agy.send({ threadId: "fail", cwd, text: "crash" });
  done = await until(named("turn.done", "fail"), from);
  assert.equal(done.stopReason, "error_during_execution");
  assert.deepEqual(told("fail", from).filter((event) => event.event === "error").map((event) => event.message), ["model unreachable"]);

  const missing = new AntigravitySession("missing", { command: join(cwd, "no-such-agy") });
  from = events.length;
  await missing.send({ threadId: "missing", cwd, text: "hello" });
  await until(named("turn.done", "missing"), from);
  assert.equal(told("missing", from)[0].message, "Antigravity isn't installed. Install it with `curl -fsSL https://antigravity.google/cli/install.sh | bash`.");
});

/// A stand-in agy on a chosen path, a stand-in `security` holding a Gemini key, and the provider
/// reading the settings the stand-in reads.
async function provider(settingsProvider: string | undefined, setting: { key?: boolean; allow?: string[] }, banned = false) {
  const made = await standIn(settingsProvider);
  const agy = join(made.cwd, "agy");
  await writeFile(agy, `#!/bin/sh\nexport AGY_LOG='${made.logFile}' HOME='${made.home}'${banned ? " AGY_BANNED=1" : ""}\nexec "${process.execPath}" "${fixture}" "$@"\n`);
  const security = join(made.cwd, "security");
  await writeFile(security, `#!/bin/sh\ncase "$*" in\n  "find-generic-password -s OriCode.antigravity -a antigravity -w") echo gemini-key-187 ;;\n  *) exit 44 ;;\nesac\n`);
  await Promise.all([chmod(agy, 0o755), chmod(security, 0o755)]);
  change("antigravity", true, { path: agy, ...setting });
  return { ...made, agy, provider: antigravityProvider({ security, settings: made.settings }) };
}

test("the Gemini API route: the key Settings keeps reaches agy's check, its models and each agy it starts, and no other process", async () => {
  const { agy, cwd, logged, provider: gemini } = await provider("gemini", { key: true });
  assert.deepEqual(await gemini.availability(), { state: "ready", cli: agy, version: "1.2.11", hint: null });
  assert.deepEqual(
    (await gemini.listModels!(agy)).map((model) => [model.id, model.name, model.efforts]),
    [
      ["gemini-3.8-flash-high", "Gemini 3.8 Flash (High)", []],
      ["gemini-3.1-pro-high", "Gemini 3.1 Pro (High)", []],
    ],
  );
  const thread = gemini.session("keyed", agy) as AntigravitySession;
  sessions.push(thread);
  const from = events.length;
  await thread.send({ threadId: "keyed", cwd, text: "hello", permissionMode: "default" });
  assert.equal((await until(named("turn.done", "keyed"), from)).stopReason, "end_turn");
  const runs = await logged();
  // The check's list served the menu, so `agy models` ran once.
  assert.deepEqual(runs.map((run) => [run.args?.[0] ?? null, run.route ?? null, run.key ?? null]).filter(([args]) => args !== null), [
    ["models", "gemini", "gemini-key-187"],
    ["--input-format", "gemini", "gemini-key-187"],
  ]);
  assert.equal(process.env.GEMINI_API_KEY, undefined);
  assert.equal(agentEnvironment().GEMINI_API_KEY, undefined);

  const { provider: keyless, logged: nothing } = await provider("gemini", {});
  assert.deepEqual(await keyless.availability(), { state: "signedOut", cli: (await keyless.found())!, version: null, hint: "Add your Gemini API key in Settings › Agents." });
  assert.deepEqual(await nothing(), []);
});

test("the Google account route: refused while its toggle is off, with agy never started, and asked only once it's on", async () => {
  const { agy, cwd, logged, provider: google } = await provider(undefined, { key: true }, true);
  const line =
    'Antigravity signs in with a Google account, which Google keeps to its own apps. Set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and add a Gemini API key here, or turn on “Antigravity with a Google account”.';
  assert.deepEqual(await google.availability(), { state: "signedOut", cli: agy, version: null, hint: line });
  await assert.rejects(google.listModels!(agy), { message: line });
  const thread = google.session("google", agy) as AntigravitySession;
  sessions.push(thread);
  await assert.rejects(thread.send({ threadId: "google", cwd, text: "hello" }), { message: line });
  assert.equal(thread.isRunning, false);
  assert.deepEqual(await logged(), []);

  // Turned on under Google's sentence, agy is asked, and Google answers as it answers this Mac.
  change("antigravity", true, { path: agy, key: true, allow: ["google"] });
  const found = await google.availability();
  assert.equal(found.state, "signedOut");
  assert.match(found.hint!, /^Eligibility check failed: PERMISSION_DENIED \(code 403\): This service has been disabled in this account for violation of Terms of Service/);
  // The Google route never gets the Gemini key.
  assert.deepEqual((await logged()).map((run) => [run.args[0], run.route, run.key]), [["models", "google", null]]);
});

test("routes, modes, stop reasons, views, refusals, model lists and a replacement undone", async () => {
  const { settings } = await standIn("gemini");
  assert.equal(await route(settings), "gemini");
  await writeFile(settings, '{"modelProvider": "vertex"}');
  assert.equal(await route(settings), "google");
  await writeFile(settings, "{ not json");
  assert.equal(await route(settings), "google");
  assert.equal(await route(join(settings, "missing")), "google");
  assert.deepEqual(modeFlags(undefined), []);
  assert.deepEqual(modeFlags("acceptEdits"), ["--mode", "accept-edits"]);
  assert.deepEqual(modeFlags("plan"), ["--mode", "plan"]);
  assert.equal(stopReason("SUCCESS"), "end_turn");
  assert.equal(stopReason("INTERRUPTED"), "interrupted");
  assert.equal(stopReason("CANCELED"), "interrupted");
  assert.equal(stopReason("WAITING"), "error_during_execution");
  assert.deepEqual(viewOf({ SearchPath: "/w", Query: "TODO" }), { path: "/w", pattern: "TODO" });
  assert.deepEqual(viewOf({ Url: "https://antigravity.google" }), { url: "https://antigravity.google" });
  assert.equal(deniedOf([]), undefined);
  assert.match(deniedOf([{ name: "run_command", target: "rm -rf build" }, "write_file(/etc/hosts)"])!, /^Antigravity turned down run_command\(rm -rf build\), write_file\(\/etc\/hosts\),.* lets them through\.$/);
  assert.deepEqual(parseModels("Fetching available models...\ngemini-3.8-flash-high Gemini 3.8 Flash (High)\n"), {
    models: [{ id: "gemini-3.8-flash-high", name: "Gemini 3.8 Flash (High)" }],
    error: null,
  });
  assert.deepEqual(parseModels("Fetching available models...\nError: not signed in\n"), { models: [], error: "not signed in" });
  assert.equal(undo("a $& b c", { ReplacementChunks: [{ TargetContent: "x", ReplacementContent: "$&" }, { TargetContent: "d", ReplacementContent: "c" }] }), "a x b d");
  assert.equal(undo("text", { TargetContent: "a", ReplacementContent: "" }), undefined);
});
