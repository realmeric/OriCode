// A stand-in for Claude Code under the Agent SDK that says what each turn costs the way Claude Code
// does: total_cost_usd is the session's running total, and a resumed session's first result carries
// the turns before it. Turn n costs CLAUDE_SPEND_COSTS's nth amount. The session's total and its
// turns are kept in CLAUDE_SPEND_STATE across CLIs, as the transcript keeps them, and each launch's
// arguments are written to CLAUDE_SPEND_LOG.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
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
appendFileSync(process.env.CLAUDE_SPEND_LOG!, JSON.stringify(argv) + "\n");

const file = process.env.CLAUDE_SPEND_STATE!;
const costs = process.env.CLAUDE_SPEND_COSTS!.split(",").map(Number);
const saved = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as { total: number; turns: number }) : { total: 0, turns: 0 };
const state = argv.some((arg) => arg.startsWith("--resume")) ? saved : { total: 0, turns: saved.turns };

const session = "spend-session";
const send = (message: object) => process.stdout.write(JSON.stringify({ session_id: session, uuid: crypto.randomUUID(), ...message }) + "\n");
const usage = { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };

createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "control_request") {
    send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } });
    return;
  }
  if (message.type !== "user") return;
  state.total += costs[state.turns++] ?? 0;
  writeFileSync(file, JSON.stringify(state));
  send({ type: "system", subtype: "init", cwd: process.cwd(), tools: [], model: "haiku", permissionMode: "default", capabilities: [] });
  send({ type: "assistant", parent_tool_use_id: null, message: { id: crypto.randomUUID(), type: "message", role: "assistant", model: "haiku", content: [{ type: "text", text: `turn ${state.turns}` }], stop_reason: "end_turn", usage } });
  send({ type: "result", subtype: "success", is_error: false, num_turns: 1, duration_ms: 10, duration_api_ms: 10, total_cost_usd: state.total, result: `turn ${state.turns}`, usage, modelUsage: {}, permission_denials: [] });
});
