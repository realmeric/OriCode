import { tmpdir } from "node:os";
import { AcpSession, listModels, type AcpAgent } from "./acp.ts";
import { agent, binary, check, isOn } from "./agents.ts";
import type { Model } from "./models.ts";
import type { Provider } from "./provider.ts";
import { describe } from "./thread.ts";
import { log } from "./wire.ts";

// A Provider for an agent that speaks the Agent Client Protocol: Cursor, Copilot, OpenCode, Grok
// Build and Devin are each an entry in agents.ts, how its binary is started, and its quirks.

export type AcpEntry = {
  /// Its id in agents.ts, whose entry says where its CLI is and how to sign it in.
  id: string;
  /// `acp` for `opencode acp`, `--acp` for `copilot --acp`.
  args: string[];
  env?: Record<string, string>;
  authMethod?: string;
  permissions?: AcpAgent["permissions"];
  allowAlways?: string;
  strays?: boolean;
  textErrors?: boolean;
  /// What its initialize says, which hello needs before any agent has started: whether a
  /// session can be picked up (sessionCapabilities.resume or loadSession), whether it sees
  /// images (promptCapabilities.image), and whether a new mode reaches a running session.
  resume: boolean;
  images: boolean;
  modeLive: boolean;
  /// The Terminal line that opens a thread's session in the agent's own CLI.
  handoff: string | null;
  /// The values of its thought_level option, for an agent that has one.
  levels?: string[];
  /// The permission modes a thread on it picks from, the SDK's ids, which `permissions` turns
  /// into its own.
  modes: string[];
  /// Deletes a session the engine opened only to read the models, for an agent that keeps every
  /// session it opens.
  forget?: (cli: string, sessionId: string) => Promise<unknown>;
  /// Which of the models listed the user's plan runs, and how the agent names them, for an agent
  /// whose list shows more than the plan allows. Asked while the session that lists them opens.
  runs?: (cli: string) => Promise<(models: Model[]) => Model[]>;
};

export function acpProvider(entry: AcpEntry): Provider {
  const known = agent(entry.id)!;
  const started = (cli: string): AcpAgent => ({
    name: known.name,
    command: cli,
    args: entry.args,
    env: entry.env,
    authMethod: entry.authMethod,
    permissions: entry.permissions,
    allowAlways: entry.allowAlways,
    strays: entry.strays,
    textErrors: entry.textErrors,
  });
  /// The models a session offers, from one opened for nothing else.
  async function offered(cli: string): Promise<Model[]> {
    const plan = entry.runs?.(cli);
    const session = new AcpSession(`${entry.id}-models`, started(cli));
    const sessionId = await session.peek(tmpdir());
    if (sessionId && entry.forget) void entry.forget(cli, sessionId).catch((error) => log(`${known.name} kept session ${sessionId}: ${describe(error)}`));
    const { current, models } = listModels(session);
    // The agent's own default first, which a thread on it with no model runs.
    const ordered = [...models.filter((model) => model.id === current), ...models.filter((model) => model.id !== current)];
    const listed = ordered.map(
      (model): Model => ({
        id: model.id,
        name: model.name,
        description: model.description ?? "",
        efforts: entry.levels ?? [],
        fast: false,
        defaultEffort: null,
        ultra: false,
        ultraBlocked: null,
      }),
    );
    return plan ? (await plan)(listed) : listed;
  }
  return {
    id: entry.id,
    name: known.name,
    agent: known.agent,
    capabilities: {
      steer: false,
      resume: entry.resume,
      modeLive: entry.modeLive,
      attachments: entry.images,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: true,
      compact: false,
      commitMessage: false,
      handoff: entry.handoff,
    },
    levels: entry.levels ?? [],
    modes: entry.modes,
    missing: known.install ?? `${known.name} isn't installed.`,
    found: () => binary(entry.id),
    // The registry's check, whose `soon` is found and signed in with no session in the engine,
    // which this is.
    async availability() {
      if (!isOn(entry.id)) throw new Error(`${known.name} is off in Settings › Agents.`);
      const found = await check(known);
      return found.state === "soon" ? { ...found, state: "ready" } : found;
    },
    // Read after a check finds it ready, which only Settings, a menu or a pick-up asks for, as
    // `models` events; and by models.list.
    models: async (ready) => (ready.state === "ready" && ready.cli ? offered(ready.cli) : []),
    listModels: offered,
    session: (threadId, cli) => new AcpSession(threadId, started(cli)),
  };
}
