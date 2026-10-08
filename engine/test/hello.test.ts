// Hello and provider.check through the real engine, with a stand-in `claude` that answers only its
// version and its login, so nothing starts a real CLI or reaches Claude.
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, realpath, stat, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import assert from "node:assert/strict";
import type { ModelInfo } from "@anthropic-ai/claude-agent-sdk";
import { defaultsKey, writeCache } from "../cache.ts";
import { fallback, helloList, type Model } from "../models.ts";
import { drawing } from "../provider.ts";
import { opening } from "../threads.ts";
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
      workers: true,
      aside: true,
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

/// What a check leaves in the cache folder for the CLI at `path`, as the engine writes it.
async function login(folder: string, path: string, stamp?: string): Promise<string> {
  const real = await realpath(path);
  const { mtimeMs, size } = await stat(real);
  const file = join(folder, "login.json");
  await mkdir(folder, { recursive: true });
  await writeFile(file, JSON.stringify({ cli: path, stamp: stamp ?? `${real}:${mtimeMs}:${size}`, version: cli }));
  return file;
}

/// The engine's first `count` lines for one hello, with stdin closed after them.
async function helloUntil(env: Record<string, string | undefined>, count: number, before: () => Promise<void> = async () => {}): Promise<any[]> {
  const engine = startEngine(env);
  const lines: any[] = [];
  let arrived = () => {};
  createInterface({ input: engine.stdout }).on("line", (line) => {
    lines.push(JSON.parse(line));
    arrived();
  });
  const waiting = new Promise<void>((done) => (arrived = () => void (lines.length >= count && done())));
  engine.stdin.write(JSON.stringify({ id: 1, method: "hello" }) + "\n");
  await waiting;
  // What the engine does behind its reply ends with the engine: a test that looks for it waits here.
  await before();
  engine.stdin.end();
  await new Promise((done) => engine.on("close", done));
  return lines;
}

test("hello answers from the login it remembered without asking for the version or the login, and asks the login again behind the reply", async () => {
  const claude = await standIn(true);
  const { folder, config, known } = await cachedDefaults();
  const file = await login(folder, claude.path);
  // The login is asked again behind the reply, which stdin closing would cut short: on a fast
  // disk the models event beat it every time.
  let ran: string[] = [];
  const asked = async () => {
    for (let look = 0; look < 60 && !ran.length; look++) {
      ran = await claude.ran().catch(() => []);
      if (!ran.length) await new Promise((done) => setTimeout(done, 50));
    }
  };
  const lines = await helloUntil({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config }, 2, asked);
  assert.deepEqual(lines[0], { id: 1, result: { version, models: known, claude: claude.path, loggedIn: true, providers: [claudeEntry("ready", claude.path, cli, null)] } });
  // Still signed in: nothing more is said, and what it remembers stays.
  assert.deepEqual(ran, ["auth status"]);
  assert.ok(existsSync(file));
});

test("a login made and lost since: the reply says ready, a provider event says signed out, and it's forgotten", async () => {
  const claude = await standIn(false);
  const { folder, config } = await cachedDefaults();
  const file = await login(folder, claude.path);
  const lines = await helloUntil({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config }, 3);
  assert.equal(lines[0].result.providers[0].state, "ready");
  assert.deepEqual(lines[2], { event: "provider", ...claudeEntry("signedOut", claude.path, cli, "Run `claude` in Terminal and log in.") });
  assert.ok(!existsSync(file));
});

test("a CLI that isn't the one it remembered is asked in full, and remembered", async () => {
  const claude = await standIn(true);
  const { folder, config } = await cachedDefaults();
  const file = await login(folder, claude.path, "an older claude");
  const lines = await helloUntil({ ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config }, 2);
  assert.equal(lines[0].result.providers[0].state, "ready");
  assert.deepEqual(await claude.ran(), ["--version", "auth status"]);
  assert.notEqual(JSON.parse(await readFile(file, "utf8")).stamp, "an older claude");
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
      handoff: "codex resume --no-daemon {session}",
      workers: true,
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

/// Cursor as hello lists it, in the state it found it.
function cursorEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  const capabilities = { steer: false, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false, usage: false, commands: true, compact: false, commitMessage: false, handoff: null, workers: true };
  return { id: "cursor", name: "Cursor", agent: "Cursor", state, hint, cli: cliPath, version: cliVersion, capabilities, levels: [], modes: ["acceptEdits", "plan"] };
}

/// A model API that runs in Claude Code, as hello lists it: Claude's thread without its plan, with
/// OriCode's Ultracode atop its levels.
function compatibleEntry(id: string, name: string, state: string, cliPath: string | null, hint: string | null, levels: string[]) {
  const capabilities = { steer: true, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false, usage: false, commands: true, compact: true, commitMessage: true, handoff: null, workers: true };
  const modes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"];
  return { id, name, agent: name, state, hint, cli: cliPath, version: null, capabilities, levels: levels.length ? [...levels, "ultracode"] : levels, modes };
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
    cursorEntry("unknown", join(bin, "cursor-agent"), null, null),
    {
      ...unwiredEntry("grok", "Grok Build", "Grok", "missing", null, null, "Grok Build isn't installed. Install it with `curl -fsSL https://x.ai/cli/install.sh | bash`, then run `grok login`."),
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
    },
    compatibleEntry("zai", "Z.ai", "ready", claude.path, null, []),
    compatibleEntry("deepseek", "DeepSeek", "signedOut", null, "Add your DeepSeek key in Settings › Agents.", ["low", "high", "max"]),
  ]);
  assert.deepEqual(codex.result, codexEntry("ready", join(bin, "codex"), "codex-cli 9.9.9", null));
  assert.deepEqual(cursor.result, cursorEntry("signedOut", join(bin, "cursor-agent"), "2026.09.02", "Run `cursor-agent login` in Terminal."));
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

/// What `opencode models --verbose` prints for the stand-in's three models: two of its Zen's, one
/// with no variants and one with three, and one of a provider models.dev doesn't name.
const verboseOutput =
  `zen/small\n{\n  "id": "small",\n  "providerID": "zen",\n  "name": "Small",\n  "variants": {}\n}\n` +
  `zen/large\n{\n  "id": "large",\n  "providerID": "zen",\n  "name": "Large",\n  "variants": {\n    "low": {},\n    "medium": {},\n    "high": {}\n  }\n}\n` +
  `router/tiny\n{\n  "id": "tiny",\n  "providerID": "router",\n  "name": "Tiny",\n  "variants": {}\n}\n`;

test("OpenCode turned on is found at hello, reads ready once checked, and lists its models once from its model cache, as its sessions name them, with no session", async () => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const ran = join(home, "ran");
  // OpenCode's copy of the models.dev catalog.
  await mkdir(join(home, ".cache", "opencode"), { recursive: true });
  await writeFile(join(home, ".cache", "opencode", "models.json"), JSON.stringify({ zen: { id: "zen", name: "OpenCode Zen" } }));
  const agent = new URL("./fixtures/acp-agent.ts", import.meta.url).pathname;
  await writeFile(
    join(bin, "opencode"),
    `#!/bin/sh\necho "opencode $*" >> "${ran}"\ncase "$1" in\n  --version) echo "1.18.32" ;;\n  acp) exec "${process.execPath}" "${agent}" ;;\n  models) printf '${verboseOutput}' ;;\nesac\n`,
  );
  await chmod(join(bin, "opencode"), 0o755);
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, XDG_CACHE_HOME: undefined, PATH: `${bin}:/usr/bin:/bin` };
  const [hello, checked, listed] = await replies(env, [
    { method: "hello", params: { agents: { opencode: { path: join(bin, "opencode") } } } },
    { method: "provider.check", params: { provider: "opencode" } },
    { method: "models.list", params: { provider: "opencode" } },
  ]);
  const entry = {
    id: "opencode",
    name: "OpenCode",
    agent: "OpenCode",
    state: "ready",
    hint: null,
    cli: join(bin, "opencode"),
    version: null,
    capabilities: {
      steer: false,
      resume: true,
      modeLive: false,
      attachments: true,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: true,
      compact: false,
      commitMessage: false,
      handoff: "opencode --session {session}",
      workers: true,
    },
    levels: ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultracode"],
    modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  };
  assert.deepEqual(hello.result.providers[1], { ...entry, state: "unknown" });
  // Its own pick first, the last id of its first provider; each model's variants are its levels,
  // and a model with levels takes OriCode's Ultracode.
  assert.deepEqual(
    listed.result.models.map((model: Model) => [model.id, model.name, model.efforts, model.ultra, model.ultraRays]),
    [
      ["zen/small", "OpenCode Zen/Small", [], false, undefined],
      ["zen/large", "OpenCode Zen/Large", ["low", "medium", "high"], true, true],
      ["router/tiny", "router/Tiny", [], false, undefined],
    ],
  );
  assert.deepEqual(checked.result, { ...entry, version: "1.18.32" });
  // The check found it ready and read its models, which models.list had from it: one listing, and
  // no session to open or delete.
  assert.deepEqual((await readFile(ran, "utf8")).trim().split("\n").sort(), ["opencode --version", "opencode models --verbose"]);
});

test("Cursor on the Free plan reads ready and lists only Auto, as Cursor names it, deleting the session that listed it", async () => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const ran = join(home, "ran");
  const kept = join(home, ".cursor", "acp-sessions");
  await mkdir(join(kept, "s-1"), { recursive: true });
  await mkdir(join(kept, "the-users-own"));
  const agent = new URL("./fixtures/acp-agent.ts", import.meta.url).pathname;
  await writeFile(
    join(bin, "cursor-agent"),
    `#!/bin/sh\necho "cursor-agent $*" >> "${ran}"\ncase "$*" in\n  --version) echo "2026.09.02-c22c1a3" ;;\n` +
      `  "status --format json") echo '{"status": "authenticated", "isAuthenticated": true}' ;;\n` +
      `  "about --format json") echo '{"cliVersion": "2026.09.02-c22c1a3", "model": "Auto", "subscriptionTier": "Free"}' ;;\n` +
      `  acp) ACP_MODELS=cursor ACP_MODEL='default[]' exec "${process.execPath}" "${agent}" ;;\nesac\n`,
  );
  await chmod(join(bin, "cursor-agent"), 0o755);
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` };
  const [, checked, listed] = await replies(env, [
    { method: "hello", params: { agents: { cursor: { path: join(bin, "cursor-agent") } } } },
    { method: "provider.check", params: { provider: "cursor" } },
    { method: "models.list", params: { provider: "cursor" } },
  ]);
  assert.deepEqual(checked.result, cursorEntry("ready", join(bin, "cursor-agent"), "2026.09.02-c22c1a3", null));
  assert.deepEqual(
    listed.result.models.map((model: any) => [model.id, model.name, model.description, model.efforts, model.fast]),
    [["default[]", "Auto", "", [], false]],
  );
  // Only the session opened to list the models is gone.
  for (let tries = 0; tries < 40 && existsSync(join(kept, "s-1")); tries += 1) await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(existsSync(join(kept, "s-1")), false);
  assert.equal(existsSync(join(kept, "the-users-own")), true);
  const asked = (await readFile(ran, "utf8")).trim().split("\n");
  assert.deepEqual([...new Set(asked)].sort(), ["cursor-agent --version", "cursor-agent about --format json", "cursor-agent acp", "cursor-agent status --format json"]);
});

test("Copilot signed in to a GitHub account with no Copilot plan reads as its own state, with GitHub's line", async () => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const server = new URL("./fixtures/copilot-headless.ts", import.meta.url).pathname;
  await writeFile(join(bin, "copilot"), `#!/bin/sh\ncase "$1" in\n  --headless) COPILOT_ACCOUNT=noPlan exec "${process.execPath}" "${server}" ;;\nesac\n`);
  await chmod(join(bin, "copilot"), 0o755);
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` };
  const [hello, checked] = await replies(env, [
    { method: "hello", params: { agents: { copilot: { path: join(bin, "copilot") } } } },
    { method: "provider.check", params: { provider: "copilot" } },
  ]);
  const capabilities = { steer: false, resume: true, modeLive: true, attachments: true, heads: false, stopTask: false, limits: false, usage: false, commands: true, compact: false, commitMessage: false, handoff: "copilot --resume {session}", workers: true };
  const entry = { id: "copilot", name: "GitHub Copilot", agent: "Copilot", cli: join(bin, "copilot"), capabilities, levels: ["low", "medium", "high", "ultracode"], modes: ["default", "plan", "bypassPermissions"] };
  assert.deepEqual(hello.result.providers[1], { ...entry, state: "unknown", hint: null, version: null });
  assert.deepEqual(checked.result, {
    ...entry,
    state: "noPlan",
    hint: "You don't currently have a Copilot subscription. Run `copilot` in Terminal to sign up for Copilot Free.",
    version: "1.0.86",
  });
});

test("models.list for Claude answers with hello's list", async () => {
  const claude = await standIn(true);
  const { folder, config, known } = await cachedDefaults();
  const env = { ORICODE_CLAUDE: claude.path, ORICODE_CACHE: folder, CLAUDE_CONFIG_DIR: config };
  const [, listed] = await replies(env, [{ method: "hello" }, { method: "models.list", params: {} }]);
  assert.deepEqual(listed.result, { models: known });
});

test("models.list for an agent whose CLI isn't found says how to install it", async () => {
  const claude = await standIn(false);
  const [, missing] = await replies({ ORICODE_CLAUDE: claude.path }, [{ method: "hello" }, { method: "models.list", params: { provider: "devin" } }]);
  assert.equal(missing.error, "Devin isn't installed. Install it with `brew install --cask devin-cli`, then run `devin auth login`.");
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
  const send = { threadId: "k180", cwd, text: "work", model: "gpt-large", effort: "max", workflows: true, permissionMode: "default", provider: "codex" };
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
  // Every thread on an agent that takes MCP has OriCode's tools, for open_thread, and hears of it.
  const { config, ...opened } = sent.find((message) => message.method === "thread/start").params;
  assert.deepEqual(opened, { cwd, model: "gpt-large", approvalPolicy: "untrusted", sandbox: "workspace-write", developerInstructions: `${drawing}\n\n${opening}` });
  assert.match(config["mcp_servers.oricode"].url, /^http:\/\/127\.0\.0\.1:\d+\/[0-9a-f-]{36}$/);
  const decisions = sent.filter((message) => message.method === undefined && message.result?.decision).map((message) => message.result.decision);
  assert.deepEqual(decisions, [{ acceptWithExecpolicyAmendment: { execpolicy_amendment: ["make", "test"] } }, "decline"]);
});

/// A stand-in on the PATH under the agent's own name, running a fixture under node with `env`.
async function fixtureStandIn(bin: string, name: string, fixture: string, env: Record<string, string>): Promise<string> {
  const path = join(bin, name);
  const exports = Object.entries(env).map(([key, value]) => `export ${key}='${value}'\n`).join("");
  await writeFile(path, `#!/bin/sh\n${exports}exec "${process.execPath}" "${new URL(`./fixtures/${fixture}`, import.meta.url).pathname}" "$@"\n`);
  await chmod(path, 0o755);
  return path;
}

/// The engine, requests sent to it one at a time, and every line it writes, split on LF alone,
/// since pi's stand-in says U+2028, which readline would split on.
function engineWith(env: Record<string, string | undefined>) {
  const engine = startEngine(env);
  const lines: any[] = [];
  let arrived = () => {};
  let partial = "";
  engine.stdout.setEncoding("utf8");
  engine.stdout.on("data", (chunk: string) => {
    const complete = (partial + chunk).split("\n");
    partial = complete.pop() ?? "";
    lines.push(...complete.map((line) => JSON.parse(line)));
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
  const end = async () => {
    engine.stdin.end();
    await new Promise((done) => engine.on("close", done));
  };
  /// For a test that failed before it ended the engine, which would otherwise hold the run open.
  const kill = () => engine.exitCode === null && engine.kill();
  return { lines, until, request, end, kill };
}

/// Pi as hello lists it, in the state it found it.
function piEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "pi",
    name: "Pi",
    agent: "Pi",
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
      limits: false,
      usage: false,
      commands: true,
      compact: false,
      commitMessage: false,
      handoff: "pi --session {session}",
      unsupervised: true,
    },
    levels: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
    modes: [],
  };
}

test("a Pi thread through the engine: checked ready, its models with the forbidden logins marked, a turn, and claude.ai refused until its login is on", async (t) => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-pi-")));
  const log = join(cwd, "pi.log");
  const pi = await fixtureStandIn(bin, "pi", "pi-rpc.ts", { PI_LOG: log, PI_AUTH: JSON.stringify({ anthropic: "oauth", openai: "api_key", xai: "oauth" }) });
  const engine = engineWith({ ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` });
  t.after(engine.kill);

  const hello = await engine.request("hello", { agents: { pi: {} } });
  assert.deepEqual(hello.result.providers[1], piEntry("unknown", pi, null, null));
  const checked = await engine.request("provider.check", { provider: "pi" });
  assert.deepEqual(checked.result, piEntry("ready", pi, "0.87.1", null));
  const told = await engine.until((line) => line.event === "models");
  assert.equal(told.provider, "pi");
  const listed = (await engine.request("models.list", { provider: "pi" })).result.models;
  // Pi's default first, and the two it reaches through a forbidden login last.
  assert.deepEqual(
    listed.map((model: any) => [model.id, model.description, model.efforts.length, model.forbidden ?? null]),
    [
      ["openai/gpt-5.5", "openai · key", 5, null],
      ["openai/gpt-4", "openai · key", 0, null],
      ["meta/muse-1", "meta · key", 0, null],
      ["openrouter/anthropic/claude-haiku", "openrouter · key", 0, null],
      ["anthropic/claude-opus", "anthropic · login", 7, "anthropic"],
      ["xai/grok-5", "xai · login", 5, "xai"],
    ],
  );

  let from = engine.lines.length;
  const send = { threadId: "k186", cwd, text: "hello", model: "openai/gpt-5.5", effort: "high", permissionMode: "default", provider: "pi" };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  const done = await engine.until((line) => line.event === "turn.done", from);
  assert.equal(done.stopReason, "end_turn");
  assert.ok(done.sessionId.startsWith(join(cwd, "sessions")));

  from = engine.lines.length;
  await engine.request("send", { ...send, model: "anthropic/claude-opus" });
  assert.equal(
    (await engine.until((line) => line.event === "error", from)).message,
    "Pi reaches Anthropic through a login Anthropic keeps to its own apps. It stays off until you turn it on in Settings › Agents.",
  );
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "error_during_execution");

  // Turned on in Settings › Agents, that login's models can be picked, and run.
  assert.equal((await engine.request("agent.set", { provider: "pi", on: true, allow: ["anthropic"] })).result.provider.state, "ready");
  const allowed = (await engine.request("models.list", { provider: "pi" })).result.models;
  assert.deepEqual(allowed.filter((model: any) => model.forbidden).map((model: any) => model.id), ["xai/grok-5"]);
  from = engine.lines.length;
  await engine.request("send", { ...send, model: "anthropic/claude-opus" });
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).stopReason, "end_turn");
  await engine.end();

  const sent = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(sent.filter((message) => message.type === "set_model").map((message) => `${message.provider}/${message.modelId}`), ["openai/gpt-5.5", "anthropic/claude-opus"]);
  assert.equal(sent.find((message) => message.type === "set_thinking_level").level, "high");
  // No pi it started, for a thread or a list, got a variable of Claude's.
  assert.ok(sent.filter((message) => message.args).every((start) => start.env.length === 0));
});

/// Command Code as hello lists it, in the state it found it.
function commandCodeEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "commandcode",
    name: "Command Code",
    agent: "Command Code",
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
      commands: false,
      compact: false,
      commitMessage: false,
      handoff: "cmd --resume {session}",
      unsupervised: true,
    },
    levels: [],
    modes: ["default", "plan", "bypassPermissions"],
  };
}

test("a Command Code thread through the engine: signed in by its own login, its models listed once, a turn in Don't ask, and the next resuming it", async (t) => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-cmd-")));
  await writeFile(join(cwd, "hello.txt"), "zero\none\nend\n");
  const log = join(cwd, "cmd.log");
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` };
  const cmd = await fixtureStandIn(bin, "cmd", "commandcode-cli.ts", { CMD_LOG: log });
  const signedOut = engineWith(env);
  t.after(signedOut.kill);
  await signedOut.request("hello", { agents: { commandcode: {} } });
  const hint = "Command Code has no working API key. Add yours in Settings › Agents.";
  assert.deepEqual((await signedOut.request("provider.check", { provider: "commandcode" })).result, commandCodeEntry("signedOut", cmd, "1.66.0", hint));
  await signedOut.end();

  // A `cmd login` made in Terminal, with no key kept, is cmd's own to count.
  await fixtureStandIn(bin, "cmd", "commandcode-cli.ts", { CMD_LOG: log, CMD_LOGIN: "1" });
  const engine = engineWith(env);
  t.after(engine.kill);
  const hello = await engine.request("hello", { agents: { commandcode: {} } });
  assert.deepEqual(hello.result.providers[1], commandCodeEntry("unknown", cmd, null, null));
  assert.deepEqual((await engine.request("provider.check", { provider: "commandcode" })).result, commandCodeEntry("ready", cmd, "1.66.0", null));
  const told = await engine.until((line) => line.event === "models");
  assert.equal(told.provider, "commandcode");
  const listed = (await engine.request("models.list", { provider: "commandcode" })).result.models;
  assert.deepEqual(
    listed.map((model: any) => [model.id, model.name, model.efforts]),
    [
      ["deepseek/deepseek-v4-flash", "deepseek-v4-flash", []],
      ["deepseek/deepseek-v4-pro", "deepseek-v4-pro", []],
      ["inclusionai/ling-3.0-flash-sante:free", "ling-3.0-flash-sante:free", []],
      ["claude-sonnet-5", "claude-sonnet-5", []],
    ],
  );

  let from = engine.lines.length;
  const send = { threadId: "k190", cwd, text: "work", model: "deepseek/deepseek-v4-pro", permissionMode: "bypassPermissions", provider: "commandcode" };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  const done = await engine.until((line) => line.event === "turn.done", from);
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "s-1");
  const edit = engine.lines.slice(from).find((line) => line.event === "tool.result" && line.toolUseId === "t-edit");
  assert.deepEqual(edit.patch, [{ oldStart: 1, newStart: 1, lines: [" zero", "-one", "+two", " end"] }]);
  from = engine.lines.length;
  await engine.request("send", { ...send, text: "hello", permissionMode: "plan" });
  assert.equal((await engine.until((line) => line.event === "turn.done", from)).sessionId, "s-1");
  await engine.end();

  const runs = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  // The menu and models.list read one list between them.
  assert.equal(runs.filter((run) => run.args[0] === "--list-models").length, 1);
  const turns = runs.filter((run) => run.prompt !== undefined);
  assert.deepEqual(
    turns.map((run) => run.args),
    [
      ["-p", "--output-format", "json", "--yolo", "--tools-enable", "todo_write", "--model", "deepseek/deepseek-v4-pro"],
      ["-p", "--output-format", "json", "--permission-mode", "plan", "--tools-enable", "todo_write", "--model", "deepseek/deepseek-v4-pro", "--resume", "s-1"],
    ],
  );
  // No key was kept, so none was read, and cmd ran on its own login.
  assert.deepEqual(turns.map((run) => run.key), [null, null]);
});

/// Antigravity as hello lists it, in the state it found it.
function antigravityEntry(state: string, cliPath: string | null, cliVersion: string | null, hint: string | null) {
  return {
    id: "antigravity",
    name: "Antigravity",
    agent: "Antigravity",
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
      commands: false,
      compact: false,
      commitMessage: false,
      handoff: "agy --conversation {session}",
      unsupervised: true,
    },
    levels: [],
    modes: ["default", "acceptEdits", "plan"],
  };
}

test("an Antigravity thread through the engine: its Google account refused while off, no key, then ready on the Gemini API with a turn", async (t) => {
  const claude = await standIn(false);
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  const settings = join(home, ".gemini/antigravity-cli/settings.json");
  await mkdir(bin);
  await mkdir(join(home, ".gemini/antigravity-cli"), { recursive: true });
  await writeFile(settings, '{"colorScheme": "dark"}');
  const cwd = await realpath(await mkdtemp(join(tmpdir(), "oricode-agy-")));
  const log = join(cwd, "agy.log");
  const env = { ORICODE_CLAUDE: claude.path, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin`, GEMINI_API_KEY: undefined };
  const agy = await fixtureStandIn(bin, "agy", "antigravity-cli.ts", { AGY_LOG: log });

  const off = engineWith(env);
  t.after(off.kill);
  const hello = await off.request("hello", { agents: { antigravity: {} } });
  assert.deepEqual(hello.result.providers[1], antigravityEntry("unknown", agy, null, null));
  const google =
    'Antigravity signs in with a Google account, which Google keeps to its own apps. Set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and add a Gemini API key here, or turn on “Antigravity with a Google account”.';
  assert.deepEqual((await off.request("provider.check", { provider: "antigravity" })).result, antigravityEntry("signedOut", agy, null, google));
  const refused = await off.request("send", { threadId: "k187", cwd, text: "hello", permissionMode: "default", provider: "antigravity" });
  assert.equal(refused.error, google);
  await writeFile(settings, '{"colorScheme": "dark", "modelProvider": "gemini"}');
  const keyless = (await off.request("provider.check", { provider: "antigravity" })).result;
  assert.deepEqual(keyless, antigravityEntry("signedOut", agy, null, "Add your Gemini API key in Settings › Agents."));
  await off.end();
  // Neither route ran agy.
  assert.equal(await readFile(log, "utf8").catch(() => ""), "");

  const engine = engineWith({ ...env, GEMINI_API_KEY: "env-key-187" });
  t.after(engine.kill);
  await engine.request("hello", { agents: { antigravity: {} } });
  assert.deepEqual((await engine.request("provider.check", { provider: "antigravity" })).result, antigravityEntry("ready", agy, "1.2.11", null));
  const told = await engine.until((line) => line.event === "models");
  assert.equal(told.provider, "antigravity");
  assert.deepEqual(
    (await engine.request("models.list", { provider: "antigravity" })).result.models.map((model: any) => model.id),
    ["gemini-3.8-flash-high", "gemini-3.1-pro-high"],
  );
  const from = engine.lines.length;
  const send = { threadId: "k187", cwd, text: "hello", model: "gemini-3.1-pro-high", permissionMode: "plan", provider: "antigravity" };
  assert.deepEqual((await engine.request("send", send)).result, { ok: true });
  const done = await engine.until((line) => line.event === "turn.done", from);
  assert.equal(done.stopReason, "end_turn");
  assert.equal(done.sessionId, "c-1");
  await engine.end();

  const runs = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(
    runs.filter((run) => run.args).map((run) => [run.args, run.route, run.key]),
    [
      [["models"], "gemini", "env-key-187"],
      [["--input-format", "stream-json", "--output-format", "stream-json", "--mode", "plan", "--model", "gemini-3.1-pro-high"], "gemini", "env-key-187"],
    ],
  );
});
