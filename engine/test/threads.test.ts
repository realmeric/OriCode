// A thread that opens another, or suggests one, through the real engine: a stand-in Codex in the
// thread's place, the test calling the tools over MCP as its agent would and answering
// `thread.open` as the app would.
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { told } from "../provider.ts";
import { mostOpened, mostSuggested, openedByAnother, opening, suggesting } from "../threads.ts";
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
  const starts = async () => (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line)).filter((message) => message.method === "thread/start").map((message) => message.params);
  return { engine, cwd, turn, starts };
}

test("a thread with no rays has open_thread and suggest_thread alone, is told when to open one, and the app's answer is the tool's", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const [started] = await starts();
  const url: string = started.config["mcp_servers.oricode"].url;
  assert.equal(started.developerInstructions, told(`${opening}\n\n${suggesting}`));
  assert.equal((await mcp(url, "initialize", { protocolVersion: "2025-06-18" })).instructions, `${opening}\n\n${suggesting}`);
  const tools = (await mcp(url, "tools/list")).tools;
  assert.deepEqual(tools.map((tool: { name: string }) => tool.name), ["open_thread", "suggest_thread"]);
  assert.match(tools[0].description, /only when the user asked for another thread in their own words/);
  assert.match((await call(url, "start_worker", { agent: "codex", task: "x" })).error, /isn't one of this thread's rays/);

  // The call waits on the app, which makes the thread and says what it made.
  const from = engine.lines.length;
  const calling = call(url, "open_thread", { title: "Rename sum.txt", message: " Rename sum.txt to total.txt. ", model: "gpt-large", folder: "/elsewhere", worktree: true, mode: "bypassPermissions" });
  const asked = await engine.until((line) => line.event === "thread.open", from);
  const { requestId, ...fields } = asked;
  assert.deepEqual(fields, { event: "thread.open", threadId: "parent", title: "Rename sum.txt", text: "Rename sum.txt to total.txt.", model: "gpt-large", folder: "/elsewhere", worktree: true });
  const made = { thread: "Rename sum.txt", agent: "codex", model: "gpt-large", mode: "default", folder: "/elsewhere" };
  assert.deepEqual((await engine.request("app.reply", { requestId, result: made })).result, { ok: true });
  assert.deepEqual(await calling, made);
  assert.equal((await engine.request("app.reply", { requestId, result: made })).error, "Nothing is waiting on that reply.");

  // What the app refuses, the agent reads as the tool's error.
  const refused = call(url, "open_thread", { title: "x", message: "y", agent: "pi" });
  const second = await engine.until((line) => line.event === "thread.open" && line.requestId !== requestId, from);
  assert.equal(second.worktree, false);
  await engine.request("app.reply", { requestId: second.requestId, error: "Pi asks before nothing, and this thread is on Ask." });
  assert.deepEqual(await refused, { error: "Pi asks before nothing, and this thread is on Ask." });
  assert.deepEqual(await call(url, "open_thread", { title: "x", message: "  " }), { error: "A thread needs its first message." });
  await engine.end();
});

test("one turn opens three threads at most, and the next turn three more", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("parent");
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const open = async (title: string) => {
    const from = engine.lines.length;
    const calling = call(url, "open_thread", { title, message: "go" });
    // The fourth is refused before the app hears of it.
    const asked = await Promise.race([engine.until((line) => line.event === "thread.open", from), calling.then(() => undefined)]);
    if (asked) await engine.request("app.reply", { requestId: asked.requestId, result: { thread: title } });
    return calling;
  };
  for (let n = 1; n <= mostOpened; n++) assert.deepEqual(await open(`t${n}`), { thread: `t${n}` });
  assert.deepEqual(await open("t4"), { error: "This turn has opened 3 threads, which is as many as one turn may." });
  // One the app refused doesn't count, so a turn's three are three that opened.
  await turn("parent");
  const from = engine.lines.length;
  const refused = call(url, "open_thread", { title: "no", message: "go" });
  await engine.request("app.reply", { requestId: (await engine.until((line) => line.event === "thread.open", from)).requestId, error: "No." });
  assert.deepEqual(await refused, { error: "No." });
  for (let n = 1; n <= mostOpened; n++) assert.deepEqual(await open(`u${n}`), { thread: `u${n}` });
  assert.match((await open("u4")).error, /^This turn has opened 3 threads/);
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

test("a thread another thread opened has no open_thread, with rays or without, and is told why", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("child", { opened: true });
  await turn("child-head", { opened: true, rays: ["codex/gpt-small"] });
  const [child, head] = await starts();
  // Without rays it has suggest_thread alone, which opens nothing.
  assert.deepEqual((await mcp(child.config["mcp_servers.oricode"].url, "tools/list")).tools.map((tool: { name: string }) => tool.name), ["suggest_thread"]);
  assert.equal(child.developerInstructions, told(`${openedByAnother}\n\n${suggesting}`));
  const url: string = head.config["mcp_servers.oricode"].url;
  assert.match(head.developerInstructions, /^[^]*You are this thread's head\./);
  assert.equal(head.developerInstructions.endsWith(`\n\n${openedByAnother}\n\n${suggesting}`), true);
  const listed = (await mcp(url, "tools/list")).tools.map((tool: { name: string }) => tool.name);
  assert.equal(listed.includes("start_worker"), true);
  assert.equal(listed.includes("open_thread"), false);
  assert.equal(listed.includes("suggest_thread"), true);
  const from = engine.lines.length;
  assert.deepEqual(await call(url, "open_thread", { title: "x", message: "y" }), { error: "Another thread opened this one, so it can't open threads of its own." });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "thread.open"), false);
  await engine.end();
});
