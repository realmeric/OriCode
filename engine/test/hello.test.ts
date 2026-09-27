// Hello and provider.check through the real engine, with a stand-in `claude` that answers only its
// version and its login, so nothing starts a real CLI or reaches Claude.
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { defaultsKey, writeCache } from "../cache.ts";
import { fallback, helloList } from "../models.ts";
import { version } from "../version.ts";

const cli = "9.9.9 (Claude Code)";

/// Claude Code as hello lists it among the agents, in the state it found it.
function claudeEntry(state: string, path: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "claude",
    name: "Claude Code",
    agent: "Claude",
    state,
    hint,
    cli: path,
    version: cliVersion,
    capabilities: {
      steer: true,
      resume: true,
      modeLive: true,
      attachments: true,
      heads: true,
      stopTask: true,
      limits: true,
      usage: true,
      commands: true,
      compact: true,
      commitMessage: true,
      handoff: "claude --resume {session}",
    },
    levels: ["low", "medium", "high", "xhigh", "max", "ultracode"],
    modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  };
}

/// A `claude` that says its version and whether it's logged in, and writes down what it was asked.
/// `logIn` is the login made in Terminal.
async function standIn(loggedIn: boolean): Promise<{ path: string; ran: () => Promise<string[]>; logIn: () => Promise<void> }> {
  const folder = await mkdtemp(join(tmpdir(), "oricode-hello-"));
  const path = join(folder, "claude");
  const login = join(folder, "login");
  await writeFile(
    path,
    `#!/bin/sh\necho "$*" >> "${folder}/ran"\ncase "$1" in\n  --version) echo "${cli}" ;;\n` +
      `  auth) if [ -e "${login}" ]; then echo '{"loggedIn": true}'; else echo '{"loggedIn": false}'; exit 1; fi ;;\nesac\n`,
  );
  await chmod(path, 0o755);
  const logIn = () => writeFile(login, "");
  if (loggedIn) await logIn();
  return { path, ran: async () => (await readFile(join(folder, "ran"), "utf8")).trim().split("\n").sort(), logIn };
}

/// A cache folder with one model and the defaults read for it, under the stand-in's version.
async function cachedDefaults(): Promise<{ folder: string; config: string; known: object[] }> {
  const config = await mkdtemp(join(tmpdir(), "oricode-config-"));
  const folder = join(await mkdtemp(join(tmpdir(), "oricode-cache-")), "Engine");
  const sdk = [{ value: "default", displayName: "Default", description: "Recommended", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high"] }] as ModelInfo[];
  // No catalog and no settings in the config folder, so the list and its key are these.
  const list = helloList(sdk, [], null);
  const known = list.map((model) => ({ ...model, defaultEffort: "medium" }));
  await writeCache(folder, { version: cli, at: Date.now(), models: sdk, defaults: { key: defaultsKey(list, ""), models: known, settingsEffort: "medium", ultraKnown: true } });
  return { folder, config, known };
}

/// Every line the engine writes for one hello, with stdin closed behind it so it ends once it has answered.
async function hello(env: Record<string, string | undefined>): Promise<any[]> {
  return (await helloLines(env)).map((line) => JSON.parse(line));
}

function startEngine(env: Record<string, string | undefined>) {
  const merged: Record<string, string | undefined> = { ...process.env, ORICODE_CLAUDE: undefined, ORICODE_CACHE: undefined, ...env };
  return spawn(process.execPath, [new URL("../main.ts", import.meta.url).pathname], {
    stdio: ["pipe", "pipe", "inherit"],
    env: Object.fromEntries(Object.entries(merged).filter(([, value]) => value !== undefined)),
  });
}

async function helloLines(env: Record<string, string | undefined>): Promise<string[]> {
  const engine = startEngine(env);
  let out = "";
  engine.stdout.on("data", (chunk) => (out += chunk));
  engine.stdin.end(JSON.stringify({ id: 1, method: "hello" }) + "\n");
  await new Promise((done) => engine.on("close", done));
  return out.trim().split("\n");
}

test("with no claude to be found, hello says so and offers the fallback list", async () => {
  // A home with nothing in it: the login shell finds no claude, and nor do the usual places.
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const hint = "Install Claude Code, then run `claude` in Terminal and log in.";
  assert.deepEqual(await hello({ HOME: home, ZDOTDIR: undefined }), [
    { id: 1, result: { version, models: fallback, claude: null, loggedIn: false, providers: [claudeEntry("missing", null, null, hint)] } },
  ]);
});

test("a claude that isn't logged in gets the fallback list and no probe", async () => {
  const claude = await standIn(false);
  const lines = await hello({ ORICODE_CLAUDE: claude.path });
  const hint = "Run `claude` in Terminal and log in.";
  assert.deepEqual(lines, [
    { id: 1, result: { version, models: fallback, claude: claude.path, loggedIn: false, providers: [claudeEntry("signedOut", claude.path, cli, hint)] } },
  ]);
  assert.deepEqual(await claude.ran(), ["--version", "auth status"]);
});

test("ready from the cache, hello answers with the defaults it kept, and the models event follows the reply", async () => {
  const claude = await standIn(true);
  const { folder, config, known } = await cachedDefaults();
  const lines = await hello({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config });
  assert.deepEqual(lines, [
    { id: 1, result: { version, models: known, claude: claude.path, loggedIn: true, providers: [claudeEntry("ready", claude.path, cli, null)] } },
    { event: "models", models: known, settingsEffort: "medium", ultraKnown: true },
  ]);
  // The version and the login, and no CLI for the models.
  assert.deepEqual(await claude.ran(), ["--version", "auth status"]);
});

test("the agents come after everything hello said before there were others, so those bytes stay as they were", async () => {
  const claude = await standIn(false);
  const [line] = await helloLines({ ORICODE_CLAUDE: claude.path });
  const before = JSON.stringify({ id: 1, result: { version, models: fallback, claude: claude.path, loggedIn: false } });
  assert.ok(line.startsWith(before.slice(0, -2) + ',"providers":[{"id":"claude",'));
});

/// Hello, then, once `between` has run, a check of Claude: every line the engine wrote, the
/// first `count` of them waited for before stdin closes, so one more coming late would show.
async function helloThenCheck(env: Record<string, string | undefined>, between: () => Promise<void>, count: number): Promise<any[]> {
  const engine = startEngine(env);
  const lines: any[] = [];
  let arrived = () => {};
  createInterface({ input: engine.stdout }).on("line", (line) => {
    lines.push(JSON.parse(line));
    arrived();
  });
  const until = (wanted: number) => new Promise<void>((done) => (arrived = () => void (lines.length >= wanted && done())));
  let waiting = until(1);
  engine.stdin.write(JSON.stringify({ id: 1, method: "hello" }) + "\n");
  await waiting;
  await between();
  waiting = until(count);
  engine.stdin.write(JSON.stringify({ id: 2, method: "provider.check", params: { provider: "claude" } }) + "\n");
  await waiting;
  engine.stdin.end();
  await new Promise((done) => engine.on("close", done));
  return lines;
}

test("a check after a login in Terminal finds Claude ready and reads its models, asking the CLI only for the login", async () => {
  const claude = await standIn(false);
  const { folder, config, known } = await cachedDefaults();
  const lines = await helloThenCheck({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config }, claude.logIn, 3);
  const hint = "Run `claude` in Terminal and log in.";
  assert.deepEqual(lines, [
    { id: 1, result: { version, models: fallback, claude: claude.path, loggedIn: false, providers: [claudeEntry("signedOut", claude.path, cli, hint)] } },
    { id: 2, result: claudeEntry("ready", claude.path, cli, null) },
    // The cache had the defaults, so one event carries the list with them.
    { event: "models", models: known, settingsEffort: "medium", ultraKnown: true },
  ]);
  assert.deepEqual(await claude.ran(), ["--version", "auth status", "auth status"]);
});

test("a check while still signed out says so again and reads no models", async () => {
  const claude = await standIn(false);
  const lines = await helloThenCheck({ ORICODE_CLAUDE: claude.path }, async () => {}, 2);
  assert.deepEqual(lines.slice(1), [{ id: 2, result: claudeEntry("signedOut", claude.path, cli, "Run `claude` in Terminal and log in.") }]);
  assert.deepEqual(await claude.ran(), ["--version", "auth status", "auth status"]);
});

test("a check of a Claude that was ready at hello doesn't send its models again", async () => {
  const claude = await standIn(true);
  const { folder, config } = await cachedDefaults();
  const lines = await helloThenCheck({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config }, async () => {}, 3);
  assert.deepEqual(lines.slice(2), [{ id: 2, result: claudeEntry("ready", claude.path, cli, null) }]);
});

/// Each request in turn, the next sent once the last has its reply, and every reply by its id.
async function replies(env: Record<string, string | undefined>, requests: { method: string; params?: object }[]): Promise<any[]> {
  const engine = startEngine(env);
  const answered = new Map<number, any>();
  let arrived = () => {};
  createInterface({ input: engine.stdout }).on("line", (line) => {
    const message = JSON.parse(line);
    if (message.id !== undefined) answered.set(message.id, message);
    arrived();
  });
  for (const [index, request] of requests.entries()) {
    const id = index + 1;
    const replied = new Promise<void>((done) => (arrived = () => void (answered.has(id) && done())));
    engine.stdin.write(JSON.stringify({ id, ...request }) + "\n");
    await replied;
  }
  engine.stdin.end();
  await new Promise((done) => engine.on("close", done));
  return requests.map((_, index) => answered.get(index + 1));
}

/// Codex as hello lists it, in the state it found it.
function codexEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "codex",
    name: "Codex",
    agent: "Codex",
    state,
    hint,
    cli: cliPath,
    version: cliVersion,
    capabilities: {
      steer: true,
      resume: true,
      modeLive: false,
      attachments: true,
      heads: false,
      stopTask: false,
      limits: true,
      usage: true,
      commands: false,
      compact: false,
      commitMessage: false,
      handoff: "codex resume {session}",
    },
    levels: ["low", "medium", "high", "xhigh", "max", "ultracode"],
    modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  };
}

/// A `codex` that says its version and runs the stand-in app-server for everything else, writing
/// down what it was asked outside the app-server.
async function codexStandIn(bin: string, ran: string): Promise<string> {
  const fixture = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  const path = join(bin, "codex");
  await writeFile(
    path,
    `#!/bin/sh\ncase "$*" in\n  app-server) exec "${process.execPath}" "${fixture}" "$@" ;;\nesac\necho "codex $*" >> "${ran}"\n` +
      `case "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${fixture}" "$@" ;;\nesac\n`,
  );
  await chmod(path, 0o755);
  return path;
}

/// An agent with no session in the engine yet, as hello lists it.
function unwiredEntry(id: string, name: string, agent: string, state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  const capabilities = { steer: false, resume: false, modeLive: false, attachments: false, heads: false, stopTask: false, limits: false, usage: false, commands: false, compact: false, commitMessage: false, handoff: null };
  return { id, name, agent, state, hint, cli: cliPath, version: cliVersion, capabilities, levels: [], modes: [] };
}

/// A model API that runs in Claude Code, as hello lists it: Claude's thread without its plan.
function compatibleEntry(id: string, name: string, state: string, cliPath: string | null, hint: string | null, levels: string[]) {
  const capabilities = { steer: true, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false, usage: false, commands: true, compact: true, commitMessage: true, handoff: null };
  const modes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"];
  return { id, name, agent: name, state, hint, cli: cliPath, version: null, capabilities, levels, modes };
}

test("hello lists the agents turned on without asking their CLIs anything, a check asks one, and one turned off is forgotten", async () => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const ran = join(home, "ran");
  const standInAgent = async (name: string, cases: string) => {
    await writeFile(join(bin, name), `#!/bin/sh\necho "${name} $*" >> "${ran}"\ncase "$*" in\n${cases}\nesac\n`);
    await chmod(join(bin, name), 0o755);
  };
  await codexStandIn(bin, ran);
  await standInAgent("cursor-agent", `  --version) echo "2026.09.02" ;;\n  "status --format json") echo '{"isAuthenticated": false}' ;;`);
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` };
  const agents = { codex: {}, cursor: {}, grok: {}, zai: { key: true }, deepseek: {} };
  const [hello, codex, cursor, off, checkedOff, devin, listed] = await replies(env, [
    { method: "hello", params: { agents } },
    { method: "provider.check", params: { provider: "codex" } },
    { method: "provider.check", params: { provider: "cursor" } },
    { method: "agent.set", params: { provider: "codex", on: false } },
    { method: "provider.check", params: { provider: "codex" } },
    { method: "agent.set", params: { provider: "devin", on: true } },
    { method: "agents" },
  ]);
  assert.deepEqual(hello.result.providers, [
    claudeEntry("signedOut", claude.path, cli, "Run `claude` in Terminal and log in."),
    codexEntry("unknown", join(bin, "codex"), null, null),
    unwiredEntry("cursor", "Cursor", "Cursor", "unknown", join(bin, "cursor-agent"), null, null),
    unwiredEntry("grok", "Grok Build", "Grok", "missing", null, null, "Grok Build isn't installed. Install it with `curl -fsSL https://x.ai/cli/install.sh | bash`, then run `grok login`."),
    compatibleEntry("zai", "Z.ai", "ready", claude.path, null, []),
    compatibleEntry("deepseek", "DeepSeek", "signedOut", null, "Add your DeepSeek key in Settings › Agents.", ["low", "high", "max"]),
  ]);
  assert.deepEqual(codex.result, codexEntry("ready", join(bin, "codex"), "codex-cli 9.9.9", null));
  assert.deepEqual(cursor.result, unwiredEntry("cursor", "Cursor", "Cursor", "signedOut", join(bin, "cursor-agent"), "2026.09.02", "Run `cursor-agent login` in Terminal."));
  assert.deepEqual(off.result, { provider: null });
  assert.equal(checkedOff.error, "Codex is off in Settings › Agents.");
  assert.equal(devin.result.provider.state, "missing");
  assert.equal(listed.result.agents.length, 14);
  // Hello asked Claude only; each check asked its own agent.
  assert.deepEqual(await claude.ran(), ["--version", "auth status"]);
  assert.deepEqual((await readFile(ran, "utf8")).trim().split("\n").sort(), ["codex --version", "codex login status", "cursor-agent --version", "cursor-agent status --format json"]);
});

test("Z.ai, DeepSeek, OpenRouter and Meta run in Claude Code: ready once a key is kept, signed out or not, and their models listed without starting it", async () => {
  const claude = await standIn(false);
  // OpenRouter's public list, asked with no key.
  const asked: (string | undefined)[] = [];
  const catalog = createServer((req, res) => {
    asked.push(req.headers.authorization);
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ data: [{ id: "z-ai/glm-5.3", name: "Z.ai: GLM 5.3", context_length: 1_310_720, supported_parameters: ["tools"], reasoning: { supported_efforts: ["max", "high", "low"], default_effort: "max" } }] }));
  });
  await new Promise<void>((listening) => catalog.listen(0, "127.0.0.1", listening));
  const env = { ORICODE_CLAUDE: claude.path, ORICODE_OPENROUTER_MODELS: `http://127.0.0.1:${(catalog.address() as AddressInfo).port}/api/v1/models` };
  const [hello, zai, deepseek, kept, checked, openrouter, openrouterModels, meta, metaModels] = await replies(env, [
    { method: "hello", params: { agents: { zai: { key: true }, deepseek: {}, openrouter: { key: true }, meta: {} } } },
    { method: "models.list", params: { provider: "zai" } },
    { method: "models.list", params: { provider: "deepseek" } },
    { method: "agent.set", params: { provider: "deepseek", on: true, key: true } },
    { method: "provider.check", params: { provider: "zai" } },
    { method: "provider.check", params: { provider: "openrouter" } },
    { method: "models.list", params: { provider: "openrouter" } },
    { method: "agent.set", params: { provider: "meta", on: true, key: true } },
    { method: "models.list", params: { provider: "meta" } },
  ]);
  catalog.close();
  assert.deepEqual(hello.result.providers.slice(1), [
    compatibleEntry("zai", "Z.ai", "ready", claude.path, null, []),
    compatibleEntry("deepseek", "DeepSeek", "signedOut", null, "Add your DeepSeek key in Settings › Agents.", ["low", "high", "max"]),
    compatibleEntry("openrouter", "OpenRouter", "ready", claude.path, null, ["low", "medium", "high", "xhigh", "max"]),
    compatibleEntry("meta", "Meta", "signedOut", null, "Add your Meta Model API key in Settings › Agents.", ["low", "medium", "high", "xhigh"]),
  ]);
  assert.deepEqual(
    zai.result.models.map((model: any) => [model.id, model.name, model.efforts, model.fast, model.ultra]),
    [
      ["glm-5.3[1m]", "GLM-5.3", [], false, false],
      ["glm-5.3-flash[1m]", "GLM-5.3-Flash", [], false, false],
    ],
  );
  assert.deepEqual(
    deepseek.result.models.map((model: any) => [model.id, model.efforts]),
    [
      ["deepseek-v4-pro[1m]", ["low", "high", "max"]],
      ["deepseek-flash[1m]", ["low", "high", "max"]],
    ],
  );
  assert.deepEqual(kept.result.provider, compatibleEntry("deepseek", "DeepSeek", "ready", claude.path, null, ["low", "high", "max"]));
  assert.equal(checked.result.state, "ready");
  assert.equal(openrouter.result.state, "ready");
  assert.deepEqual(
    openrouterModels.result.models.map((model: any) => [model.id, model.name, model.description, model.efforts, model.defaultEffort]),
    [["z-ai/glm-5.3[1m]", "GLM 5.3", "Z.ai · 1M context", ["low", "high", "max"], "max"]],
  );
  // Read once, for the check and the list both, with no key.
  assert.deepEqual(asked, [undefined]);
  assert.deepEqual(meta.result.provider, compatibleEntry("meta", "Meta", "ready", claude.path, null, ["low", "medium", "high", "xhigh"]));
  assert.deepEqual(
    metaModels.result.models.map((model: any) => [model.id, model.name, model.efforts]),
    [["muse-spark-1.3[1m]", "Muse Spark 1.3", ["low", "medium", "high", "xhigh"]]],
  );
  // Claude Code was asked what hello always asks, and nothing on their behalf.
  assert.deepEqual(await claude.ran(), ["--version", "auth status"]);
});

test("with no Claude Code, Z.ai says it needs it", async () => {
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const [hello] = await replies({ HOME: home, ZDOTDIR: undefined, PATH: "/usr/bin:/bin" }, [{ method: "hello", params: { agents: { zai: { key: true } } } }]);
  assert.deepEqual(hello.result.providers[1], compatibleEntry("zai", "Z.ai", "missing", null, "Z.ai runs in Claude Code, which isn't installed. Install Claude Code to use it.", []));
});

test("models.list for Claude answers with hello's list", async () => {
  const claude = await standIn(true);
  const { folder, config, known } = await cachedDefaults();
  const env = { ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config };
  const [, listed] = await replies(env, [{ method: "hello" }, { method: "models.list", params: {} }]);
  assert.deepEqual(listed.result, { models: known });
});

test("models.list for an agent with no session in the engine says so", async () => {
  const claude = await standIn(false);
  const [, unknown] = await replies({ ORICODE_CLAUDE: claude.path }, [{ method: "hello" }, { method: "models.list", params: { provider: "cursor" } }]);
  assert.equal(unknown.error, "Cursor can't list its models yet.");
});

test("a Codex thread through the engine: checked ready, its models listed, a turn whose asks the shared registry answers, its usage", async () => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-codex-"));
  const log = join(cwd, "codex.log");
  const codex = await codexStandIn(bin, join(home, "ran"));
  const engine = startEngine({ ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin`, CODEX_LOG: log });
  const lines: any[] = [];
  let arrived = () => {};
  createInterface({ input: engine.stdout }).on("line", (line) => {
    lines.push(JSON.parse(line));
    arrived();
  });
  const until = async (matches: (line: any) => boolean, from = 0) => {
    while (!lines.slice(from).some(matches)) await new Promise<void>((done) => (arrived = done));
    return lines.slice(from).find(matches);
  };
  let next = 0;
  const request = (method: string, params: object = {}) => {
    const id = ++next;
    engine.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    return until((line) => line.id === id);
  };

  const hello = await request("hello", { agents: { codex: {} } });
  assert.deepEqual(hello.result.providers[1], codexEntry("unknown", codex, null, null));
  const checked = await request("provider.check", { provider: "codex" });
  assert.deepEqual(checked.result, codexEntry("ready", codex, "codex-cli 9.9.9", null));
  const told = await until((line) => line.event === "models");
  assert.equal(told.provider, "codex");
  assert.deepEqual(told.models.map((model: { id: string }) => model.id), ["gpt-large", "gpt-small"]);
  const listed = await request("models.list", { provider: "codex" });
  assert.deepEqual(listed.result.models[0], {
    id: "gpt-large",
    name: "GPT Large",
    description: "Deep",
    efforts: ["low", "medium", "high", "xhigh", "max"],
    fast: false,
    defaultEffort: "high",
    ultra: true,
    ultraBlocked: null,
  });

  const from = lines.length;
  const send = { threadId: "k180", cwd, text: "work", model: "gpt-large", effort: "ultracode", permissionMode: "default", provider: "codex" };
  assert.deepEqual((await request("send", send)).result, { ok: true });
  const run = await until((line) => line.event === "ask", from);
  assert.deepEqual(run.choices.map((choice: { id: string }) => choice.id), ["accept", "acceptWithExecpolicyAmendment", "cancel"]);
  assert.deepEqual((await request("answer", { requestId: run.requestId, allow: true, optionId: "acceptWithExecpolicyAmendment" })).result, { ok: true });
  const edit = await until((line) => line.event === "ask" && line.requestId !== run.requestId, from);
  await request("answer", { requestId: edit.requestId, allow: false });
  const done = await until((line) => line.event === "turn.done", from);
  assert.equal(done.sessionId, "t-1");
  assert.equal((await request("answer", { requestId: run.requestId, allow: true })).error, "That question is no longer waiting.");
  const limits = lines.slice(from).find((line) => line.event === "limits");
  assert.deepEqual(limits.windows, [{ id: "30_day", label: "30-day window", used: 0.01, resetsAt: 1792439399000 }]);

  const usage = await request("usage", { provider: "codex" });
  assert.deepEqual(usage.result, { available: true, plan: "go", windows: [{ id: "30_day", label: "30-day window", used: 0.02, resetsAt: new Date(1792439399000).toISOString() }] });
  engine.stdin.end();
  await new Promise((done) => engine.on("close", done));

  const sent = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  const start = sent.find((message) => message.method === "turn/start").params;
  assert.equal(start.model, "gpt-large");
  assert.equal(start.effort, "ultra");
  assert.deepEqual(sent.find((message) => message.method === "thread/start").params, { cwd, model: "gpt-large", approvalPolicy: "untrusted", sandbox: "workspace-write" });
  const decisions = sent.filter((message) => message.method === undefined && message.result?.decision).map((message) => message.result.decision);
  assert.deepEqual(decisions, [{ acceptWithExecpolicyAmendment: { execpolicy_amendment: ["make", "test"] } }, "decline"]);
});
