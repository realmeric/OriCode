// Hello through the real engine, with a stand-in `claude` that answers only its version and its
// login, so nothing starts a real CLI or reaches Claude.
import { spawn } from "node:child_process";
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
async function standIn(loggedIn: boolean): Promise<{ path: string; ran: () => Promise<string[]> }> {
  const folder = await mkdtemp(join(tmpdir(), "oricode-hello-"));
  const path = join(folder, "claude");
  await writeFile(
    path,
    `#!/bin/sh\necho "$*" >> "${folder}/ran"\ncase "$1" in\n  --version) echo "${cli}" ;;\n  auth) echo '{"loggedIn": ${loggedIn}}'; exit ${loggedIn ? 0 : 1} ;;\nesac\n`,
  );
  await chmod(path, 0o755);
  return { path, ran: async () => (await readFile(join(folder, "ran"), "utf8")).trim().split("\n").sort() };
}

/// Every line the engine writes for one hello, with stdin closed behind it so it ends once it has answered.
async function hello(env: Record<string, string | undefined>): Promise<any[]> {
  return (await helloLines(env)).map((line) => JSON.parse(line));
}

async function helloLines(env: Record<string, string | undefined>): Promise<string[]> {
  const merged: Record<string, string | undefined> = { ...process.env, ORICODE_CLAUDE: undefined, ORICODE_CACHE: undefined, ...env };
  const engine = spawn(process.execPath, [new URL("../main.ts", import.meta.url).pathname], {
    stdio: ["pipe", "pipe", "inherit"],
    env: Object.fromEntries(Object.entries(merged).filter(([, value]) => value !== undefined)),
  });
  let out = "";
  engine.stdout.on("data", (chunk) => (out += chunk));
  engine.stdin.end(JSON.stringify({ id: 1, method: "hello" }) + "\n");
  await new Promise((done) => engine.on("close", done));
  return out.trim().split("\n");
}

test("with no claude to be found, hello says so and offers the fallback list", async () => {
  // A home with nothing in it: the login shell finds no claude, and nor do the usual places.
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const missing = "claude isn't installed. Install Claude Code, run `claude` in Terminal and log in.";
  assert.deepEqual(await hello({ HOME: home, ZDOTDIR: undefined }), [
    { id: 1, result: { version, models: fallback, claude: null, loggedIn: false, providers: [claudeEntry("missing", null, null, missing)] } },
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
  const config = await mkdtemp(join(tmpdir(), "oricode-config-"));
  const folder = join(await mkdtemp(join(tmpdir(), "oricode-cache-")), "Engine");
  const sdk = [{ value: "default", displayName: "Default", description: "Recommended", supportsEffort: true, supportedEffortLevels: ["low", "medium", "high"] }] as ModelInfo[];
  // No catalog and no settings in the config folder, so the list and its key are these.
  const list = helloList(sdk, [], null);
  const known = list.map((model) => ({ ...model, defaultEffort: "medium" }));
  await writeCache(folder, { version: cli, at: Date.now(), models: sdk, defaults: { key: defaultsKey(list, ""), models: known, settingsEffort: "medium", ultraKnown: true } });
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
