// Hello and provider.check through the real engine, with a stand-in `claude` that answers only its
// version and its login, so nothing starts a real CLI or reaches Claude.
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
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
