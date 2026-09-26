import { homedir } from "node:os";
import { query, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment } from "./claude.ts";

export type UsageWindow = { id: string; label: string; used: number | null; resetsAt: string | null };
export type Usage = { available: boolean; plan: string | null; windows: UsageWindow[] };

type Limit = { utilization: number | null; resets_at: string | null } | null | undefined;

/// The windows worth naming, in the order a person asks about them. The response also
/// carries codenamed windows nobody could label, which are left out.
const named: [string, string][] = [
  ["five_hour", "Session"],
  ["seven_day", "Week"],
  ["seven_day_opus", "Opus week"],
  ["seven_day_sonnet", "Sonnet week"],
];

const idle: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
let cached: { at: number; usage: Usage } | undefined;
let inFlight: Promise<Usage> | undefined;

/// Plan usage the way `/usage` reports it, asked of the user's own CLI so the engine never
/// holds a token. Each ask spawns the CLI for about a second, so an answer is kept a minute.
export function usage(claude: string): Promise<Usage> {
  if (cached && Date.now() - cached.at < 60_000) return Promise.resolve(cached.usage);
  inFlight ??= (async () => {
    const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment() } });
    try {
      const answer = await probe.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true });
      const limits = (answer.rate_limits ?? {}) as Record<string, unknown>;
      const windows: UsageWindow[] = [];
      for (const [id, label] of named) {
        const limit = limits[id] as Limit;
        if (limit) windows.push({ id, label, used: percent(limit.utilization), resetsAt: limit.resets_at });
      }
      const scoped = (limits.model_scoped ?? []) as { display_name: string; utilization: number | null; resets_at: string | null }[];
      for (const limit of scoped) {
        windows.push({ id: `model:${limit.display_name}`, label: `${limit.display_name} week`, used: percent(limit.utilization), resetsAt: limit.resets_at });
      }
      const result = { available: answer.rate_limits_available, plan: answer.subscription_type, windows };
      cached = { at: Date.now(), usage: result };
      return result;
    } finally {
      probe.close();
      inFlight = undefined;
    }
  })();
  return inFlight;
}

/// The API reports percentages; the app draws fractions.
function percent(value: number | null): number | null {
  return value === null ? null : value / 100;
}
