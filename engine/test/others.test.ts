// Threads at work in one project: what each hears of the others, and the hold on an edit, through
// the events every session writes, a Thread on a stand-in CLI, and the real engine on a stand-in
// Codex. Nothing reaches a model.
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { Thread } from "../thread.ts";
import { atStart, atStep, gone, heard, hold, noteGap, rested, working } from "../others.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

const place = (title: string, project = "P", branch?: string) => ({ project, title, ...(branch ? { branch } : {}) });

/// A thread's edit of `file` called and come back, its turn's business from here on.
function edit(thread: string, file: string, call = `${thread}-${file}`, isError = false): void {
  heard("tool.use", { threadId: thread, toolUseId: call, name: "Edit", input: { file_path: file } });
  heard("tool.result", { threadId: thread, toolUseId: call, isError });
}

test("a thread alone hears nothing and is held on nothing", (t) => {
  t.after(() => gone("alone"));
  working("alone", place("Alone"), "/w", true);
  edit("alone", "/w/a.txt");
  assert.equal(atStart("alone"), undefined);
  assert.equal(atStep("alone"), undefined);
  assert.equal(hold("alone", "/w/a.txt"), undefined);
});

test("a session the app didn't place takes no part", () => {
  assert.equal(atStart("worker"), undefined);
  assert.equal(atStep("worker"), undefined);
  assert.equal(hold("worker", "/w/a.txt"), undefined);
});

test("the note says who works here, where, on what and what they edited, and how to reach them", (t) => {
  t.after(() => ["n1", "n2", "n3"].forEach(gone));
  working("n1", place("Me"), "/w", true);
  working("n2", place("Fix the drawer"), "/w", true);
  working("n3", place("Tidy threads", "P", "oricode/t-1"), "/w/.worktrees/t-1", true);
  edit("n2", "/w/App/Drawer.swift");
  heard("tool.use", { threadId: "n2", toolUseId: "b", name: "Bash", input: { command: "make test\nmore" } });
  edit("n3", "/w/.worktrees/t-1/engine/plan.ts");
  edit("n3", "/w/.worktrees/t-1/App/Drawer.swift");
  edit("n1", "/w/App/Drawer.swift");
  assert.equal(
    atStart("n1"),
    '[OriCode] 2 other threads are working in this project. message_thread reaches one.\n' +
      '"Fix the drawer" (id n2), shares your folder, at Bash make test, you both edited App/Drawer.swift\n' +
      '"Tidy threads" (id n3), on branch oricode/t-1, at Edit App/Drawer.swift, edited engine/plan.ts, you both edited App/Drawer.swift, which merging will meet',
  );
});

test("a thread in another project isn't company, and a thread with no tools isn't told of message_thread", (t) => {
  t.after(() => ["q1", "q2", "q3"].forEach(gone));
  working("q1", place("Me", "Q"), "/w", false);
  working("q2", place("Elsewhere", "R"), "/w", true);
  assert.equal(atStart("q1"), undefined);
  working("q3", place("Here", "Q"), "/x", true);
  assert.equal(atStart("q1"), '[OriCode] Another thread is working in this project.\n"Here" (id q3), in /x');
});

test("the note stays within its cap and says how many it left out, those whose work meets this thread's first", (t) => {
  const ids = Array.from({ length: 12 }, (_, index) => `FFFFFFFF-0000-4000-8000-${String(index).padStart(12, "0")}`);
  t.after(() => ["me", ...ids].forEach(gone));
  working("me", place("Me"), "/w", true);
  for (const [index, id] of ids.entries()) {
    working(id, place(`A very long title of a thread that goes on and on, number ${index}`, "P", `oricode/t-${index}`), index === 11 ? "/w" : `/w/.worktrees/${index}`, true);
    for (let file = 0; file < 50; file++) edit(id, `${index === 11 ? "/w" : `/w/.worktrees/${index}`}/App/Some/Quite/Deep/Folder/File${file}.swift`);
  }
  const note = atStart("me")!;
  assert.ok(note.length <= 500, `${note.length} characters`);
  assert.match(note, /And \d+ more: list_threads names them\.$/);
  assert.match(note.split("\n")[1], /shares your folder/);
  assert.match(note, /and 47 more/);
});

test("mid-turn a note comes at a step when something changed, no sooner than the gap after the last", (t) => {
  t.after(() => ["s1", "s2", "s3"].forEach(gone));
  working("s1", place("Me"), "/w", true);
  // Nobody to tell of: its first note comes as soon as there is.
  const clock = Date.now();
  assert.equal(atStart("s1", clock), undefined);
  working("s2", place("Two"), "/x", true);
  assert.match(atStep("s1", clock + 1)!, /"Two" \(id s2\)/);
  assert.equal(atStep("s1", clock + 2), undefined, "nothing has changed");
  edit("s2", "/x/a.txt");
  assert.equal(atStep("s1", clock + noteGap), undefined, "a new file waits out the gap");
  assert.match(atStep("s1", clock + 1 + noteGap)!, /edited a\.txt/);
  assert.equal(atStep("s1", clock + 2 + noteGap), undefined);
  // What another thread is at changes all the time, and isn't news.
  heard("tool.use", { threadId: "s2", toolUseId: "r", name: "Read", input: { file_path: "/x/b.txt" } });
  assert.equal(atStep("s1", clock + 3 * noteGap), undefined);
  working("s3", place("Three"), "/y", true);
  assert.match(atStep("s1", clock + 3 * noteGap)!, /2 other threads/);
  // One ending is news; the last ending leaves it alone, and alone hears nothing.
  heard("turn.done", { threadId: "s3" });
  assert.doesNotMatch(atStep("s1", clock + 4 * noteGap)!, /Three/);
  heard("turn.done", { threadId: "s2" });
  assert.equal(atStep("s1", clock + 5 * noteGap), undefined);
});

test("a thread's start tells it whatever the gap, and a thread woken by no send counts from turn.started", (t) => {
  t.after(() => ["w1", "w2"].forEach(gone));
  working("w1", place("Me"), "/w", true);
  working("w2", place("Two"), "/x", true);
  assert.ok(atStart("w1", 1_000));
  assert.ok(atStart("w1", 1_001));
  heard("turn.done", { threadId: "w2" });
  assert.equal(atStart("w1", 1_002), undefined);
  heard("turn.started", { threadId: "w2" });
  assert.ok(atStart("w1", 1_003));
});

test("the first attempt on a file another thread here edited is held, naming it, and the second goes through", (t) => {
  t.after(() => ["h1", "h2"].forEach(gone));
  working("h1", place("Me"), "/w", true);
  working("h2", place("Fix the drawer"), "/w", true);
  edit("h2", "/w/App/Drawer.swift");
  assert.equal(hold("h1", "/w/App/Other.swift"), undefined);
  assert.equal(
    hold("h1", "/w/App/Drawer.swift"),
    'Held, this edit wasn\'t made: the thread "Fix the drawer" (id h2), at work in this folder, edited App/Drawer.swift in its turn. Read the file again or message_thread it, then edit again.',
  );
  assert.equal(hold("h1", "/w/App/Drawer.swift"), undefined);
  // A path from the folder is the same file.
  edit("h2", "/w/App/Theme.swift");
  assert.match(hold("h1", "App/Theme.swift")!, /edited App\/Theme\.swift/);
  // Another turn hasn't been told.
  heard("turn.done", { threadId: "h1" });
  working("h1", place("Me"), "/w", true);
  assert.match(hold("h1", "/w/App/Drawer.swift")!, /^Held/);
});

test("another folder isn't held, though the note names the overlap", (t) => {
  t.after(() => ["f1", "f2"].forEach(gone));
  working("f1", place("Me"), "/w", true);
  working("f2", place("Other", "P", "oricode/t-2"), "/w/.worktrees/t-2", true);
  edit("f2", "/w/.worktrees/t-2/a.txt");
  edit("f1", "/w/a.txt");
  assert.equal(hold("f1", "/w/a.txt"), undefined);
  assert.equal(hold("f1", "/w/.worktrees/t-2/a.txt"), undefined);
  assert.match(atStart("f1")!, /you both edited a\.txt, which merging will meet/);
});

test("only an edit that came back without an error counts, while its thread works", (t) => {
  t.after(() => ["e1", "e2"].forEach(gone));
  working("e1", place("Me"), "/w", true);
  working("e2", place("Two"), "/w", true);
  edit("e2", "/w/failed.txt", "c1", true);
  assert.equal(hold("e1", "/w/failed.txt"), undefined);
  heard("tool.use", { threadId: "e2", toolUseId: "c2", name: "Write", input: { file_path: "/w/waiting.txt" } });
  assert.equal(hold("e1", "/w/waiting.txt"), undefined);
  heard("tool.use", { threadId: "e2", toolUseId: "c3", name: "Read", input: { file_path: "/w/read.txt" } });
  heard("tool.result", { threadId: "e2", toolUseId: "c3", isError: false });
  assert.equal(hold("e1", "/w/read.txt"), undefined);
  // A subagent's edit is the thread's, a move is on both its names, another agent says its kind.
  heard("tool.use", { threadId: "e2", toolUseId: "c4", name: "Edit", input: { file_path: "/w/sub.txt" }, parent: "task" });
  heard("tool.result", { threadId: "e2", toolUseId: "c4", isError: false, parent: "task" });
  heard("tool.use", { threadId: "e2", toolUseId: "c5", name: "Move", kind: "move", input: { path: "/w/old.txt", movePath: "/w/new.txt" }, view: {} });
  heard("tool.result", { threadId: "e2", toolUseId: "c5", isError: false });
  for (const file of ["/w/sub.txt", "/w/old.txt", "/w/new.txt"]) assert.match(hold("e1", file)!, /^Held/, file);
  // Its turn over, what it edited holds nobody.
  edit("e2", "/w/done.txt");
  rested("e2");
  assert.equal(hold("e1", "/w/done.txt"), undefined);
});

/// The options a Thread starts its CLI with, on a CLI that does nothing.
async function launched(id: string, shared: boolean) {
  const options: any[] = [];
  const launch = (call: { options: unknown }) => {
    options.push(call.options);
    return { async *[Symbol.asyncIterator]() {
        await new Promise(() => {});
      }, initializationResult: () => Promise.reject(new Error("no CLI here")), close: () => {} };
  };
  const thread = new Thread(id, "claude", launch as never);
  await thread.send({ threadId: id, cwd: tmpdir(), text: "Go", permissionMode: "default", ...(shared ? { shared } : {}) });
  return options[0];
}

test("Claude Code's hooks hold the edit and carry the note, and a session that isn't a project's has none", async (t) => {
  t.after(() => ["c1", "c2"].forEach(gone));
  assert.equal((await launched("plain", false)).hooks, undefined);
  const { hooks } = await launched("c1", true);
  assert.equal(hooks.PreToolUse[0].matcher, "Edit|MultiEdit|Write|NotebookEdit");
  const before = hooks.PreToolUse[0].hooks[0];
  const after = hooks.PostToolUse[0].hooks[0];
  working("c1", place("Me"), "/w", true);
  const attempt = { tool_input: { file_path: "/w/a.txt" } };
  assert.deepEqual(await before(attempt), { continue: true });
  assert.deepEqual(await after({}), { continue: true });
  working("c2", place("Two"), "/w", true);
  edit("c2", "/w/a.txt");
  // A subagent's step keeps it for the thread's own.
  assert.deepEqual(await after({ agent_id: "sub" }), { continue: true });
  const { hookSpecificOutput: told } = await after({});
  assert.equal(told.hookEventName, "PostToolUse");
  assert.match(told.additionalContext, /"Two" \(id c2\), shares your folder/);
  const { hookSpecificOutput: held } = await before(attempt);
  assert.equal(held.permissionDecision, "deny");
  assert.match(held.permissionDecisionReason, /edited a\.txt in its turn/);
  assert.deepEqual(await before(attempt), { continue: true });
});

test("through the engine a lone thread's message goes as it was written, and one with company has the note ahead of it", async (t) => {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-others-"));
  const log = join(logs, "codex.log");
  const codex = await standInCli(bin, "codex", "codex-app-server.ts", { CODEX_LOG: log });
  const cwd = await mkdtemp(join(tmpdir(), "oricode-others-cwd-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: codex } } });
  const send = (threadId: string, text: string, fields: object) => engine.request("send", { threadId, cwd, text, permissionMode: "default", provider: "codex", ...fields });
  const prompts = async () =>
    (await readFile(log, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line))
      .filter((message) => message.method === "turn/start")
      .map((message) => message.params.input.at(-1).text as string);
  const done = (threadId: string, from: number) => engine.until((line) => line.event === "turn.done" && line.threadId === threadId, from);

  // The stand-in matches a message by its whole text, so `slow` and `hello` run only unchanged.
  let from = engine.lines.length;
  await send("A", "slow", { place: place("Slow one") });
  await engine.until((line) => line.event === "text" && line.threadId === "A", from);
  await send("C", "hello", { place: place("Elsewhere", "Other") });
  await send("D", "hello", {});
  await done("C", from);
  await done("D", from);
  from = engine.lines.length;
  await send("B", "hello", { place: place("Second") });
  await done("B", from);
  from = engine.lines.length;
  await engine.request("interrupt", { threadId: "A" });
  await done("A", from);
  // A's over, so B is alone again.
  from = engine.lines.length;
  await send("B", "hello", { place: place("Second") });
  await done("B", from);

  const [a, c, d, b, lone] = (await prompts()).map((text) => text.replace(/^\[OriCode\] Parts of this message.*\n\n/, ""));
  assert.equal(a, "slow");
  assert.equal(c, "hello");
  assert.equal(d, "hello");
  assert.equal(b, `[OriCode] Another thread is working in this project. message_thread reaches one.\n"Slow one" (id A), shares your folder\n\nhello`);
  assert.equal(lone, "hello");
  await engine.end();
});
