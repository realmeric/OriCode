import type { query } from "@anthropic-ai/claude-agent-sdk";
import { agent, check, isOn, keyFor } from "./agents.ts";
import { claude, cleanEnvironment, oneShot } from "./claude.ts";
import type { Model } from "./models.ts";
import { openRouterModels } from "./openrouter.ts";
import type { Provider } from "./provider.ts";
import { Thread } from "./thread.ts";

// A model API whose maker publishes an Anthropic-compatible endpoint for Claude Code: a thread on
// it is the user's own Claude Code, all of it, started with the maker's endpoint and the key
// from the Keychain. The key outranks the claude.ai login, so the login is never sent to the
// maker: Claude Code's credential order puts ANTHROPIC_AUTH_TOKEN second, the subscription's
// OAuth last (code.claude.com/docs/en/authentication).

export type Maker = {
  id: string;
  /// The endpoint the maker's Claude Code page gives.
  url: string;
  /// The variables that page sets beside the endpoint and the key: the models Claude Code's
  /// aliases stand for, and the maker's own tuning. A maker with many models sets them from the
  /// thread's.
  env: Record<string, string> | ((model: string) => Record<string, string>);
  models: Model[];
  /// Where the models come from when they aren't known ahead.
  list?: () => Promise<Model[]>;
  levels: string[];
};

function model(id: string, name: string, description: string, efforts: string[]): Model {
  return { id, name, description, efforts, fast: false, defaultEffort: null, ultra: false, ultraBlocked: null };
}

/// docs.z.ai/devpack/tool/claude. GLM always thinks and takes no level.
export const zaiMaker: Maker = {
  id: "zai",
  url: "https://api.z.ai/api/anthropic",
  env: {
    ANTHROPIC_DEFAULT_OPUS_MODEL: "glm-5.3[1m]",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "glm-5.3[1m]",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "glm-5.3-flash[1m]",
    CLAUDE_CODE_AUTO_COMPACT_WINDOW: "1000000",
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    API_TIMEOUT_MS: "3000000",
  },
  models: [
    model("glm-5.3[1m]", "GLM-5.3", "1M context", []),
    model("glm-5.3-flash[1m]", "GLM-5.3-Flash", "1M context", []),
  ],
  levels: [],
};

/// api-docs.deepseek.com/quick_start/agent_integrations/claude_code. Its page also sets
/// CLAUDE_CODE_EFFORT_LEVEL=max, which would outrank the level a thread picks, so it's left out;
/// the endpoint takes low, high and max (api-docs.deepseek.com/guides/thinking_mode).
export const deepseekMaker: Maker = {
  id: "deepseek",
  url: "https://api.deepseek.com/anthropic",
  env: {
    ANTHROPIC_DEFAULT_OPUS_MODEL: "deepseek-flash[1m]",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "deepseek-flash[1m]",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "deepseek-flash",
    CLAUDE_CODE_SUBAGENT_MODEL: "deepseek-flash",
    CLAUDE_CODE_AUTO_COMPACT_WINDOW: "786432",
  },
  models: [
    model("deepseek-v4-pro[1m]", "DeepSeek V4 Pro", "1M context", ["low", "high", "max"]),
    model("deepseek-flash[1m]", "DeepSeek Flash", "1M context", ["low", "high", "max"]),
  ],
  levels: ["low", "high", "max"],
};

/// openrouter.ai/docs/cookbook/coding-agents/claude-code-integration: its "Anthropic Skin" with
/// ANTHROPIC_API_KEY empty. Every alias and subagent runs on the thread's model, so a background
/// task never bills a Claude model the thread didn't pick.
export const openRouterMaker: Maker = {
  id: "openrouter",
  url: "https://openrouter.ai/api",
  env: (model) => ({
    ANTHROPIC_API_KEY: "",
    ANTHROPIC_DEFAULT_FABLE_MODEL: model,
    ANTHROPIC_DEFAULT_OPUS_MODEL: model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: model,
    ANTHROPIC_DEFAULT_HAIKU_MODEL: model,
    CLAUDE_CODE_SUBAGENT_MODEL: model,
  }),
  models: [],
  list: openRouterModels,
  levels: ["low", "medium", "high", "xhigh", "max"],
};

/// dev.meta.ai/docs/coding-agents, through Meta Model API's Messages API. Muse Spark always
/// reasons, and the Messages API passes low to xhigh through (dev.meta.ai/docs/protocols/messages).
export const metaMaker: Maker = {
  id: "meta",
  url: "https://api.meta.ai",
  env: {
    ANTHROPIC_DEFAULT_OPUS_MODEL: "muse-spark-1.3[1m]",
    ANTHROPIC_DEFAULT_SONNET_MODEL: "muse-spark-1.3[1m]",
    ANTHROPIC_DEFAULT_HAIKU_MODEL: "muse-spark-1.3[1m]",
    CLAUDE_CODE_SUBAGENT_MODEL: "muse-spark-1.3",
    ENABLE_TOOL_SEARCH: "true",
  },
  models: [model("muse-spark-1.3[1m]", "Muse Spark 1.3", "1M context", ["low", "medium", "high", "xhigh"])],
  levels: ["low", "medium", "high", "xhigh"],
};

function models(maker: Maker): Promise<Model[]> {
  return maker.list ? maker.list() : Promise.resolve(maker.models);
}

/// Claude Code's environment with every Anthropic credential and endpoint taken out, and the
/// maker's put in. Without a key it refuses: the endpoint alone would carry the claude.ai login.
async function environment(maker: Maker, name: string, security?: string, model?: string): Promise<Record<string, string | undefined>> {
  const key = (await keyFor(maker.id, security)).ANTHROPIC_AUTH_TOKEN;
  if (!key) throw new Error(`No ${name} key was found in your Keychain. Add it again in Settings › Agents.`);
  const env = cleanEnvironment();
  for (const variable of Object.keys(env)) if (variable.startsWith("ANTHROPIC_")) delete env[variable];
  // A thread that names no model gets the maker's first rather than the one the user's settings name.
  const chosen = model ?? (await models(maker))[0].id;
  const own = typeof maker.env === "function" ? maker.env(chosen) : maker.env;
  return { ...env, ANTHROPIC_MODEL: chosen, ...own, ANTHROPIC_BASE_URL: maker.url, ANTHROPIC_AUTH_TOKEN: key };
}

/// Tests stand in for /usr/bin/security and for the SDK's query.
export function claudeCompatible(maker: Maker, { security, launch }: { security?: string; launch?: typeof query } = {}): Provider {
  const entry = agent(maker.id)!;
  return {
    id: entry.id,
    name: entry.name,
    agent: entry.agent,
    capabilities: {
      steer: true,
      resume: true,
      modeLive: true,
      attachments: true,
      heads: false,
      stopTask: false,
      limits: false,
      usage: false,
      commands: true,
      compact: true,
      commitMessage: true,
      // `claude --resume` in Terminal would go to Anthropic with the login.
      handoff: null,
      workers: true,
    },
    levels: maker.levels,
    modes: claude.modes,
    missing: `${entry.name} runs in Claude Code, which isn't installed. Install Claude Code to use it.`,
    found: claude.found,
    availability: async () => {
      if (!isOn(entry.id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
      return check(entry);
    },
    models: async (ready) => (ready.state === "ready" ? models(maker) : []),
    listModels: () => models(maker),
    session: (threadId, cli) => new Thread(threadId, cli, launch, { agent: entry.agent, environment: (model) => environment(maker, entry.name, security, model) }),
    folderCommands: claude.folderCommands,
    oneShot: async (cli, cwd, prompt) => oneShot(cli, cwd, prompt, await environment(maker, entry.name, security)),
  };
}

export const zai = claudeCompatible(zaiMaker);
export const deepseek = claudeCompatible(deepseekMaker);
export const openrouter = claudeCompatible(openRouterMaker);
export const meta = claudeCompatible(metaMaker);
