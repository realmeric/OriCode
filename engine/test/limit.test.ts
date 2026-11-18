// When a turn the plan's limits refused can go on, from the CLI's last report of them.
import { test } from "node:test";
import assert from "node:assert/strict";
import { limitReached, Thread, wakeHold } from "../thread.ts";

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
function eventsFor(messages: object[], thread: any = new Thread("t", "/nowhere/claude")): Record<string, any>[] {
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
  return lines.map((line) => JSON.parse(line)).filter((event) => ["limited", "limits", "note", "error", "turn.done"].includes(event.event));
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
    ["limits", 1790281800000, undefined],
    ["limited", 1790281800000, "five_hour"],
    ["turn.done", undefined, undefined],
  ]);
});

// The app tells a thread's opener from these two turns: that it waits, and then that it finished.
test("a first turn the session limit stopped says so before its end, and the turn after the reset ends with no limit", () => {
  const thread = new Thread("t", "/nowhere/claude");
  const limit = { type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: 1790281800, rateLimitType: "five_hour" } };
  const first = eventsFor([limit, refusal, result], thread).filter((event) => event.event !== "limits");
  assert.deepEqual(first.map((event) => [event.event, event.resetsAt, event.window]), [
    ["limited", 1790281800000, "five_hour"],
    ["turn.done", undefined, undefined],
  ]);
  const allowed = { type: "rate_limit_event", rate_limit_info: { status: "allowed", resetsAt: 1790299800, rateLimitType: "five_hour" } };
  const reply = { ...refusal, error: undefined, message: { ...refusal.message, id: "m2", content: [{ type: "text", text: "Renamed it." }] } };
  const second = eventsFor([allowed, reply, { ...result, is_error: false, stop_reason: "end_turn" }], thread).filter((event) => event.event !== "limits");
  assert.deepEqual(second.map((event) => [event.event, event.stopReason]), [["turn.done", "end_turn"]]);
});

test("a refusal with no limit behind it is Claude slowing requests for a moment", () => {
  const events = eventsFor([refusal, result]);
  assert.deepEqual(events.map((event) => event.event), ["error", "turn.done"]);
  assert.equal(events[0].message, "Claude is limiting requests for a moment. Try again shortly.");
});

test("a limit the CLI says was reached without saying when it resets is a usage limit", () => {
  const limit = { type: "rate_limit_event", rate_limit_info: { status: "rejected", rateLimitType: "seven_day" } };
  const events = eventsFor([limit, refusal, result]).filter((event) => event.event !== "limits");
  assert.deepEqual(events.map((event) => event.event), ["error", "turn.done"]);
  assert.equal(events[0].message, "Stopped at one of Claude's usage limits.");
});

/// A report as Claude Code 2.1.283 sends one, with each window's reading beside the limit it names.
function report(status: string, used: number, session = 0.3) {
  return {
    type: "rate_limit_event",
    rate_limit_info: {
      status,
      resetsAt: 1790281800,
      rateLimitType: "seven_day",
      utilization: used,
      surpassedThreshold: status === "allowed_warning" ? 0.75 : undefined,
      unifiedWindows: { five_hour: { utilization: session, resetsAt: 1790262000 }, seven_day: { utilization: used, resetsAt: 1790281800 } },
    },
  };
}

test("the plan's limits go to the app as fractions and milliseconds", () => {
  const [limits] = eventsFor([report("allowed_warning", 0.76)]);
  assert.deepEqual(limits, {
    event: "limits",
    threadId: "t",
    status: "allowed_warning",
    rateLimitType: "seven_day",
    utilization: 0.76,
    resetsAt: 1790281800000,
    surpassedThreshold: 0.75,
    windows: [
      { id: "five_hour", used: 0.3, resetsAt: 1790262000000 },
      { id: "seven_day", used: 0.76, resetsAt: 1790281800000 },
    ],
  });
});

test("the limits are sent again only when a status or a whole percent moves", () => {
  const events = eventsFor([
    report("allowed_warning", 0.76),
    report("allowed_warning", 0.762),
    report("allowed_warning", 0.762, 0.304),
    report("allowed_warning", 0.77),
    report("allowed_warning", 0.77, 0.31),
    report("rejected", 0.77, 0.31),
  ]);
  assert.deepEqual(
    events.map((event) => [event.status, event.utilization, event.windows[0].used]),
    [
      ["allowed_warning", 0.76, 0.3],
      ["allowed_warning", 0.77, 0.3],
      ["allowed_warning", 0.77, 0.31],
      ["rejected", 0.77, 0.31],
    ],
  );
});

test("a report without each window's reading still names its limit", () => {
  const [limits] = eventsFor([{ type: "rate_limit_event", rate_limit_info: { status: "allowed" } }]);
  assert.deepEqual(limits.windows, []);
  assert.equal(limits.utilization, null);
  assert.equal(limits.resetsAt, null);
});

test("Claude Code's notices come to the thread as notes, and its quieter lines don't", () => {
  const notice = (level: string, content: string) => ({ type: "system", subtype: "informational", level, content });
  const events = eventsFor([
    notice("notice", "Approaching your 5-hour usage limit — Claude will wrap up the current step."),
    notice("info", "Hook ran"),
    notice("suggestion", "Try /compact"),
    notice("warning", "Stop hook prevented continuation"),
  ]);
  assert.deepEqual(
    events.map((event) => [event.event, event.text]),
    [
      ["note", "Approaching your 5-hour usage limit — Claude will wrap up the current step."],
      ["note", "Stop hook prevented continuation"],
    ],
  );
});

/// What a thread tells the app of the messages its CLI sends between turns as well as in them.
function heard(thread: any, messages: object[]): Record<string, any>[] {
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    for (const message of messages) thread.handle({ session_id: "s", uuid: "u", ...message });
  } finally {
    process.stdout.write = write;
  }
  return lines.map((line) => JSON.parse(line)).filter((event) => ["limited", "error", "turn.started", "turn.done"].includes(event.event));
}

/// A thread whose turn has ended with its CLI still up, a background subagent out.
function idleThread(): any {
  const thread: any = new Thread("t", "/nowhere/claude");
  thread.sessionId = "s";
  thread.query = { close() {} };
  thread.idleSince = Date.now() - 3_600_000;
  return thread;
}

const inAnHour = Math.floor(Date.now() / 1000) + 3600;
// What the CLI sent when a background subagent of a thread met the session limit on 2026-11-18:
// the subagent's refusal, its end, and the turn that end woke, refused as well.
const subagentRefusal = { ...refusal, parent_tool_use_id: "toolu_agent", message: { ...refusal.message, id: "sub" } };
const sessionLimit = { type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: inAnHour, rateLimitType: "five_hour" } };
const subagentFailed = {
  type: "system",
  subtype: "task_notification",
  task_id: "a1",
  tool_use_id: "toolu_agent",
  status: "failed",
  output_file: "",
  summary: 'Agent "Redesign the site" failed: Agent terminated early due to an API error: You\'ve hit your 5-hour limit · resets 10am (Europe/Istanbul)',
};

test("a subagent stopped by the session limit keeps its thread's CLI up for the turn it wakes, which waits for the reset", () => {
  const thread = idleThread();
  heard(thread, [subagentRefusal, sessionLimit, subagentFailed]);
  // Nothing of the woken turn has come yet, and closing the CLI now would lose it.
  assert.equal(thread.releaseIfIdle(0), false);
  const woken = heard(thread, [sessionLimit, { ...refusal, message: { ...refusal.message, id: "woke" } }, result]);
  assert.deepEqual(woken.map((event) => [event.event, event.resetsAt, event.window]), [
    ["turn.started", undefined, undefined],
    ["limited", inAnHour * 1000, "five_hour"],
    ["turn.done", undefined, undefined],
  ]);
  assert.equal(thread.releaseIfIdle(0), true);
});

test("a task's end that wakes no turn holds the CLI only so long", () => {
  const thread = idleThread();
  heard(thread, [subagentFailed]);
  assert.equal(thread.releaseIfIdle(0), false);
  assert.equal(thread.releaseIfIdle(0, Date.now() + wakeHold), true);
});

test("a subagent stopped by a limit its thread's turn went on past makes the thread wait for that limit", () => {
  const thread = new Thread("t", "/nowhere/claude");
  const opus = { type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: inAnHour, rateLimitType: "seven_day_opus" } };
  const allowed = { type: "rate_limit_event", rate_limit_info: { status: "allowed", resetsAt: inAnHour + 600, rateLimitType: "five_hour" } };
  const reply = { ...refusal, error: undefined, message: { ...refusal.message, id: "m2", content: [{ type: "text", text: "The agent stopped at its limit." }] } };
  const done = { ...result, is_error: false, stop_reason: "end_turn" };
  const first = eventsFor([subagentRefusal, opus, allowed, reply, done], thread).filter((event) => event.event !== "limits");
  assert.deepEqual(first.map((event) => [event.event, event.resetsAt, event.window, event.subagent]), [
    ["limited", inAnHour * 1000, "seven_day_opus", true],
    ["turn.done", undefined, undefined, undefined],
  ]);
  // The turn the reset sends, or a reset used, goes on with nothing left to wait for.
  const next = eventsFor([allowed, { ...reply, message: { ...reply.message, id: "m3" } }, done], thread).filter((event) => event.event !== "limits");
  assert.deepEqual(next.map((event) => event.event), ["turn.done"]);
});

test("a subagent and its thread refused by the same limit wait for it once", () => {
  const events = eventsFor([subagentRefusal, sessionLimit, refusal, result]).filter((event) => event.event !== "limits");
  assert.deepEqual(events.map((event) => [event.event, event.subagent]), [
    ["limited", undefined],
    ["turn.done", undefined],
  ]);
});
