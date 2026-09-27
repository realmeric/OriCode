import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { agentEnvironment } from "./acp.ts";
import type { Availability } from "./provider.ts";
import { lastLine } from "./shell.ts";
import { log } from "./wire.ts";

// Every agent OriCode knows, whether or not the user has turned it on in Settings › Agents, and
// what the engine knows of the ones turned on: where their CLI is, whether a key is kept for them,
// and which of the logins their makers forbid the user has turned on. An agent that isn't turned
// on is never looked for and never asked anything.

const run = promisify(execFile);

/// A login an agent offers that its maker keeps to its own apps. It stays off until the user
/// turns it on under the maker's sentence.
export type ForbiddenLogin = {
  /// The maker's id as the agent names it: pi's provider, or Google for Antigravity.
  id: string;
  title: string;
  maker: string;
  /// The maker's own words, or null where they couldn't be read to quote.
  sentence: string | null;
  url: string;
};

export type Agent = {
  id: string;
  /// Its maker's name for it.
  name: string;
  /// What a thread's lines call it.
  agent: string;
  /// How a thread on it runs.
  route: string;
  /// The names its CLI goes by, looked for in this order. None for a model API that runs
  /// through another agent's CLI.
  binaries: string[];
  /// What to do when its CLI isn't found.
  install: string | null;
  /// The one Terminal line that signs it in, as a hint.
  login: string | null;
  /// The variable its process takes a key in from the Keychain, for an agent that needs one.
  key: string | null;
  /// The agent whose CLI a model API runs in, once its route is wired: its threads are that
  /// agent's, pointed at the maker's endpoint with the key.
  through?: string;
  forbidden: ForbiddenLogin[];
  /// Whether the CLI says it's signed in, asked without reaching a model; null when it has no way
  /// to say short of a thread.
  signedIn?: (cli: string) => Promise<boolean | null>;
  /// The agent's own reading, where its session module has one.
  availability?: (cli: string, env: Record<string, string>) => Promise<Omit<Availability, "cli">>;
};

/// Exits 0 when the CLI says it's signed in.
function succeeds(...args: string[]): (cli: string) => Promise<boolean> {
  return (cli) =>
    run(cli, args, { env: agentEnvironment(), timeout: 10_000 }).then(
      () => true,
      () => false,
    );
}

export const agents: Agent[] = [
  {
    id: "claude",
    name: "Claude Code",
    agent: "Claude",
    route: "the Agent SDK",
    binaries: ["claude"],
    install: "Install Claude Code, then run `claude` in Terminal and log in.",
    login: "Run `claude` in Terminal and log in.",
    key: null,
    forbidden: [],
  },
  {
    id: "codex",
    name: "Codex",
    agent: "Codex",
    route: "its app-server",
    binaries: ["codex"],
    install: "Codex isn't installed. Install it with `npm install -g @openai/codex`, then run `codex login`.",
    login: "Run `codex login` in Terminal and log in.",
    key: null,
    forbidden: [],
    signedIn: succeeds("login", "status"),
  },
  {
    id: "cursor",
    name: "Cursor",
    agent: "Cursor",
    route: "ACP",
    binaries: ["cursor-agent", "agent"],
    install: "Cursor's CLI isn't installed. Install it with `curl https://cursor.com/install -fsS | bash`, then run `cursor-agent login`.",
    login: "Run `cursor-agent login` in Terminal.",
    key: null,
    forbidden: [],
    signedIn: async (cli) => {
      try {
        const { stdout } = await run(cli, ["status", "--format", "json"], { env: agentEnvironment(), timeout: 10_000 });
        return JSON.parse(stdout).isAuthenticated === true;
      } catch {
        return false;
      }
    },
  },
  {
    id: "copilot",
    name: "GitHub Copilot",
    agent: "Copilot",
    route: "ACP",
    binaries: ["copilot"],
    install: "Copilot's CLI isn't installed. Install it with `npm install -g @github/copilot`, then run `copilot login`.",
    login: "Run `copilot login` in Terminal.",
    key: null,
    forbidden: [],
  },
  {
    id: "opencode",
    name: "OpenCode",
    agent: "OpenCode",
    route: "ACP",
    binaries: ["opencode"],
    install: "OpenCode isn't installed. Install it with `brew install anomalyco/tap/opencode`.",
    login: "Run `opencode auth login` in Terminal.",
    key: null,
    forbidden: [],
    // Its free models need no login.
    signedIn: async () => true,
  },
  {
    id: "grok",
    name: "Grok Build",
    agent: "Grok",
    route: "ACP",
    binaries: ["grok"],
    install: "Grok Build isn't installed. Install it with `curl -fsSL https://x.ai/cli/install.sh | bash`, then run `grok login`.",
    login: "Run `grok login` in Terminal.",
    key: null,
    forbidden: [],
  },
  {
    id: "devin",
    name: "Devin",
    agent: "Devin",
    route: "ACP",
    binaries: ["devin"],
    install: "Devin isn't installed. Install it with `brew install --cask devin-cli`, then run `devin auth login`.",
    login: "Run `devin auth login` in Terminal.",
    key: null,
    forbidden: [],
  },
  {
    id: "pi",
    name: "Pi",
    agent: "Pi",
    route: "its RPC mode",
    binaries: ["pi"],
    install: "Pi isn't installed. Install it with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`, then run `pi` and /login.",
    login: "Run `pi` in Terminal, then /login.",
    key: null,
    forbidden: [
      {
        id: "anthropic",
        title: "Pi signed into claude.ai",
        maker: "Anthropic",
        sentence:
          "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Team, and Enterprise subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications.",
        url: "https://code.claude.com/docs/en/legal-and-compliance",
      },
      {
        id: "xai",
        title: "Pi signed into xAI",
        maker: "xAI",
        // x.ai answered every fetch with Cloudflare's 403 on 2026-09-26.
        sentence: null,
        url: "https://x.ai/legal/terms-of-service",
      },
      {
        id: "meta",
        title: "Pi signed into Meta",
        maker: "Meta",
        sentence: "This credential is for use with Muse Code only.",
        url: "https://dev.meta.ai/docs/muse-code/subscriptions",
      },
    ],
    // Imported when asked, so a launch doesn't parse Pi's session.
    availability: async (cli, env) => (await import("./pi.ts")).availability({ command: cli, env }),
  },
  {
    id: "antigravity",
    name: "Antigravity",
    agent: "Antigravity",
    route: "its stream-json mode",
    binaries: ["agy"],
    install: "Antigravity isn't installed. Install it with `curl -fsSL https://antigravity.google/cli/install.sh | bash`.",
    login: "Run `agy` in Terminal and sign in.",
    key: null,
    forbidden: [
      {
        id: "google",
        title: "Antigravity with a Google account",
        maker: "Google",
        sentence:
          "Using third party software, tools, or services to access the Service (e.g. using OpenClaw with Antigravity OAuth) is a breach of this Agreement. Such actions may be grounds for suspension or termination of your Antigravity and/or Gemini CLI accounts.",
        url: "https://antigravity.google/terms",
      },
    ],
  },
  {
    id: "commandcode",
    name: "Command Code",
    agent: "Command Code",
    route: "its headless JSON",
    binaries: ["cmd"],
    install: "Command Code isn't installed. Install it with `npm i -g command-code`.",
    login: "Add your Command Code key in Settings › Agents.",
    key: "COMMAND_CODE_API_KEY",
    forbidden: [],
    availability: async (cli, env) => (await import("./commandcode.ts")).availability({ command: cli, env }),
  },
  {
    id: "zai",
    name: "Z.ai",
    agent: "Z.ai",
    route: "Claude Code",
    binaries: [],
    install: null,
    login: "Add your Z.ai key in Settings › Agents.",
    key: "ANTHROPIC_AUTH_TOKEN",
    through: "claude",
    forbidden: [],
  },
  {
    id: "deepseek",
    name: "DeepSeek",
    agent: "DeepSeek",
    route: "Claude Code",
    binaries: [],
    install: null,
    login: "Add your DeepSeek key in Settings › Agents.",
    key: "ANTHROPIC_AUTH_TOKEN",
    through: "claude",
    forbidden: [],
  },
  {
    id: "openrouter",
    name: "OpenRouter",
    agent: "OpenRouter",
    route: "Claude Code",
    binaries: [],
    install: null,
    login: "Add your OpenRouter key in Settings › Agents.",
    key: "ANTHROPIC_AUTH_TOKEN",
    through: "claude",
    forbidden: [],
  },
  {
    id: "meta",
    name: "Meta",
    agent: "Meta",
    route: "Claude Code",
    binaries: [],
    install: null,
    login: "Add your Meta Model API key in Settings › Agents.",
    key: "ANTHROPIC_AUTH_TOKEN",
    through: "claude",
    forbidden: [],
  },
];

export function agent(id: string): Agent | undefined {
  return agents.find((candidate) => candidate.id === id);
}

/// The registry as the app lists it in Settings › Agents.
export function registry() {
  return agents.map(({ id, name, agent, route, binaries, key, forbidden }) => ({ id, name, agent, route, binary: binaries.length > 0, key: key !== null, forbidden }));
}

/// What the app says of an agent turned on: a CLI chosen in Settings, whether a key is kept for
/// it, and which forbidden logins are turned on.
export type Setting = { path?: string; key?: boolean; allow?: string[] };

/// The agents turned on. Claude Code always is.
const settings = new Map<string, Setting>([["claude", {}]]);
const paths = new Map<string, Promise<string | null>>();

/// The agents hello says are on, by id, beside Claude Code.
export function turnOn(on: Record<string, Setting> | undefined): void {
  for (const [id, setting] of Object.entries(on ?? {})) if (agent(id)) settings.set(id, setting);
}

export function isOn(id: string): boolean {
  return settings.has(id);
}

export function turnedOn(): Agent[] {
  return agents.filter((candidate) => settings.has(candidate.id));
}

/// Whether the user turned on a login the agent's maker forbids for third-party apps.
export function allows(id: string, login: string): boolean {
  return settings.get(id)?.allow?.includes(login) ?? false;
}

export function keyKept(id: string): boolean {
  return settings.get(id)?.key ?? false;
}

/// Settings › Agents changed an agent. Off, it's forgotten; on, with a new CLI, it's looked for again.
export function change(id: string, on: boolean, setting: Setting): void {
  if (!on && id !== "claude") {
    settings.delete(id);
    paths.delete(id);
    return;
  }
  if (settings.get(id)?.path !== setting.path) paths.delete(id);
  settings.set(id, setting);
}

/// The agent's CLI, or null. Found once, by the lookup that found every agent turned on with it;
/// one turned off is never looked for.
export function binary(id: string): Promise<string | null> {
  if (!settings.has(id)) return Promise.resolve(null);
  if (!paths.has(id)) lookUp([id]);
  return paths.get(id) ?? Promise.resolve(null);
}

/// Looks for every agent given that isn't found yet, in one login shell, which sees the PATH
/// Terminal does: Codex lives in ~/.local/bin, which only the user's profile adds. A CLI chosen
/// in Settings, or ORICODE_CLAUDE for Claude Code, is taken as it is when it runs.
export function lookUp(ids: string[], shell = "/bin/zsh"): void {
  const wanted = ids.flatMap((id) => {
    const found = agent(id);
    return found && settings.has(id) && found.binaries.length > 0 && !paths.has(id) ? [found] : [];
  });
  const searched = wanted.filter((found) => !chosen(found.id)).flatMap((found) => found.binaries);
  const onPath = searched.length > 0 ? whence(shell, searched) : Promise.resolve(new Map<string, string>());
  for (const found of wanted) paths.set(found.id, locate(found, onPath));
}

function chosen(id: string): string | undefined {
  return (id === "claude" ? process.env.ORICODE_CLAUDE : undefined) || settings.get(id)?.path || undefined;
}

async function locate(found: Agent, onPath: Promise<Map<string, string>>): Promise<string | null> {
  const choice = chosen(found.id);
  if (choice && (await executable(choice))) return choice;
  const seen = await onPath;
  for (const name of found.binaries) {
    const path = seen.get(name);
    if (path && (await executable(path))) return path;
  }
  // The login shell failed, or the profile doesn't add the folder the installer used.
  const folders = [join(homedir(), ".local/bin"), ...(found.id === "claude" ? [join(homedir(), ".claude/local")] : []), "/opt/homebrew/bin", "/usr/local/bin"];
  for (const folder of folders) {
    for (const name of found.binaries) if (await executable(join(folder, name))) return join(folder, name);
  }
  return null;
}

/// Each name's path as the login shell's PATH has it, aliases and functions left out, since the
/// engine runs a file.
async function whence(shell: string, names: string[]): Promise<Map<string, string>> {
  const script = names.map((name) => `print -r -- "${name}=$(whence -p ${name})"`).join("; ");
  const found = new Map<string, string>();
  try {
    const { stdout } = await run(shell, ["-lc", script], { timeout: 5000 });
    for (const line of stdout.split("\n")) {
      const match = /^([\w.-]+)=(\/.+)$/.exec(line);
      if (match && names.includes(match[1])) found.set(match[1], match[2]);
    }
  } catch (error) {
    log(`login shell lookup failed: ${(error as Error).message.split("\n")[0]}`);
  }
  return found;
}

async function executable(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

/// An agent turned on, as hello gives it without asking its CLI anything: missing, or found and
/// not yet asked whether it's signed in. A model API that runs through another agent goes by
/// whether a key is kept.
export async function unasked(entry: Agent): Promise<Availability> {
  if (entry.binaries.length === 0) return byKey(entry);
  const cli = await binary(entry.id);
  if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
  return { state: "unknown", cli, version: null, hint: null };
}

/// An agent turned on, asked: its version, and whether it's signed in where its CLI can say. One
/// that could run is `soon` until a later card wires its session into the engine.
export async function check(entry: Agent): Promise<Availability> {
  if (entry.binaries.length === 0) return byKey(entry);
  const cli = await binary(entry.id);
  if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
  if (entry.availability) {
    const own = await entry.availability(cli, await keyFor(entry.id));
    return { ...own, cli, state: own.state === "ready" ? "soon" : own.state };
  }
  const [version, signedIn] = await Promise.all([versionOf(cli), entry.signedIn?.(cli) ?? null]);
  if (signedIn === null) return { state: "unknown", cli, version, hint: null };
  return signedIn ? { state: "soon", cli, version, hint: null } : { state: "signedOut", cli, version, hint: entry.login };
}

/// A model API by whether a key is kept, and, for one that runs in another agent's CLI, whether
/// that CLI is found. Its login isn't asked: the key replaces it.
async function byKey(entry: Agent): Promise<Availability> {
  if (!keyKept(entry.id)) return { state: "signedOut", cli: null, version: null, hint: entry.login };
  if (!entry.through) return { state: "soon", cli: null, version: null, hint: null };
  const cli = await binary(entry.through);
  const host = agent(entry.through)!;
  if (!cli) return { state: "missing", cli: null, version: null, hint: `${entry.name} runs in ${host.name}, which isn't installed. Install ${host.name} to use it.` };
  return { state: "ready", cli, version: null, hint: null };
}

export async function versionOf(cli: string): Promise<string | null> {
  try {
    const { stdout } = await run(cli, ["--version"], { env: agentEnvironment(), timeout: 5000 });
    return stdout.trim().split("\n")[0] || null;
  } catch {
    return null;
  }
}

/// The Keychain item Settings › Agents keeps an agent's key in.
export function keyService(id: string): string {
  return `OriCode.${id}`;
}

/// The agent's key as its process takes it, read from the Keychain for the one process about to
/// start and never kept, logged or written anywhere. Empty when none is kept. `security` made the
/// item for the app, so it reads it back without asking for the login keychain's password.
export async function keyFor(id: string, security = "/usr/bin/security"): Promise<Record<string, string>> {
  const variable = agent(id)?.key;
  if (!variable || !keyKept(id)) return {};
  try {
    const { stdout } = await run(security, ["find-generic-password", "-s", keyService(id), "-a", id, "-w"], { timeout: 5000 });
    const key = stdout.trim();
    return key ? { [variable]: key } : {};
  } catch (error) {
    // Its message is the command line, which holds no key; stdout is left alone.
    log(`no key read for ${id}: ${lastLine((error as { stderr?: string }).stderr ?? "") || `exit ${(error as { code?: unknown }).code}`}`);
    return {};
  }
}
