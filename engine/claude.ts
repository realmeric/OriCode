import { mkdir, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { query, type FastModeDisabledReason, type FastModeState, type ModelInfo, type SDKUserMessage, type SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { agent, binary } from "./agents.ts";
import { cachedModels, defaultsKey, readCache, writeCache, type Cache } from "./cache.ts";
import { run, within } from "./child.ts";
import { readCatalog, readSettings, readSettingsEffort } from "./catalog.ts";
import { fallback, helloList, withDefaults, type Model } from "./models.ts";
import type { Availability, ModelsEvent, Provider } from "./provider.ts";
import { describe, Thread } from "./thread.ts";
import { usage } from "./usage.ts";
import { version } from "./version.ts";
import { log } from "./wire.ts";

/// The `claude` the user installed and logged into, found with every other agent turned on in the
/// one login shell agents.ts runs. The SDK's own bundled CLI is left out of the app on purpose,
/// so this is the only one the engine will run.
export function findClaude(): Promise<string | null> {
  return binary("claude");
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

const versions = new Map<string, Promise<string | null>>();

/// Whether Claude Code can run, asked of the CLI the way hello always has. The version is read
/// once for each CLI, like its path, so a check after a login in Terminal asks only for the login.
async function availability(): Promise<Availability> {
  const claude = await findClaude();
  const entry = agent("claude")!;
  if (!claude) return { state: "missing", cli: null, version: null, hint: entry.install };
  let version = versions.get(claude);
  if (!version) versions.set(claude, (version = claudeVersion(claude)));
  const [login, cli] = await Promise.all([loggedIn(claude), version]);
  void remember(claude, cli, login);
  return { state: login ? "ready" : "signedOut", cli: claude, version: cli, hint: login ? null : entry.login };
}

/// What the last check found when Claude Code was signed in, for hello to answer with while
/// `claude auth status` is asked again behind it. It names the CLI's file, so an update or a
/// different `claude` is asked in full, and holds no login: the CLI said it has one, that's all.
type Remembered = { cli: string; stamp: string; version: string | null };

async function stampOf(cli: string): Promise<string | undefined> {
  try {
    const real = await realpath(cli);
    const { mtimeMs, size } = await stat(real);
    return `${real}:${mtimeMs}:${size}`;
  } catch {
    return undefined;
  }
}

async function remember(cli: string, version: string | null, signedIn: boolean): Promise<void> {
  if (!cacheFolder) return;
  const file = join(cacheFolder, "login.json");
  try {
    if (!signedIn) return await rm(file, { force: true });
    const stamp = await stampOf(cli);
    if (!stamp) return;
    await mkdir(cacheFolder, { recursive: true });
    await writeFile(file, JSON.stringify({ cli, stamp, version } satisfies Remembered));
  } catch (error) {
    log(`login not remembered: ${describe(error)}`);
  }
}

/// Claude Code as the last check found it, or undefined when it found none, found it signed out,
/// or the CLI has changed since.
async function remembered(): Promise<Availability | undefined> {
  if (!cacheFolder) return undefined;
  try {
    const [cli, text] = await Promise.all([findClaude(), readFile(join(cacheFolder, "login.json"), "utf8")]);
    const known = JSON.parse(text) as Remembered;
    if (!cli || known.cli !== cli || known.stamp !== (await stampOf(cli))) return undefined;
    versions.set(cli, Promise.resolve(known.version));
    return { state: "ready", cli, version: known.version, hint: null };
  } catch {
    return undefined;
  }
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
        return await within(probe.supportedCommands(), 30_000, "Claude Code's commands");
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
    return await within(probe.supportedModels(), 20_000, "Claude Code's models");
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
    const learned = await within(withDefaults(probe, ultraProbe, base), 60_000, "Claude Code's model defaults");
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
    const init = await within(probe.initializationResult(), 20_000, "Claude Code's fast mode");
    return { state: init.fast_mode_state ?? "off", reason: init.fast_mode_disabled_reason ?? null };
  } finally {
    probe.close();
  }
}

/// One small Haiku call, no tools and no settings, so hooks and MCP servers stay out of it. On
/// another maker's endpoint `env` points Haiku at that maker's small model.
export async function oneShot(claude: string, cwd: string, prompt: string, env = cleanEnvironment()): Promise<string> {
  const call = query({
    prompt,
    options: { cwd, model: "haiku", tools: [], maxTurns: 1, settingSources: [], pathToClaudeCodeExecutable: claude, env },
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
    workers: true,
  },
  levels: ["low", "medium", "high", "xhigh", "max", "ultracode"],
  modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  missing,
  found: findClaude,
  availability,
  remembered,
  models: list,
  session: (threadId, cli) => new Thread(threadId, cli),
  fastCheck,
  folderCommands,
  usage,
  oneShot,
};
