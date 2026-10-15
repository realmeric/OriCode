import { agent, binary, isOn, versionOf } from "./agents.ts";
import { availability, CodexSession, listModels, threadEvents, threadsIn, usage } from "./codex.ts";
import type { Model } from "./models.ts";
import { client, type Availability, type Provider } from "./provider.ts";
import { perSource, type Found, type Source } from "./sessions.ts";

// Codex behind the Provider seam: the user's own codex, found by the one login shell agents.ts
// runs, and a thread's session one `codex app-server` of its own.

const entry = agent("codex")!;

const versions = new Map<string, Promise<string | null>>();

/// Whether Codex can run: `codex login status`, as Terminal would ask it, and the version, read
/// once for each CLI like Claude Code's.
async function check(): Promise<Availability> {
  if (!isOn(entry.id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
  const cli = await binary(entry.id);
  if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
  if (!versions.has(cli)) versions.set(cli, versionOf(cli));
  const [found, version] = await Promise.all([availability({ command: cli }), versions.get(cli)!]);
  return { state: found.state, cli, version, hint: found.hint };
}

/// Codex's models as the menu lists them, its default first. Ultra comes as the model's
/// Ultracode, and none has fast mode.
async function models(cli: string): Promise<Model[]> {
  const listed = await listModels({ command: cli });
  return listed
    .sort((a, b) => Number(b.isDefault) - Number(a.isDefault))
    .map(({ id, name, description, efforts, defaultEffort, ultra }) => ({ id, name, description, efforts, fast: false, defaultEffort, ultra, ultraBlocked: null }));
}

export const codex: Provider = {
  id: entry.id,
  name: entry.name,
  agent: entry.agent,
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
    // Without the shared background server, which would keep the thread after the block quits.
    handoff: "codex resume --no-daemon {session}",
    workers: true,
  },
  levels: ["low", "medium", "high", "xhigh", "max", "ultracode"],
  modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  missing: entry.install!,
  found: () => binary(entry.id),
  availability: check,
  models: async (ready) => (ready.state === "ready" && ready.cli ? models(ready.cli) : []),
  listModels: models,
  session: (threadId, cli) => new CodexSession(threadId, { command: cli }),
  usage: (cli) => usage({ command: cli }),
};

/// The user's Codex threads, from its CLI's and its app's alike, while Codex is turned on in
/// Settings › Agents. Each picks up on Codex by its id. OriCode's own are threads already.
export const codexThreads: Source = {
  id: entry.id,
  name: entry.name,
  async list(folder) {
    const cli = await binary(entry.id);
    if (!cli) return [];
    const found: Found[] = [];
    for (const thread of await threadsIn({ command: cli }, [folder.path, folder.real], perSource)) {
      if (thread.originator === client || !(await folder.holds(thread.cwd))) continue;
      const title = thread.name?.trim() || thread.preview.split("\n").find((line) => line.trim())?.trim() || "Untitled thread";
      found.push({ id: thread.id, agent: entry.id, sessionId: thread.id, title, modified: thread.updatedAt * 1000, branch: thread.gitInfo?.branch ?? null });
    }
    return found;
  },
  async read(id) {
    const cli = await binary(entry.id);
    if (!cli) throw new Error(`${entry.name} is off in Settings › Agents, or isn't installed.`);
    return threadEvents({ command: cli }, id);
  },
};
