// A thread that opens, messages, waits on or stops another, suggests one, or reads the others,
// through the real engine: a stand-in Codex in the thread's place, the test calling the tools over
// MCP as its agent would and answering the app's events as the app would.
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { told } from "../provider.ts";
import { fromThread, leading, mostSuggested, opening, suggesting } from "../threads.ts";
import { engineWith, sandbox } from "./engine.ts";

async function mcp(url: string, method: string, params: object = {}): Promise<any> {
  const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  assert.equal(response.status, 200);
  return (await response.json()).result;
}

/// A tool's answer, parsed, or its error's words.
async function call(url: string, name: string, args: object = {}): Promise<any> {
  const result = await mcp(url, "tools/call", { name, arguments: args });
  const text = result.content[0].text;
  return result.isError ? { error: text } : JSON.parse(text);
}

/// An engine with a stand-in Codex, and what each of its threads was started with.
async function codex(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const log = join(await mkdtemp(join(tmpdir(), "oricode-threads-logs-")), "codex.log");
  const standIn = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${log}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${standIn}" "$@" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-threads-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const turn = async (threadId: string, more: object = {}) => {
    const from = engine.lines.length;
    assert.deepEqual((await engine.request("send", { threadId, cwd, text: "hello", permissionMode: "default", provider: "codex", ...more })).result, { ok: true });
    await engine.until((line) => line.event === "turn.done" && line.threadId === threadId, from);
  };
  const logged = async (method: string) => (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line)).filter((message) => message.method === method).map((message) => message.params);
  const starts = () => logged("thread/start");
  return { engine, cwd, turn, starts, logged };
}

test("a thread with no rays has the thread tools alone, is told it decides, and the app's answer is the tool's", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const [started] = await starts();
  const url: string = started.config["mcp_servers.oricode"].url;
  assert.equal(started.developerInstructions, told(`${opening}\n\n${suggesting}`));
  assert.equal((await mcp(url, "initialize", { protocolVersion: "2025-06-18" })).instructions, `${opening}\n\n${suggesting}`);
  const tools = (await mcp(url, "tools/list")).tools;
  assert.deepEqual(tools.map((tool: { name: string }) => tool.name), ["open_thread", "message_thread", "wait_thread", "answer_ask", "stop_thread", "merge_thread", "finish_merge", "suggest_thread", "list_threads", "read_thread", "read_plan", "add_tasks", "claim_task", "update_task", "wait_plan"]);
  assert.match(tools[0].description, /Open one when you judge the work wants it/);
  assert.doesNotMatch(tools[0].description, /asked|own words/);
  assert.deepEqual(tools[0].inputSchema.required, ["title", "message", "reason"]);
  assert.match(opening, /CLAUDE\.md or AGENTS\.md: keep to it\./);
  assert.match(opening, /Ask the user first only where you aren't sure/);
  assert.match((await call(url, "start_worker", { agent: "codex", task: "x" })).error, /isn't one of this thread's rays/);

  // The call waits on the app, which makes the thread and says what it made.
  const from = engine.lines.length;
  const calling = call(url, "open_thread", { title: "Rename sum.txt", message: " Rename sum.txt to total.txt. ", reason: " The rename can go on alone. ", model: "gpt-large", folder: "/elsewhere", worktree: true, mode: "default" });
  const asked = await engine.until((line) => line.event === "thread.open", from);
  const { requestId, ...fields } = asked;
  assert.deepEqual(fields, { event: "thread.open", threadId: "parent", title: "Rename sum.txt", text: "Rename sum.txt to total.txt.", reason: "The rename can go on alone.", model: "gpt-large", folder: "/elsewhere", mode: "default", worktree: true });
  const made = { thread: "Rename sum.txt", agent: "codex", model: "gpt-large", mode: "default", folder: "/elsewhere" };
  assert.deepEqual((await engine.request("app.reply", { requestId, result: made })).result, { ok: true });
  assert.deepEqual(await calling, made);
  assert.equal((await engine.request("app.reply", { requestId, result: made })).error, "Nothing is waiting on that reply.");

  // What the app refuses, the agent reads as the tool's error.
  const refused = call(url, "open_thread", { title: "x", message: "y", reason: "z", agent: "pi" });
  const second = await engine.until((line) => line.event === "thread.open" && line.requestId !== requestId, from);
  assert.equal(second.worktree, false);
  await engine.request("app.reply", { requestId: second.requestId, error: "Pi asks before nothing, and this thread is on Ask." });
  assert.deepEqual(await refused, { error: "Pi asks before nothing, and this thread is on Ask." });
  assert.deepEqual(await call(url, "open_thread", { title: "x", message: "  ", reason: "z" }), { error: "A thread needs its first message." });
  assert.deepEqual(await call(url, "open_thread", { title: "x", message: "y" }), { error: "Say why in `reason`, one line the user reads." });
  await engine.end();
});

// The app tells a thread's opener at once when its first send is refused, so the engine must
// answer that send with the error and start nothing it would later end.
test("a first send the engine refuses is the send's error, and no turn of it starts or ends", async (t) => {
  const { engine, turn } = await codex(t);
  const from = engine.lines.length;
  const reply = await engine.request("send", { threadId: "opened", cwd: "/nowhere/at/all", text: "Rename sum.txt.", permissionMode: "default", provider: "codex" });
  assert.match(reply.error, /isn't where it was/);
  // Another thread's whole turn later, still nothing of it.
  await turn("parent");
  assert.deepEqual(engine.lines.slice(from).filter((line) => line.threadId === "opened" && line.event), []);
  await engine.end();
});

test("a turn opens as many threads as the app lets it, which is the app's ceiling to keep", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const open = async (title: string, answer: object) => {
    const from = engine.lines.length;
    const calling = call(url, "open_thread", { title, message: "go", reason: "a part of its own" });
    const asked = await engine.until((line) => line.event === "thread.open", from);
    await engine.request("app.reply", { requestId: asked.requestId, ...answer });
    return calling;
  };
  for (let n = 1; n <= 5; n++) assert.deepEqual(await open(`t${n}`, { result: { thread: `t${n}` } }), { thread: `t${n}` });
  assert.deepEqual(await open("t6", { error: "2 threads are working, as many as the user allows at once." }), { error: "2 threads are working, as many as the user allows at once." });
  await engine.end();
});

test("a suggestion goes to the app as an event and starts nothing, two a turn at most", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const described = (await mcp(url, "tools/list")).tools.find((tool: { name: string }) => tool.name === "suggest_thread");
  assert.match(described.description, /Nothing starts\./);
  assert.match(described.description, /Most replies suggest nothing\./);
  assert.deepEqual(described.inputSchema.required, ["title", "prompt"]);

  const from = engine.lines.length;
  assert.deepEqual(await call(url, "suggest_thread", { title: " Fix the README's install line ", prompt: " README.md says npm install; the repo uses pnpm. " }), { shown: "Fix the README's install line", started: false });
  const suggested = await engine.until((line) => line.event === "thread.suggested", from);
  assert.deepEqual(suggested, { event: "thread.suggested", threadId: "parent", title: "Fix the README's install line", text: "README.md says npm install; the repo uses pnpm." });
  // The app isn't asked for anything, so there is nothing for it to answer.
  assert.equal(engine.lines.slice(from).some((line) => line.event === "thread.open" || line.requestId), false);

  // One with no title or no prompt has nothing to show, and isn't one of the turn's two.
  assert.deepEqual(await call(url, "suggest_thread", { title: " ", prompt: "x" }), { error: "A suggestion needs a title for its button." });
  assert.deepEqual(await call(url, "suggest_thread", { title: "x" }), { error: "A suggestion needs the prompt its thread would start on." });
  assert.deepEqual(await call(url, "suggest_thread", { title: "Second", prompt: "y" }), { shown: "Second", started: false });
  assert.deepEqual(await call(url, "suggest_thread", { title: "Third", prompt: "z" }), { error: "This turn has suggested 2 threads, which is as many as one turn may." });
  assert.equal(engine.lines.slice(from).filter((line) => line.event === "thread.suggested").length, mostSuggested);
  // The next turn has two of its own.
  await turn("parent");
  assert.deepEqual(await call(url, "suggest_thread", { title: "Third", prompt: "z" }), { shown: "Third", started: false });
  await engine.end();
});

test("a thread another opened has every thread tool, and a message from a thread says who sent it", async (t) => {
  const { engine, turn, starts, logged } = await codex(t);
  await turn("child", { from: { id: "PARENT-1", title: "Sums" } });
  await turn("child", { text: "and you?" });
  const [child] = await starts();
  assert.deepEqual((await mcp(child.config["mcp_servers.oricode"].url, "tools/list")).tools.map((tool: { name: string }) => tool.name).slice(0, 5), ["open_thread", "message_thread", "wait_thread", "answer_ask", "stop_thread"]);
  assert.equal(child.developerInstructions, told(`${opening}\n\n${suggesting}`));
  const [first, second] = await logged("turn/start");
  // Codex hears the lead on parts ahead of each message, then who sent it.
  assert.equal(JSON.stringify(first.input).includes(JSON.stringify(`${leading}\n\n${fromThread({ id: "PARENT-1", title: "Sums" })}\n\nhello`).slice(1, -1)), true);
  assert.match(fromThread({ id: "PARENT-1", title: "Sums" }), /^\[From another thread\] The thread "Sums" \(id PARENT-1\)/);
  // The user's own message says nothing of another thread.
  assert.doesNotMatch(JSON.stringify(second.input), /From another thread/);
  assert.equal(JSON.stringify(second.input).includes(JSON.stringify(`${leading}\n\nand you?`).slice(1, -1)), true);
  await engine.end();
});

test("message_thread, wait_thread and stop_thread go to the app with the thread and the reason, and the app's answer is the tool's", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const answered = async (name: string, args: object, event: string, answer: object) => {
    const from = engine.lines.length;
    const calling = call(url, name, args);
    const { requestId, ...asked } = await engine.until((line) => line.event === event, from);
    await engine.request("app.reply", { requestId, ...answer });
    return { asked, answer: await calling };
  };
  const sent = await answered("message_thread", { thread: " T2 ", text: " Use tabs. ", reason: " It asked which. " }, "thread.message", { result: { sent: "Tabs", started: true } });
  assert.deepEqual(sent.asked, { event: "thread.message", threadId: "parent", thread: "T2", text: "Use tabs.", reason: "It asked which." });
  assert.deepEqual(sent.answer, { sent: "Tabs", started: true });
  const waited = await answered("wait_thread", { thread: "T2", reason: "ignored" }, "thread.wait", { result: { state: "idle", reply: "Done." } });
  assert.deepEqual(waited.asked, { event: "thread.wait", threadId: "parent", thread: "T2" });
  assert.deepEqual(waited.answer, { state: "idle", reply: "Done." });
  const stopped = await answered("stop_thread", { thread: "T2", reason: "Its part is done." }, "thread.stop", { error: "Tabs isn't working, so there's nothing to stop." });
  assert.deepEqual(stopped.asked, { event: "thread.stop", threadId: "parent", thread: "T2", reason: "Its part is done." });
  assert.deepEqual(stopped.answer, { error: "Tabs isn't working, so there's nothing to stop." });
  // What's missing is refused before the app hears of it.
  const from = engine.lines.length;
  assert.deepEqual(await call(url, "message_thread", { thread: "T2", reason: "x" }), { error: "A message needs its text." });
  assert.deepEqual(await call(url, "message_thread", { thread: "T2", text: "x" }), { error: "Say why in `reason`, one line the user reads." });
  assert.deepEqual(await call(url, "stop_thread", { reason: "x" }), { error: "Name the thread by its id, which list_threads gives." });
  assert.deepEqual(await call(url, "wait_thread", {}), { error: "Name the thread by its id, which list_threads gives." });
  assert.equal(engine.lines.slice(from).some((line) => line.requestId), false);
  await engine.end();
});

test("answer_ask goes to the app with the ask, what to do with it and the reason, and the app's answer is the tool's", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const tool = (await mcp(url, "tools/list")).tools.find((listed: { name: string }) => listed.name === "answer_ask");
  assert.deepEqual(tool.inputSchema.required, ["ask", "answer", "reason"]);
  assert.match(tool.description, /only what your own permission mode would have done without asking the user/);
  assert.match(opening, /pass up what your mode can't allow or you aren't sure of/);
  const answered = async (args: object, answer: object) => {
    const from = engine.lines.length;
    const calling = call(url, "answer_ask", args);
    const { requestId, ...asked } = await engine.until((line) => line.event === "thread.answer", from);
    await engine.request("app.reply", { requestId, ...answer });
    return { asked, answer: await calling };
  };
  const allowed = await answered({ ask: " r1 ", answer: "allow", reason: " An edit in its own worktree. " }, { result: { ask: "r1", answered: "allow" } });
  assert.deepEqual(allowed.asked, { event: "thread.answer", threadId: "parent", ask: "r1", answer: "allow", reason: "An edit in its own worktree." });
  assert.deepEqual(allowed.answer, { ask: "r1", answered: "allow" });
  const told = await answered({ ask: "r2", answer: "answer", answers: { "Which file?": "sum.py", count: 2 }, reason: "The task names it." }, { result: { ask: "r2", answered: "answer" } });
  assert.deepEqual(told.asked, { event: "thread.answer", threadId: "parent", ask: "r2", answer: "answer", reason: "The task names it.", answers: { "Which file?": "sum.py", count: "2" } });
  const refused = await answered({ ask: "r3", answer: "allow", reason: "Tests." }, { error: "This thread is on Accept edits, which allows edits to files and nothing else without the user, so it can't allow Bash: npm test." });
  assert.match(refused.answer.error, /can't allow Bash: npm test/);
  // What's missing is refused before the app hears of it.
  const from = engine.lines.length;
  assert.deepEqual(await call(url, "answer_ask", { ask: "r1", answer: "maybe", reason: "x" }), { error: "Say allow, deny, answer or pass in `answer`." });
  assert.deepEqual(await call(url, "answer_ask", { ask: "r1", answer: "pass" }), { error: "Say why in `reason`, one line the user reads in both threads." });
  assert.deepEqual(await call(url, "answer_ask", { ask: "r1", answer: "answer", reason: "x" }), { error: "A question is answered with `answers`, each question's text to its answer." });
  assert.deepEqual(await call(url, "answer_ask", { answer: "deny", reason: "x" }), { error: "Name the ask by its id, from wait_thread's `asks`." });
  assert.equal(engine.lines.slice(from).some((line) => line.requestId), false);
  await engine.end();
});

test("a thread lists the others and reads one through the app", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("asking");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const tools = (await mcp(url, "tools/list")).tools;
  const described = (name: string) => tools.find((tool: { name: string }) => tool.name === name);
  assert.match(described("list_threads").description, /It reads and starts nothing\./);
  assert.match(described("read_thread").description, /Reading wakes nothing/);
  assert.deepEqual(described("read_thread").inputSchema.required, ["thread"]);
  assert.deepEqual(await call(url, "steer_thread", { thread: "t", text: "x" }), { error: "OriCode has no tool called steer_thread." });

  // The listing is the app's, asked for when the tool is called, with the file to look for.
  const from = engine.lines.length;
  const listing = call(url, "list_threads", { edited: "App/Drawer.swift", state: "working" });
  const { requestId, ...asked } = await engine.until((line) => line.event === "threads.list", from);
  assert.deepEqual(asked, { event: "threads.list", threadId: "asking", edited: "App/Drawer.swift" });
  const listed = { project: "alpha", threads: [{ id: "T1", title: "The drawer's width", state: "idle", edited: [{ path: "App/Drawer.swift" }] }] };
  await engine.request("app.reply", { requestId, result: listed });
  assert.deepEqual(await listing, listed);

  // So is a transcript, a part at a time.
  const reading = call(url, "read_thread", { thread: " T1 ", before: 40, text: "do this next" });
  const { requestId: second, ...read } = await engine.until((line) => line.event === "thread.read", from);
  assert.deepEqual(read, { event: "thread.read", threadId: "asking", thread: "T1", before: 40 });
  await engine.request("app.reply", { requestId: second, error: "No thread of this project has the id T1." });
  assert.deepEqual(await reading, { error: "No thread of this project has the id T1." });
  const whole = call(url, "read_thread", { thread: "T1", before: "40" });
  const third = await engine.until((line) => line.event === "thread.read" && line.requestId !== second, from);
  assert.equal("before" in third, false);
  await engine.request("app.reply", { requestId: third.requestId, result: { transcript: "User: hi" } });
  assert.deepEqual(await whole, { transcript: "User: hi" });
  // Nor is a number no transcript has a place for, which the app would have to turn into one.
  for (const before of [1e30, -1, 1.5]) {
    const asked = engine.lines.length;
    const reading = call(url, "read_thread", { thread: "T1", before });
    const odd = await engine.until((line) => line.event === "thread.read", asked);
    assert.equal("before" in odd, false);
    await engine.request("app.reply", { requestId: odd.requestId, result: { transcript: "User: hi" } });
    await reading;
  }
  assert.deepEqual(await call(url, "read_thread", {}), { error: "read_thread needs a thread's id, which list_threads gives." });

  // Reading starts no turn and reaches no thread but through the app's answer.
  assert.equal(engine.lines.slice(from).some((line) => ["turn.started", "thread.open", "thread.suggested"].includes(line.event)), false);
  await engine.end();
});
