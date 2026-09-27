import { agent, binary, isOn, keyFor } from "./agents.ts";
import { availability, CommandCodeSession, listModels } from "./commandcode.ts";
import type { Model } from "./models.ts";
import type { Provider } from "./provider.ts";

// Command Code behind the Provider seam: the user's own cmd, one headless run a turn, with the
// key Settings › Agents keeps in the Keychain read for each process it starts and put in that
// process alone. Without a key, a `cmd login` the user made counts, which cmd decides for itself.
// DO_NOT_TRACK is left as the user's environment has it: whether cmd sends its telemetry is
// Meriç's to decide.

/// Tests stand in for /usr/bin/security.
export function commandCode({ security }: { security?: string } = {}): Provider {
  const entry = agent("commandcode")!;
  const key = () => keyFor(entry.id, security);
  // `cmd --list-models` takes seconds, and its list doesn't change while the engine runs.
  const lists = new Map<string, Promise<Model[]>>();

  async function read(cli: string): Promise<Model[]> {
    const listed = await listModels({ command: cli, env: await key() });
    return listed
      .sort((a, b) => Number(b.isDefault) - Number(a.isDefault))
      .map(({ id, description }) => ({ id, name: id.slice(id.lastIndexOf("/") + 1), description, efforts: [], fast: false, defaultEffort: null, ultra: false, ultraBlocked: null }));
  }

  function models(cli: string): Promise<Model[]> {
    if (!lists.has(cli)) lists.set(cli, read(cli).catch((error) => (lists.delete(cli), Promise.reject(error))));
    return lists.get(cli)!;
  }

  return {
    id: entry.id,
    name: entry.name,
    agent: entry.agent,
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
    // cmd's levels depend on the model, and its list doesn't say which a model takes.
    levels: [],
    // Headless, only --yolo writes: Accept edits and Auto would edit nothing.
    modes: ["default", "plan", "bypassPermissions"],
    missing: entry.install!,
    found: () => binary(entry.id),
    availability: async () => {
      if (!isOn(entry.id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
      const cli = await binary(entry.id);
      if (!cli) return { state: "missing", cli: null, version: null, hint: entry.install };
      return { ...(await availability({ command: cli, env: await key() })), cli };
    },
    models: async (ready) => (ready.state === "ready" && ready.cli ? models(ready.cli) : []),
    listModels: models,
    session: (threadId, cli) => new CommandCodeSession(threadId, { command: cli, key }),
  };
}

export const commandcode = commandCode();
