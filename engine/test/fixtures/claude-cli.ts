// A stand-in for Claude Code under the Agent SDK, for the engine's tests: it answers the SDK's
// control requests, and each message it's sent is a turn that starts a background workflow. Then
// it does what Claude Code can do before the workflow's end, a background list that leaves the
// workflow out. SIGUSR1 ends the workflow and reports back, as a turn of its own. It writes its
// pid to CLAUDE_STAND_IN_PID.
import { writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
if (argv.includes("--version")) {
  process.stdout.write("9.9.9 (Claude Code)\n");
  process.exit(0);
}
if (argv[0] === "auth") {
  process.stdout.write('{"loggedIn": false}\n');
  process.exit(1);
}
if (process.env.CLAUDE_STAND_IN_PID) writeFileSync(process.env.CLAUDE_STAND_IN_PID, String(process.pid));

const session = "stand-in-session";
const send = (message: object) => process.stdout.write(JSON.stringify({ session_id: session, uuid: crypto.randomUUID(), ...message }) + "\n");
const system = (subtype: string, body: object) => send({ type: "system", subtype, ...body });
const usage = { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
const reply = (text: string) => {
  send({ type: "assistant", parent_tool_use_id: null, message: { id: crypto.randomUUID(), type: "message", role: "assistant", model: "stand-in", content: [{ type: "text", text }], stop_reason: "end_turn", usage } });
  send({ type: "result", subtype: "success", is_error: false, num_turns: 1, duration_ms: 10, duration_api_ms: 10, total_cost_usd: 0, result: text, usage, modelUsage: {}, permission_denials: [] });
};

let workflows = 0;
createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.type === "control_request") {
    send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } });
    return;
  }
  if (message.type !== "user") return;
  const task = `w${++workflows}`;
  system("init", { cwd: process.cwd(), tools: ["Workflow"], model: "stand-in", permissionMode: "default", capabilities: [] });
  system("task_started", { task_id: task, tool_use_id: `call-${task}`, description: "water-041", task_type: "local_workflow", workflow_name: "water-041" });
  system("background_tasks_changed", { tasks: [{ task_id: task, task_type: "local_workflow", description: "water-041" }] });
  reply("Started water-041 in the background.");
  system("background_tasks_changed", { tasks: [] });
});

process.on("SIGUSR1", () => {
  const task = `w${workflows}`;
  system("task_notification", { task_id: task, tool_use_id: `call-${task}`, status: "completed", output_file: "", summary: "water-041 finished" });
  reply("water-041 finished.");
});
