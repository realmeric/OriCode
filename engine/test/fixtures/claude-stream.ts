// A stand-in for Claude Code under the Agent SDK that streams: each message it's sent is a turn of
// CLAUDE_STREAM_COUNT text deltas, CLAUDE_STREAM_RATE of them a second (one word each, numbered so
// their order can be checked), then the assistant message and the result. With CLAUDE_STREAM_TOOL
// set, a tool call goes out after the first half, so what's held ahead of it has to come first.
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
if (argv.includes("--version")) {
  process.stdout.write("9.9.9 (Claude Code)\n");
  process.exit(0);
}
if (argv[0] === "auth") {
  process.stdout.write('{"loggedIn": true}\n');
  process.exit(0);
}

const rate = Number(process.env.CLAUDE_STREAM_RATE ?? 500);
const count = Number(process.env.CLAUDE_STREAM_COUNT ?? 1000);
const tool = process.env.CLAUDE_STREAM_TOOL === "1";
const session = "stream-session";
const send = (message: object) => process.stdout.write(JSON.stringify({ session_id: session, uuid: crypto.randomUUID(), ...message }) + "\n");
const usage = { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
const delta = (text: string) => send({ type: "stream_event", parent_tool_use_id: null, event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text } } });

createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "control_request") {
    send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } });
    return;
  }
  if (message.type !== "user") return;
  send({ type: "system", subtype: "init", cwd: process.cwd(), tools: [], model: "stand-in", permissionMode: "default", capabilities: [] });
  const id = crypto.randomUUID();
  send({ type: "stream_event", parent_tool_use_id: null, event: { type: "message_start", message: { id } } });
  let sent = 0;
  let text = "";
  const start = performance.now();
  const tick = () => {
    // As many as are due by the clock, so the rate holds whatever the timer's grain.
    const due = Math.min(count, Math.floor(((performance.now() - start) / 1000) * rate) + 1);
    while (sent < due) {
      const word = `w${sent} `;
      text += word;
      delta(word);
      sent += 1;
      if (tool && sent === Math.floor(count / 2)) {
        send({ type: "assistant", parent_tool_use_id: null, message: { id: crypto.randomUUID(), type: "message", role: "assistant", model: "stand-in", content: [{ type: "tool_use", id: "call-1", name: "Read", input: { file_path: "a.txt" } }], stop_reason: "tool_use", usage } });
      }
    }
    if (sent < count) {
      setTimeout(tick, Math.max(1, 1000 / rate));
      return;
    }
    send({ type: "assistant", parent_tool_use_id: null, message: { id, type: "message", role: "assistant", model: "stand-in", content: [{ type: "text", text }], stop_reason: "end_turn", usage } });
    send({ type: "result", subtype: "success", is_error: false, num_turns: 1, duration_ms: 10, duration_api_ms: 10, total_cost_usd: 0, result: text, usage, modelUsage: {}, permission_denials: [] });
  };
  tick();
});
