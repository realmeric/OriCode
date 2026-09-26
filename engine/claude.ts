import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { query, type FastModeDisabledReason, type FastModeState, type ModelInfo, type SDKUserMessage, type SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { cachedModels, defaultsKey, readCache, writeCache, type Cache } from "./cache.ts";
import { readCatalog, readSettings, readSettingsEffort } from "./catalog.ts";
import { fallback, helloList, withDefaults, type Model } from "./models.ts";
import type { Availability, ModelsEvent, Provider } from "./provider.ts";
import { describe, Thread } from "./thread.ts";
import { usage } from "./usage.ts";
import { version } from "./version.ts";
import { log } from "./wire.ts";

const run = promisify(execFile);

async function executable(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

let found: Promise<string | null> | undefined;

/// The `claude` the user installed and logged into. The SDK's own bundled CLI is left
/// out of the app on purpose, so this is the only one the engine will run.
export function findClaude(): Promise<string | null> {
  found ??= (async () => {
    const override = process.env.ORICODE_CLAUDE;
    if (override && (await executable(override))) return override;
    try {
      const { stdout } = await run("/bin/zsh", ["-lc", "command -v claude"], { timeout: 5000 });
      const path = stdout.trim().split("\n").pop();
      if (path && path.startsWith("/") && (await executable(path))) return path;
    } catch {}
    const candidates = [
      join(homedir(), ".local/bin/claude"),
      join(homedir(), ".claude/local/claude"),
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ];
    for (const path of candidates) if (await executable(path)) return path;
    return null;
  })();
  return found;
}

/// Asks the CLI whether it has a login. The engine never sees the credential itself.
export async function loggedIn(claude: string): Promise<boolean> {
  try {
    const { stdout } = await run(claude, ["auth", "status"], { timeout: 10000, env: cleanEnvironment() as NodeJS.ProcessEnv });
    return JSON.parse(stdout).loggedIn === true;
  } catch (error) {
    const stdout = (error as { stdout?: string }).stdout;
    try {
      return JSON.parse(stdout ?? "").loggedIn === true;
    } catch {
      return false;
    }
  }
}

/// What `claude --version` prints, "2.1.282 (Claude Code)", or null when it can't say.
export async function claudeVersion(claude: string): Promise<string | null> {
  try {
    const { stdout } = await run(claude, ["--version"], { timeout: 5000, env: cleanEnvironment() as NodeJS.ProcessEnv });
    return stdout.trim() || null;
  } catch {
    return null;
  }
}

/// The environment for the CLI. When OriCode is opened from inside a Claude Code session,
/// it inherits that session's CLAUDE* variables, and a child `claude` that sees them waits
/// for a host that isn't there. CLAUDE_CONFIG_DIR is the user's own setting and stays.
export function cleanEnvironment(): Record<string, string | undefined> {
  const environment: Record<string, string | undefined> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if ((key.startsWith("CLAUDE") && key !== "CLAUDE_CONFIG_DIR") || key === "AI_AGENT" || key === "PWD" || key === "OLDPWD") continue;
    environment[key] = value;
  }
  environment.CLAUDE_AGENT_SDK_CLIENT_APP = `oricode/${version}`;
  // Without it the first turn waits for every MCP server in the user's settings to connect,
  // and one started with `npm exec …@latest` can take minutes. The desktop app sets it too.
  environment.MCP_CONNECTION_NONBLOCKING ??= "true";
  return environment;
}

/// Where the CLI writes its --debug-file when the app asks for a trace.
export function cliDebugFile(name: string): string | undefined {
  const folder = process.env.ORICODE_CLI_DEBUG;
  return folder ? `${folder}/${name}-${Date.now()}.log` : undefined;
}

const missing = "claude isn't installed. Install Claude Code, run `claude` in Terminal and log in.";

/// Whether Claude Code can run, asked of the CLI the way hello always has.
async function availability(): Promise<Availability> {
  const claude = await findClaude();
  if (!claude) return { state: "missing", cli: null, version: null, hint: missing };
  const [login, cli] = await Promise.all([loggedIn(claude), claudeVersion(claude)]);
  return { state: login ? "ready" : "signedOut", cli: claude, version: cli, hint: login ? null : "Run `claude` in Terminal and log in." };
}

let models: Model[] | undefined;
const cacheFolder = process.env.ORICODE_CACHE;
let cache: Cache | undefined;

/// Hello's list: read once Claude Code is logged in, and the fallback until it is.
async function list(ready: Availability, tell: (models: ModelsEvent) => void): Promise<Model[]> {
  if (ready.state === "ready" && !models) {
    models = await startingModels(ready.cli!, ready.version, tell).catch((error) => {
      log(`supported models unavailable, using the fallback list: ${describe(error)}`);
      return undefined;
    });
  }
  return models ?? fallback;
}

const idle: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
const commandsByFolder = new Map<string, Promise<SlashCommand[]>>();

/// Commands for a folder when no thread there has a CLI yet: one probe with the user's and
/// the project's settings, kept for the engine's lifetime.
function folderCommands(claude: string, cwd: string): Promise<SlashCommand[]> {
  let found = commandsByFolder.get(cwd);
  if (!found) {
    found = (async () => {
      const probe = query({
        prompt: idle,
        options: { cwd, pathToClaudeCodeExecutable: claude, settingSources: ["user", "project", "local"], env: cleanEnvironment() },
      });
      try {
        return await probe.supportedCommands();
      } finally {
        probe.close();
      }
    })();
    found.catch(() => commandsByFolder.delete(cwd));
    commandsByFolder.set(cwd, found);
  }
  return found;
}

/// Claude Code is moving its list of models to the catalog it caches, behind a flag, and serves
/// that list only while its copy is fresh: the rows and their ids change from one launch to the
/// next. With the catalog off the probe lists the same rows every time, and the engine adds the
/// catalog's names, older models and newer ones itself.
async function supportedModels(claude: string): Promise<ModelInfo[]> {
  const env = { ...cleanEnvironment(), CLAUDE_CODE_MODEL_CATALOG: "0" };
  const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env, stderr: (data: string) => process.stderr.write(data), debugFile: cliDebugFile("probe") } });
  try {
    const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), 20000));
    return await Promise.race([probe.supportedModels(), timeout]);
  } finally {
    probe.close();
  }
}

async function listFrom(sdk: ModelInfo[]): Promise<Model[]> {
  const [catalog, settingsEffort] = await Promise.all([readCatalog(), readSettingsEffort()]);
  return helloList(sdk, catalog, settingsEffort);
}

/// Hello's list. The SDK's part comes from the cache while Claude Code is the version that gave
/// it, and a probe reads it again a minute after a launch that finds it a day old; the catalog
/// and the settings are read each time. The defaults follow as a `models` event, from the cache
/// while the list and the user's settings are the ones they were read under.
async function startingModels(claude: string, cli: string | null, tell: (models: ModelsEvent) => void): Promise<Model[]> {
  cache = await readCache(cacheFolder);
  const cached = cachedModels(cache, cli);
  if (cached) {
    const list = await listFrom(cached.models);
    if (cached.stale) setTimeout(() => void refresh(claude, tell), 60_000).unref();
    const known = cache?.defaults;
    if (known?.key === defaultsKey(list, await readSettings())) {
      tell({ models: known.models, settingsEffort: known.settingsEffort, ultraKnown: known.ultraKnown });
      return known.models;
    }
    void learnDefaults(claude, list, tell);
    return list;
  }
  const sdk = await supportedModels(claude);
  if (cli) {
    cache = { version: cli, at: Date.now(), models: sdk };
    await writeCache(cacheFolder, cache).catch((error) => log(`models cache not written: ${describe(error)}`));
  }
  const list = await listFrom(sdk);
  void learnDefaults(claude, list, tell);
  return list;
}

/// A day-old list read again. The defaults are read again with it, even for the same list, and
/// the `models` event carries both to the app.
async function refresh(claude: string, tell: (models: ModelsEvent) => void): Promise<void> {
  if (!cache) return;
  try {
    const sdk = await supportedModels(claude);
    cache = { version: cache.version, at: Date.now(), models: sdk };
    await writeCache(cacheFolder, cache);
    await learnDefaults(claude, await listFrom(sdk), tell);
  } catch (error) {
    log(`models list not read again: ${describe(error)}`);
  }
}

/// Each model's default effort and Ultracode, which take a model switch each in two idle CLIs,
/// the second launched with Ultracode on (about two seconds in all), so hello answers without
/// them and the list follows as a `models` event. The user's own settings are read, since an
/// effortLevel there is what a thread's default turns into, but not their hooks, which have no
/// business with a probe. A reading the CLIs can't give leaves that model on its fallback, and
/// the event goes out all the same.
async function learnDefaults(claude: string, base: Model[], tell: (models: ModelsEvent) => void): Promise<void> {
  const key = defaultsKey(base, await readSettings());
  const probe = query({
    prompt: idle,
    options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: ["user"], settings: { disableAllHooks: true }, env: cleanEnvironment() },
  });
  const ultraProbe = query({
    prompt: idle,
    options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: ["user"], settings: { disableAllHooks: true, ultracode: true }, env: cleanEnvironment() },
  });
  try {
    const learned = await withDefaults(probe, ultraProbe, base);
    for (const miss of learned.missed) {
      log(`model defaults: the ${miss.ultracode ? "Ultracode " : ""}probe missed ${miss.id}: ${describe(miss.error)}`);
    }
    models = learned.models;
    tell({ models, settingsEffort: learned.settingsEffort, ultraKnown: learned.ultraKnown });
    // A model a probe couldn't switch to keeps the default the catalog gives it until the daily
    // reading; a probe that never answered at all is asked again next launch.
    if (cache && !learned.missed.some((miss) => miss.id === "settings")) {
      cache.defaults = { key, models, settingsEffort: learned.settingsEffort, ultraKnown: learned.ultraKnown };
      await writeCache(cacheFolder, cache).catch((error) => log(`models cache not written: ${describe(error)}`));
    }
  } catch (error) {
    log(`model defaults unavailable: ${describe(error)}`);
  } finally {
    probe.close();
    ultraProbe.close();
  }
}

/// Whether the user's CLI would serve a model fast, asked without sending it anything: the
/// initialize handshake carries the state, and the reason when it can't be on.
async function fastCheck(claude: string, model: string | undefined): Promise<{ state: FastModeState; reason: FastModeDisabledReason | null }> {
  const probe = query({
    prompt: idle,
    options: { cwd: homedir(), model, pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment(), settings: { fastMode: true } },
  });
  try {
    const init = await probe.initializationResult();
    return { state: init.fast_mode_state ?? "off", reason: init.fast_mode_disabled_reason ?? null };
  } finally {
    probe.close();
  }
}

/// One small Haiku call, no tools and no settings, so hooks and MCP servers stay out of it.
async function oneShot(claude: string, cwd: string, prompt: string): Promise<string> {
  const call = query({
    prompt,
    options: { cwd, model: "haiku", tools: [], maxTurns: 1, settingSources: [], pathToClaudeCodeExecutable: claude, env: cleanEnvironment() },
  });
  let text = "";
  for await (const message of call) {
    if (message.type === "result") {
      if (message.subtype !== "success") throw new Error("Couldn't write a message just now.");
      text = message.result;
    }
  }
  return text.trim();
}

/// Claude Code, through the Agent SDK and the user's own CLI.
export const claude: Provider = {
  id: "claude",
  name: "Claude Code",
  agent: "Claude",
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
  missing,
  found: findClaude,
  availability,
  models: list,
  session: (threadId, cli) => new Thread(threadId, cli),
  fastCheck,
  folderCommands,
  usage,
  oneShot,
};
