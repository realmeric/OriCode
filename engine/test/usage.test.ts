import assert from "node:assert/strict";
import test from "node:test";
import { limitsOf, merge, usageOf as codexUsage } from "../codex.ts";
import { passed, usageOf } from "../usage.ts";

// Claude Code 2.1.319's get_usage answers, cut to what is read: a fresh fetch carries the
// server's rows, and one the CLI kept from an earlier fetch has only the keyed windows.
const week = { utilization: 85, resets_at: "2026-11-20T20:59:59.181803+00:00" };
const fresh = {
  rate_limits_available: true,
  subscription_type: "max",
  rate_limits: {
    five_hour: { utilization: 31, resets_at: "2026-11-18T00:50:00.181780+00:00" },
    seven_day: week,
    limits: [
      { kind: "session", group: "session", percent: 31, severity: "normal", resets_at: "2026-11-18T00:50:00.181780+00:00", scope: null, is_active: false },
      { kind: "weekly_all", group: "weekly", percent: 85, severity: "warning", resets_at: week.resets_at, scope: null, is_active: true },
      { kind: "weekly_scoped", group: "weekly", percent: 55, severity: "normal", resets_at: "2026-11-20T21:00:00.181970+00:00", scope: { model: { id: null, display_name: "Fable" }, surface: null }, is_active: false },
    ],
    seven_day_breakdown: { as_of: "2026-11-17T19:53:28.199599+00:00" },
    model_scoped: [{ display_name: "Fable", utilization: 55, resets_at: "2026-11-20T21:00:00.181970+00:00" }],
  },
};
const now = Date.parse("2026-11-17T19:57:46Z");

test("the server's rows are drawn as /usage draws them, dated by the fetch they came from", () => {
  const usage = usageOf(fresh, now);
  assert.deepEqual(
    usage.windows.map((window) => [window.id, window.label, window.used]),
    [["five_hour", "Session", 0.31], ["seven_day", "Week", 0.85], ["model:Fable", "Fable week", 0.55]],
  );
  assert.equal(usage.at, Date.parse("2026-11-17T19:53:28.199Z"));
});

test("an answer the CLI kept, with no rows, still has every window it names", () => {
  const { limits: _, ...kept } = fresh.rate_limits;
  const usage = usageOf({ ...fresh, rate_limits: kept }, now);
  assert.deepEqual(usage.windows.map((window) => window.id), ["five_hour", "seven_day", "model:Fable"]);
  // Without the breakdown's date, it is as old as the ask.
  const { seven_day_breakdown: __, ...undated } = kept;
  assert.equal(usageOf({ ...fresh, rate_limits: undated }, now).at, now);
});

test("an answer that names a reset since passed is old", () => {
  const usage = usageOf(fresh, now);
  assert.equal(passed(usage, now), false);
  assert.equal(passed(usage, Date.parse("2026-11-18T00:51:00Z")), true);
});

test("Codex's rolling update keeps what it leaves out, and a bucket of its own stays apart", () => {
  const known = { limitId: "codex", primary: { usedPercent: 40, windowDurationMins: 300, resetsAt: 10 }, secondary: { usedPercent: 70, windowDurationMins: 10080, resetsAt: 20 }, planType: "plus", rateLimitReachedType: null };
  const merged = merge(known, { limitId: "codex", primary: { usedPercent: 45, windowDurationMins: 300, resetsAt: 10 }, secondary: null, planType: null, rateLimitReachedType: null });
  assert.deepEqual(limitsOf(merged).windows.map((window) => [window.id, window.used]), [["five_hour", 0.45], ["seven_day", 0.7]]);
  assert.equal(merged.planType, "plus");
  const other = limitsOf({ limitId: "codex_other", limitName: "GPT Large", primary: { usedPercent: 10, windowDurationMins: 10080, resetsAt: 30 }, secondary: null, planType: null, rateLimitReachedType: null });
  assert.deepEqual(other.windows.map((window) => [window.id, window.label]), [["codex_other:seven_day", "GPT Large 7-day window"]]);
});

test("Codex's read lists every bucket, the plan's first", () => {
  const bucket = (limitId: string, usedPercent: number) => ({ limitId, primary: { usedPercent, windowDurationMins: 43200, resetsAt: 1796751044 }, secondary: null, planType: "go", rateLimitReachedType: null });
  const usage = codexUsage({
    rateLimits: bucket("codex", 100),
    rateLimitsByLimitId: { other: bucket("other", 5), codex: bucket("codex", 100) },
  });
  assert.deepEqual(usage.windows.map((window) => [window.id, window.used]), [["30_day", 1], ["other:30_day", 0.05]]);
});
