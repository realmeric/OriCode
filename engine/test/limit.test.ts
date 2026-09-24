// When a turn the plan's limits refused can go on, from the CLI's last report of them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { limitReached, Thread } from "../thread.ts";

test("a reached session limit says when it resets, in milliseconds", () => {
  assert.deepEqual(limitReached({ status: "rejected", resetsAt: 1790281800, rateLimitType: "five_hour" }), {
    resetsAt: 1790281800000,
    window: "five_hour",
  });
});

test("a limit with room left, or one that doesn't say when it resets, is no reason to wait", () => {
  assert.equal(limitReached({ status: "allowed_warning", resetsAt: 1790281800, rateLimitType: "five_hour" }), undefined);
  assert.equal(limitReached({ status: "rejected" }), undefined);
  assert.equal(limitReached(undefined), undefined);
});

/// The events a thread sends for the messages the CLI sends it, with nothing started.
function eventsFor(messages: object[]): Record<string, any>[] {
  const thread = new Thread("t", "/nowhere/claude") as any;
  thread.running = true;
  thread.sessionId = "s";
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    for (const message of messages) thread.handle({ session_id: "s", uuid: "u", ...message });
  } finally {
    process.stdout.write = write;
  }
  return lines.map((line) => JSON.parse(line)).filter((event) => ["limited", "error", "turn.done"].includes(event.event));
}

// What the CLI sent when this very thread met the session limit on 2026-09-24.
const refusal = {
  type: "assistant",
  parent_tool_use_id: null,
  error: "rate_limit",
  message: { id: "m", role: "assistant", content: [{ type: "text", text: "You've hit your session limit · resets 11:30pm (Europe/Istanbul)" }], usage: { input_tokens: 0, output_tokens: 0 } },
};
const result = {
  type: "result",
  subtype: "success",
  is_error: true,
  duration_ms: 20,
  num_turns: 1,
  stop_reason: "stop_sequence",
  total_cost_usd: 0,
  result: "",
  usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  modelUsage: {},
};

test("a turn the session limit refused says when it can go on, and nothing about a rate", () => {
  const limit = { type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: 1790281800, rateLimitType: "five_hour" } };
  const names = eventsFor([limit, refusal, result]).map((event) => [event.event, event.resetsAt, event.window]);
  assert.deepEqual(names, [
    ["limited", 1790281800000, "five_hour"],
    ["turn.done", undefined, undefined],
  ]);
});

test("a refusal with no limit reached behind it is the plain rate-limit line", () => {
  const events = eventsFor([refusal, result]);
  assert.deepEqual(events.map((event) => event.event), ["error", "turn.done"]);
  assert.match(events[0].message, /Rate limited/);
});
