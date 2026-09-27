import { agent, binary, isOn, versionOf } from "./agents.ts";
import { availability, CodexSession, listModels, usage } from "./codex.ts";
import type { Model } from "./models.ts";
import type { Availability, Provider } from "./provider.ts";

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
