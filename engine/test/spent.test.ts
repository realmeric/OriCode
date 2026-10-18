// A session the model can't be sent again: what Claude Code 2.1.300 sent when Haiku 5.5 stopped on a
// million characters of one repeated line, and when a message was longer than its window.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Thread } from "../thread.ts";

/// The events a thread sends for the messages the CLI sends it, with nothing started; `resumed`
/// is a session from before this CLI, and `waiting` the ids of messages sent into the turn.
function eventsFor(messages: object[], resumed = false, thread: any = new Thread("t", "/nowhere/claude"), waiting: string[] = []): Record<string, any>[] {
  thread.running = true;
  thread.sessionId = "s";
  thread.fresh = !resumed;
  for (const id of waiting) thread.waiting.add(id);
  const lines: string[] = [];
  const write = process.stdout.write;
  process.stdout.write = ((chunk: string) => (lines.push(chunk), true)) as typeof process.stdout.write;
  try {
    for (const message of messages) thread.handle({ session_id: "s", uuid: "u", ...message });
  } finally {
    process.stdout.write = write;
  }
  return lines.map((line) => JSON.parse(line)).filter((event) => ["note", "error", "turn.done", "message.cancelled"].includes(event.event));
}

const synthetic = (text: string) => ({
  type: "assistant",
  parent_tool_use_id: null,
  error: "invalid_request",
  message: { id: "m", role: "assistant", model: "<synthetic>", content: [{ type: "text", text }], usage: { input_tokens: 0, output_tokens: 0 } },
});
const result = (fields: object) => ({
  type: "result",
  subtype: "success",
  is_error: true,
  duration_ms: 20,
  num_turns: 1,
  total_cost_usd: 0,
  result: "",
  usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  modelUsage: {},
  ...fields,
});
const stopped = { type: "system", subtype: "informational", level: "notice", content: "Haiku 5.5's safeguards stopped the response above · continuing once with that noted" };
const refused = [
  stopped,
  synthetic("API Error: Haiku 5.5 can't help with this. Start a new session to continue."),
  result({ stop_reason: "refusal", terminal_reason: "api_error", num_turns: 2 }),
];
const long = [
  synthetic("Prompt is too long · the request is ~1082510 tokens (limit 1000000)"),
  result({ stop_reason: "stop_sequence", terminal_reason: "prompt_too_long" }),
];

test("a session the model refused to go on in is said to be spent, without the API's raw error", () => {
  const events = eventsFor(refused);
  assert.deepEqual(events.map((event) => event.event), ["note", "turn.done"]);
  assert.equal(events[1].spent, "refused");
  assert.equal(events[1].held, false);
});

test("a session longer than the model's window is spent, and held more than the turn when it was resumed", () => {
  const events = eventsFor(long, true);
  assert.deepEqual(events.map((event) => event.event), ["turn.done"]);
  assert.equal(events[0].spent, "long");
  assert.equal(events[0].held, true);
});

test("a second turn in the same CLI finds the session held the first", () => {
  const thread = eventsFor([result({ is_error: false, stop_reason: "end_turn", terminal_reason: "completed" }), ...long]);
  assert.equal(thread.at(-1)?.held, true);
});

test("any other API error is said as before, and leaves the session as it was", () => {
  const events = eventsFor([synthetic("API Error: 400 something else"), result({ stop_reason: "stop_sequence", terminal_reason: "api_error" })]);
  assert.deepEqual(events.map((event) => event.event), ["error", "turn.done"]);
  assert.equal(events[0].message, "Claude returned an error (invalid_request).");
  assert.equal(events[1].spent, undefined);
});

test("messages sent into a spent turn go back before it ends, and the session goes with its CLI", () => {
  const thread = new Thread("t", "/nowhere/claude") as any;
  const events = eventsFor(refused, true, thread, ["w1", "w2"]);
  assert.deepEqual(events.map((event) => event.event), ["note", "message.cancelled", "message.cancelled", "turn.done"]);
  assert.equal(events.at(-1)?.waiting, 0);
  assert.equal(thread.sessionId, undefined);
  assert.equal(thread.query, undefined);
});
