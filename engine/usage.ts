import { homedir } from "node:os";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { within } from "./child.ts";
import { cleanEnvironment } from "./claude.ts";
import { sdk } from "./sdk.ts";

export type UsageWindow = { id: string; label: string; used: number | null; resetsAt: string | null };
/// A reset the account was granted, which the agent's own CLI can spend on its limits.
export type UsageReset = { id: string; title: string | null; expiresAt: string | null };
/// `at` is when the numbers were read from the plan, in milliseconds, which for Claude Code can
/// be minutes before the ask: its CLI keeps the endpoint's answer and gives it again.
export type Usage = { available: boolean; plan: string | null; windows: UsageWindow[]; at?: number; resets?: UsageReset[] };

type Limit = { utilization: number | null; resets_at: string | null } | null | undefined;
/// One of the server's usage rows, as /usage draws them.
type Row = { kind: string; percent: number | null; resets_at: string | null; scope?: { model?: { display_name: string } | null; surface?: { display_name: string } | null } | null };

/// The windows worth naming, in the order a person asks about them, for a CLI whose answer
/// carries no rows of the server's. The response also carries codenamed windows nobody could
/// label, which are left out.
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
/// holds a token. Each ask spawns the CLI for about a second, so an answer is kept a minute,
/// and not past a reset it names.
export function usage(claude: string): Promise<Usage> {
  if (cached && Date.now() - cached.at < 60_000 && !passed(cached.usage)) return Promise.resolve(cached.usage);
  inFlight ??= (async () => {
    const { query } = await sdk();
    const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment() } });
    try {
      const answer = await within(probe.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }), 20_000, "Claude Code's usage");
      const result = usageOf(answer as { rate_limits_available: boolean; subscription_type: string | null; rate_limits: unknown });
      // A probe that came up before the plan answered has no window to show; the next ask tries again.
      if (result.windows.length > 0 || !result.available) cached = { at: Date.now(), usage: result };
      return result;
    } finally {
      probe.close();
      inFlight = undefined;
    }
  })();
  return inFlight;
}

/// The CLI's answer as the app draws it. The server's own rows come first, as /usage draws them;
/// a CLI that sends none, or one giving an answer it kept, has only the keyed windows.
export function usageOf(answer: { rate_limits_available: boolean; subscription_type: string | null; rate_limits: unknown }, now = Date.now()): Usage {
  const limits = (answer.rate_limits ?? {}) as Record<string, unknown>;
  const rows = Array.isArray(limits.limits) ? (limits.limits as Row[]) : undefined;
  const windows = rows ? rows.flatMap(windowOf) : keyed(limits);
  // The breakdown is dated by the fetch it came with, which is the reading's age.
  const asOf = Date.parse(((limits.seven_day_breakdown ?? {}) as { as_of?: string }).as_of ?? "");
  return { available: answer.rate_limits_available, plan: answer.subscription_type, windows, at: Number.isFinite(asOf) ? Math.min(asOf, now) : now };
}

function windowOf(row: Row): UsageWindow[] {
  const used = percent(row.percent);
  const scope = row.scope?.model?.display_name ?? row.scope?.surface?.display_name;
  switch (row.kind) {
    case "session":
      return [{ id: "five_hour", label: "Session", used, resetsAt: row.resets_at }];
    case "weekly_all":
      return [{ id: "seven_day", label: "Week", used, resetsAt: row.resets_at }];
    case "weekly_scoped":
      return scope ? [{ id: `model:${scope}`, label: `${scope} week`, used, resetsAt: row.resets_at }] : [];
    default:
      // A meter this engine doesn't know yet, drawn under the name the server scoped it to.
      return scope ? [{ id: `${row.kind}:${scope}`, label: scope, used, resetsAt: row.resets_at }] : [];
  }
}

function keyed(limits: Record<string, unknown>): UsageWindow[] {
  const windows: UsageWindow[] = [];
  for (const [id, label] of named) {
    const limit = limits[id] as Limit;
    if (limit) windows.push({ id, label, used: percent(limit.utilization), resetsAt: limit.resets_at });
  }
  const scoped = (limits.model_scoped ?? []) as { display_name: string; utilization: number | null; resets_at: string | null }[];
  for (const limit of scoped) {
    windows.push({ id: `model:${limit.display_name}`, label: `${limit.display_name} week`, used: percent(limit.utilization), resetsAt: limit.resets_at });
  }
  return windows;
}

/// Whether a window the answer names has reset since, which makes the answer old.
export function passed(usage: Usage, now = Date.now()): boolean {
  return usage.windows.some((window) => window.resetsAt !== null && Date.parse(window.resetsAt) <= now);
}

/// The API reports percentages; the app draws fractions.
function percent(value: number | null): number | null {
  return value === null ? null : value / 100;
}
