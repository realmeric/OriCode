// Rays through the real engine: a head on a stand-in Codex whose thread allows workers, and the
// test in the head model's place, calling OriCode's tools over MCP the way the head's agent would.
// Workers run on the stand-in Codex and a stand-in ACP agent as OpenCode, so nothing reaches a model.
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, realpath, writeFile, chmod } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { toolsConfig } from "../codex.ts";
import { brevity, drawing, told } from "../provider.ts";
import { Thread } from "../thread.ts";
import { lead } from "../ultracode.ts";
import { engineWith, sandbox } from "./engine.ts";

/// A folder with a repository in it and one commit.
async function repository(): Promise<string> {
  // Left unresolved, under /var, which git gives as /private/var, as it gives /tmp.
  const folder = await mkdtemp(join(tmpdir(), "oricode-rays-"));
  const git = (...args: string[]) => execFileSync("git", args, { cwd: folder });
  git("init", "-q", "-b", "main");
  git("config", "user.name", "Stand-in");
  git("config", "user.email", "stand-in@example.com");
  await writeFile(join(folder, "greet.ts"), "export const greet = () => 'hi';\n");
  git("add", "-A");
  git("commit", "-q", "-m", "First");
  return folder;
}

/// Codex and OpenCode as stand-ins on the engine's PATH, logging what they're sent.
async function agents(bin: string, logs: string): Promise<void> {
  const codex = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  const acp = new URL("./fixtures/acp-agent.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${join(logs, "codex.log")}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${codex}" "$@" ;;\nesac\n`);
  await writeFile(join(bin, "opencode"), `#!/bin/sh\nexport ACP_LOG='${join(logs, "acp.log")}'\ncase "$1" in\n  --version) echo "1.18.32" ;;\n  acp) exec "${process.execPath}" "${acp}" ;;\n  models) printf 'small\\n{\\n  "id": "small",\\n  "name": "Small",\\n  "variants": {}\\n}\\n' ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  await chmod(join(bin, "opencode"), 0o755);
}

async function logged(file: string): Promise<any[]> {
  return (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
}

/// One MCP request to the head's tools, as the head's agent sends it.
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

/// An engine with a Codex head in a repository whose thread lets its workers use Codex and OpenCode.
async function head(t: { after: (fn: () => unknown) => void }, threadId: string) {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-rays-logs-"));
  await agents(bin, logs);
  const cwd = await repository();
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") }, opencode: { path: join(bin, "opencode") } } });
  const send = { threadId, cwd, text: "hello", permissionMode: "bypassPermissions", provider: "codex", rays: ["codex/gpt-small", "opencode/small", "codex/gpt-large"] };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  await engine.until((line) => line.event === "turn.done" && line.threadId === threadId);
  const started = (await logged(join(logs, "codex.log"))).find((message) => message.method === "thread/start");
  const url: string = started.params.config["mcp_servers.oricode"].url;
  return { engine, cwd, logs, url, started };
}

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8" });

test("a Codex head gets the tools as one more MCP server beside the user's own, which its calls needn't be approved for", () => {
  assert.deepEqual(toolsConfig("http://127.0.0.1:1/x"), {
    "mcp_servers.oricode": { url: "http://127.0.0.1:1/x", tool_timeout_sec: 600, default_tools_approval_mode: "approve" },
  });
});

test("a head is told its rays in its own instructions, and lists and starts only those", async (t) => {
  const { engine, url, logs, started } = await head(t, "k198");
  const rays = "codex gpt-small, opencode small, codex gpt-large";
  const init = await mcp(url, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "codex", version: "9" } });
  assert.match(init.instructions, new RegExp(`^You are this thread's head\\. The user picked these rays for it, as start_worker's agent and model: ${rays}\\. Use them: `));
  // Codex hears it as developer instructions too, after what every session is told of the
  // window, and the user's prompt is left as it was.
  assert.equal(started.params.developerInstructions, told(init.instructions));
  const turn = (await logged(join(logs, "codex.log"))).find((message) => message.method === "turn/start");
  assert.equal(JSON.stringify(turn.params.input).includes("rays"), false);
  const listed = await call(url, "list_agents");
  assert.deepEqual(
    listed.agents.map((agent: any) => [agent.id, agent.models.map((model: { id: string; name: string }) => [model.id, model.name])]),
    [
      ["codex", [["gpt-small", "GPT Small"], ["gpt-large", "GPT Large"]]],
      ["opencode", [["small", "Small"]]],
    ],
  );
  assert.match((await call(url, "start_worker", { agent: "codex", model: "gpt-huge", task: "x" })).error, /^codex gpt-huge isn't one of this thread's rays: codex gpt-small, opencode small, codex gpt-large\. start_worker takes only those\.$/);
  assert.match((await call(url, "start_worker", { agent: "cursor", task: "x" })).error, /^cursor isn't one of this thread's rays/);
  // With no model, an agent's first ray.
  const worker = await call(url, "start_worker", { agent: "opencode", task: "look" });
  assert.equal(worker.model, "small");
  await call(url, "worker_result", { worker: worker.worker, wait: true });
  await engine.end();
});

test("a head starts workers on Codex and OpenCode, reads their status and results, messages one, and merges the isolated one's edits", async (t) => {
  const { engine, cwd, url } = await head(t, "k193");
  const init = await mcp(url, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "codex", version: "9" } });
  assert.equal(init.serverInfo.name, "oricode");
  assert.equal(init.protocolVersion, "2025-06-18");
  assert.deepEqual(
    (await mcp(url, "tools/list")).tools.map((tool: { name: string }) => tool.name),
    ["list_agents", "start_worker", "worker_status", "worker_result", "message_worker", "stop_worker", "merge_worker"],
  );

  const from = engine.lines.length;
  const writer = await call(url, "start_worker", { agent: "codex", model: "gpt-small", task: "write greet.test.ts", isolated: true });
  assert.equal(writer.worker, "worker-1");
  assert.match(writer.branch, /^oricode\/ray-/);
  assert.equal(writer.folder, join(await realpath(cwd), ".worktrees", writer.branch.slice("oricode/".length)));
  const reviewer = await call(url, "start_worker", { agent: "opencode", task: "review greet.test.ts" });
  assert.equal(reviewer.worker, "worker-2");
  assert.equal(reviewer.folder, cwd);

  // Both are heads in the thread's list, each with the agent it runs on.
  const both = await engine.until((line) => line.event === "heads" && line.threadId === "k193" && line.heads.length === 2, from);
  assert.deepEqual(
    both.heads.map((entry: any) => [entry.id, entry.kind, entry.agent, entry.model, entry.label, entry.worker]),
    [
      ["worker-1", "agent", "codex", "gpt-small", "write greet.test.ts", true],
      ["worker-2", "agent", "opencode", "small", "review greet.test.ts", true],
    ],
  );
  // Not watched, so no detail.
  assert.equal(both.heads[0].tokens, undefined);

  const written = await call(url, "worker_result", { worker: "worker-1", wait: true });
  assert.equal(written.state, "done");
  assert.equal(written.text, "Wrote greet.test.ts.");
  assert.deepEqual(written.files, [{ path: "greet.test.ts", added: 1, deleted: 0 }]);
  assert.equal(written.summary, "1 file, +1 −0");
  assert.equal(written.branch, writer.branch);
  // Its edit is on its branch, and not yet in the thread's folder.
  assert.equal(existsSync(join(cwd, "greet.test.ts")), false);
  assert.match(git(cwd, "log", "--oneline", writer.branch, "-1"), /write greet\.test\.ts/);

  const review = await call(url, "worker_result", { worker: "worker-2", wait: true });
  assert.equal(review.text, "Looks right to me.");
  const status = await call(url, "worker_status", { worker: "worker-1" });
  assert.equal(status.state, "done");
  assert.equal(status.tokens, 520);
  assert.equal(status.agent, "codex");
  assert.equal(status.step, "Write · greet.test.ts");

  // The reviewer's session answers a message as its next turn.
  assert.equal((await call(url, "message_worker", { worker: "worker-2", text: "hello" })).sent, "as its next turn");
  assert.equal((await call(url, "worker_result", { worker: "worker-2", wait: true })).text, "Hi.");
  // Its turns cost something, which the thread's cost takes in.
  const costs = engine.lines.slice(from).filter((line) => line.event === "worker" && line.worker === "worker-2");
  assert.deepEqual(costs.map((line) => [line.threadId, line.agent, line.costUSD]), [["k193", "opencode", 0.01]]);

  const merged = await call(url, "merge_worker", { worker: "worker-1" });
  assert.equal(merged.merged, true);
  assert.deepEqual(merged.conflicts, []);
  assert.deepEqual(merged.files, [{ path: "greet.test.ts", added: 1, deleted: 0 }]);
  // Squashed in, uncommitted, for the review.
  assert.equal(await readFile(join(cwd, "greet.test.ts"), "utf8"), "test('greets', () => {});\n");
  assert.equal(git(cwd, "log", "--oneline").trim().split("\n").length, 1);
  const credited = engine.lines.slice(from).find((line) => line.event === "worker" && line.merged);
  assert.equal(credited.worker, "worker-1");
  assert.equal(credited.agent, "codex");
  assert.equal(credited.label, "write greet.test.ts");
  assert.deepEqual(credited.files, [{ path: join(await realpath(cwd), "greet.test.ts"), hunks: [{ oldStart: 0, newStart: 1, lines: ["+test('greets', () => {});"] }] }]);

  // A worker that worked in the thread's folder has nothing to merge.
  assert.match((await call(url, "merge_worker", { worker: "worker-2" })).error, /own folder/);
  // A worker it doesn't have.
  assert.match((await call(url, "worker_status", { worker: "worker-9" })).error, /no worker called worker-9/);
  await engine.end();
});

test("a worker's ask goes to the head's thread labelled with its agent and task, and the answer goes back to it", async (t) => {
  const { engine, url } = await head(t, "k193-ask");
  const from = engine.lines.length;
  await call(url, "start_worker", { agent: "opencode", task: "work" });
  const ask = await engine.until((line) => line.event === "ask", from);
  assert.equal(ask.threadId, "k193-ask");
  assert.deepEqual(ask.worker, { id: "worker-1", agent: "opencode", label: "work" });
  assert.deepEqual(ask.choices.map((choice: { id: string }) => choice.id), ["once", "always", "reject"]);
  assert.deepEqual((await engine.request("answer", { requestId: ask.requestId, allow: true, optionId: "once" })).result, { ok: true });
  const result = await call(url, "worker_result", { worker: "worker-1", wait: true });
  assert.equal(result.state, "done");
  assert.equal(result.text, "Let me look.Done.");
  // Its edit landed in the thread's folder, so the thread hears which ray made it, with what it cost.
  const credited = engine.lines.slice(from).find((line) => line.event === "worker");
  assert.equal(credited.costUSD, 0.25);
  assert.deepEqual(credited.files.map((file: { path: string }) => file.path), ["/w/a.txt"]);
  // Nothing of the worker's own reaches the app under an id it has no thread for.
  assert.equal(engine.lines.slice(from).some((line) => typeof line.threadId === "string" && line.threadId.includes("/worker-")), false);
  await engine.end();
});

test("Stop on the head stops its workers, a worker's row stops that worker, and detail comes only while watched", async (t) => {
  const { engine, url } = await head(t, "k193-stop");
  await engine.request("heads.watch", { threadId: "k193-stop", on: true });
  const from = engine.lines.length;
  await call(url, "start_worker", { agent: "codex", task: "slow" });
  await call(url, "start_worker", { agent: "opencode", task: "wait" });
  await call(url, "start_worker", { agent: "codex", task: "slow" });
  const three = await engine.until((line) => line.event === "heads" && line.heads.length === 3, from);
  assert.deepEqual(Object.keys(three.heads[0]).sort(), ["agent", "background", "cost", "depth", "id", "kind", "label", "model", "startedAt", "step", "tokens", "toolUseId", "tools", "type", "worker"]);

  // Stop on worker-3's row.
  assert.deepEqual((await engine.request("task.stop", { threadId: "k193-stop", taskId: "worker-3" })).result, { ok: true });
  assert.equal((await call(url, "worker_result", { worker: "worker-3", wait: true })).state, "stopped");

  // Stop on the head: the others stop, the ask the ACP worker was waiting on goes, and the list empties.
  const ask = await engine.until((line) => line.event === "ask" && line.threadId === "k193-stop", from);
  await engine.request("interrupt", { threadId: "k193-stop" });
  assert.equal((await call(url, "worker_result", { worker: "worker-1", wait: true })).state, "stopped");
  assert.equal((await call(url, "worker_result", { worker: "worker-2", wait: true })).state, "stopped");
  await engine.until((line) => line.event === "ask.cancelled" && line.requestId === ask.requestId, from);
  await engine.until((line) => line.event === "heads" && line.threadId === "k193-stop" && line.heads.length === 0, from);
  await engine.end();
});

test("an OpenCode head names the tools in session/new, since it takes MCP over HTTP", async (t) => {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-rays-logs-"));
  await agents(bin, logs);
  const cwd = await repository();
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { opencode: { path: join(bin, "opencode") }, codex: { path: join(bin, "codex") } } });
  await engine.request("send", { threadId: "k193-acp", cwd, text: "hello", permissionMode: "default", provider: "opencode", rays: ["codex/gpt-large"] });
  await engine.until((line) => line.event === "turn.done");
  const opened = (await logged(join(logs, "acp.log"))).find((message) => message.method === "session/new");
  assert.equal(opened.params.mcpServers.length, 1);
  assert.deepEqual({ ...opened.params.mcpServers[0], url: "" }, { type: "http", name: "oricode", url: "", headers: [] });
  assert.equal((await call(opened.params.mcpServers[0].url, "list_agents")).agents[0].id, "codex");
  await engine.end();
});

test("workflows on a Codex model without ultra are OriCode's: the head is told to fan out on its own model at the thread's level, and its workers take that level unless told another", async (t) => {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-rays-logs-"));
  await agents(bin, logs);
  const cwd = await repository();
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const small = (await engine.request("models.list", { provider: "codex" })).result.models.find((model: { id: string }) => model.id === "gpt-small");
  assert.deepEqual([small.ultra, small.ultraRays], [true, true]);
  // No rays picked: the workflows' ray is the head's own model, and the head hears so where it hears of rays.
  await engine.request("send", { threadId: "k199", cwd, text: "hello", model: "gpt-small", effort: "medium", workflows: true, permissionMode: "bypassPermissions", provider: "codex" });
  await engine.until((line) => line.event === "turn.done" && line.threadId === "k199");
  const sent = await logged(join(logs, "codex.log"));
  const opened = sent.find((message) => message.method === "thread/start").params;
  const url: string = opened.config["mcp_servers.oricode"].url;
  assert.match(opened.developerInstructions, /workflows are on: .*start_worker on these rays, as its agent and model: codex gpt-small\./);
  assert.equal((await mcp(url, "initialize", { protocolVersion: "2025-06-18" })).instructions, opened.developerInstructions.slice(drawing.length + 2));
  assert.deepEqual((await call(url, "list_agents")).agents.map((agent: any) => [agent.id, agent.models.map((model: { id: string }) => model.id)]), [["codex", ["gpt-small"]]]);
  const start = sent.find((message) => message.method === "turn/start").params;
  assert.equal(start.effort, "medium");
  assert.equal(start.input[0].text, `${lead}\n\nhello`);

  const inheriting = await call(url, "start_worker", { agent: "codex", model: "gpt-small", task: "hello" });
  await call(url, "worker_result", { worker: inheriting.worker, wait: true });
  const told = await call(url, "start_worker", { agent: "codex", model: "gpt-small", effort: "low", task: "again" });
  await call(url, "worker_result", { worker: told.worker, wait: true });
  const workers = (await logged(join(logs, "codex.log"))).filter((message) => message.method === "turn/start").slice(1).map((message) => message.params);
  assert.deepEqual(workers.map((worker) => [worker.effort, worker.input[0].text]), [["medium", "hello"], ["low", "again"]]);
  await engine.end();
});

test("concise replies are asked for in the engine's words, ahead of a head's rays, and only when Settings asks", async (t) => {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-concise-logs-"));
  await agents(bin, logs);
  const cwd = await repository();
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const send = { threadId: "k222", cwd, text: "hello", permissionMode: "bypassPermissions", provider: "codex" };
  await engine.request("send", { ...send, concise: true });
  await engine.until((line) => line.event === "turn.done" && line.threadId === "k222");
  await engine.request("send", send);
  await engine.until((line, ) => line.event === "turn.done" && line.threadId === "k222", engine.lines.length);
  const opened = (await logged(join(logs, "codex.log"))).filter((message) => message.method === "thread/start" || message.method === "thread/resume").map((message) => message.params.developerInstructions);
  assert.deepEqual(opened, [told(brevity), drawing]);
  await engine.end();
});

test("a Claude head gets the tools as an HTTP server loaded with its prompt, allows its own calls to them, and starts again without them", async () => {
  const launched: any[] = [];
  const launch = ((args: { prompt: AsyncIterable<SDKUserMessage>; options: any }) => {
    launched.push(args.options);
    return {
      async *[Symbol.asyncIterator]() {
        await new Promise(() => {});
      },
      initializationResult: () => Promise.reject(new Error("no CLI here")),
      close: () => {},
      interrupt: async () => {},
    };
  }) as never;
  const cwd = await mkdtemp(join(tmpdir(), "oricode-rays-claude-"));
  const thread = new Thread("k193-claude", "claude", launch);
  await thread.send({ threadId: "k193-claude", cwd, text: "Go", permissionMode: "default", tools: "http://127.0.0.1:1/head", instructions: "Your rays." });
  assert.deepEqual(launched[0].mcpServers, { oricode: { type: "http", url: "http://127.0.0.1:1/head", alwaysLoad: true, timeout: 600_000 } });
  // Told that the window draws, and its rays, in its system prompt, after Claude Code's own.
  assert.deepEqual(launched[0].systemPrompt, { type: "preset", preset: "claude_code", append: `${drawing}\n\nYour rays.` });
  const allowed = await launched[0].canUseTool("mcp__oricode__start_worker", { agent: "codex" }, { signal: new AbortController().signal, toolUseID: "c1" });
  assert.deepEqual(allowed, { behavior: "allow", updatedInput: { agent: "codex" } });
  thread.close();
  await thread.send({ threadId: "k193-claude", cwd, text: "Again", permissionMode: "default" });
  assert.equal(launched.length, 2);
  assert.equal(launched[1].mcpServers, undefined);
  assert.deepEqual(launched[1].systemPrompt, { type: "preset", preset: "claude_code", append: drawing });
  thread.close();
});
