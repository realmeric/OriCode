// A stand-in for Command Code's `cmd`, for the engine's tests: `status --json`, `--list-models`,
// and `-p --output-format json` with the frames cmd 1.66.0 writes, a scripted run for each
// prompt read from stdin, and no model anywhere. Each run logs its arguments, prompt, folder and
// environment to CMD_LOG, and the sessions it has made to CMD_LOG.sessions, which --resume reads.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
const key = process.env.COMMAND_CODE_API_KEY;

if (args[0] === "status") {
  process.stdout.write(JSON.stringify(key ? { authenticated: true, version: "1.66.0", model: "deepseek/deepseek-v4-flash", context_window: 1000000 } : { authenticated: false, version: "1.66.0" }) + "\n");
  process.exit(key ? 0 : 1);
}

if (args[0] === "--list-models") {
  process.stdout.write(`Available models  ·  4 models

Open Source

deepseek/deepseek-v4-pro               hybrid-attention long-context reasoning
deepseek/deepseek-v4-flash             fast hybrid-attention reasoning (default)
inclusionai/ling-3.0-flash-sante:free  FREE health & medicine tuned lightweight-MoE, still strong on code

Anthropic

claude-sonnet-5                        best combo of speed & intelligence (recommended)

Pass the full id, or just the short name after the last "/":
cmd --model moonshotai/kimi-k2.5
cmd --model kimi-k2.5

Docs:  https://commandcode.ai/docs/reference/cli/models

Decision models (headless only)
typesafe/jev  typed questions in, probabilities out, $0.042 per 1M input tokens, everything else free
`);
  process.exit(0);
}

const logFile = process.env.CMD_LOG ?? "";
const sessionsFile = `${logFile}.sessions`;
const record = (entry: unknown) => logFile && appendFileSync(logFile, JSON.stringify(entry) + "\n");
const flag = (name: string) => {
  const index = args.indexOf(name);
  return index === -1 ? undefined : args[index + 1];
};
const yolo = args.includes("--yolo");
const started = Date.now();
const zero = { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0 };

const line = (frame: object) => process.stdout.write(JSON.stringify(frame) + "\n");
const send = (event: object) => line({ type: "event", event });
const pause = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms));

function result(fields: { subtype?: string; sessionId?: string; stopReason?: string; usage?: object; finalText?: string; error?: string }, code = 0): never {
  line({ type: "result", subtype: "success", usage: zero, durationMs: Date.now() - started, finalText: "", ...fields });
  process.exit(code);
}

const gate = (tool: string) => `Error: Tool "${tool}" requires permissions. Use --yolo (or --dangerously-skip-permissions) to enable file writes and shell commands in print mode.`;

let prompt = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => (prompt += chunk));
process.stdin.on("end", () => void run(prompt.trim()));

process.on("SIGINT", () => {
  record({ signal: "SIGINT" });
  process.stderr.write("\nInterrupted.\n");
  process.exit(130);
});

async function run(prompt: string): Promise<void> {
  record({ args, prompt, cwd: process.cwd(), env: Object.keys(process.env).filter((name) => name.startsWith("CLAUDE")), key: key ?? null });
  if (!key) result({ subtype: "error", error: `Error: Not authenticated. Please run "cmd login" first.` }, 3);
  const known = existsSync(sessionsFile) ? readFileSync(sessionsFile, "utf8").split("\n").filter(Boolean) : [];
  const resume = flag("--resume");
  if (resume && !known.includes(resume)) result({ subtype: "error", error: `Error: No session "${resume}" found to resume.` }, 1);
  const sessionId = resume ?? `s-${known.length + 1}`;
  if (!resume) appendFileSync(sessionsFile, sessionId + "\n");
  send({ type: "run_start", sessionId });
  send({ type: "turn_start", turnNumber: 1 });
  const file = join(process.cwd(), "hello.txt");

  switch (prompt) {
    case "wait":
      send({ type: "text_delta", delta: "Working" });
      setInterval(() => {}, 1000);
      return;
    case "limit":
      result({ subtype: "error", sessionId, error: "Error: Rate limit exceeded. Please wait a moment and try again." }, 5);
    case "crash":
      process.stderr.write("boom: the model client fell over\n");
      process.exit(1);
    case "risky":
      send({ type: "tool_queued", toolCallId: "t-rm", toolName: "shell_command", input: { command: "rm", args: ["-rf", "/"] } });
      send({ type: "tool_denied", toolCallId: "t-rm", toolName: "shell_command" });
      result({ sessionId, stopReason: "permission_denied" });
    case "late": {
      // The edit lands before cmd says it's queued, so the engine reads the file too late.
      writeFileSync(file, readFileSync(file, "utf8").replace("two", "three"));
      send({ type: "tool_queued", toolCallId: "t-late", toolName: "edit_file", input: { file_path: file, old_string: "two", new_string: "three" } });
      send({ type: "tool_running", toolCallId: "t-late", toolName: "edit_file", description: null });
      send({ type: "tool_completed", toolCallId: "t-late", toolName: "edit_file", result: [{ type: "text", text: `Edited ${file}` }] });
      result({ sessionId, stopReason: "end_turn" });
    }
    case "work": {
      const todos = [
        { content: "Read the file", status: "completed", activeForm: "Reading the file" },
        { content: "Change it", status: "in_progress" },
      ];
      send({ type: "tool_queued", toolCallId: "t-plan", toolName: "todo_write", input: { todos } });
      send({ type: "tool_completed", toolCallId: "t-plan", toolName: "todo_write", result: [{ type: "text", text: "Todos updated." }] });
      send({ type: "tool_queued", toolCallId: "t-read", toolName: "read_file", input: { file_path: file } });
      send({ type: "tool_completed", toolCallId: "t-read", toolName: "read_file", result: [{ type: "text", text: "1\tone" }] });
      send({ type: "tool_queued", toolCallId: "t-ls", toolName: "shell_command", input: { command: "ls", args: ["-la"] } });
      if (yolo) send({ type: "tool_completed", toolCallId: "t-ls", toolName: "shell_command", result: [{ type: "text", text: "hello.txt" }] });
      else send({ type: "tool_hook_blocked", toolCallId: "t-ls", toolName: "shell_command", hookOutput: gate("shell_command") });
      send({ type: "tool_queued", toolCallId: "t-edit", toolName: "edit_file", input: { file_path: file, old_string: "one", new_string: "two" } });
      if (yolo) {
        await pause(50);
        send({ type: "tool_running", toolCallId: "t-edit", toolName: "edit_file", description: null });
        writeFileSync(file, readFileSync(file, "utf8").replace("one", "two"));
        send({ type: "tool_completed", toolCallId: "t-edit", toolName: "edit_file", result: [{ type: "text", text: `Edited ${file}` }] });
      } else {
        send({ type: "tool_hook_blocked", toolCallId: "t-edit", toolName: "edit_file", hookOutput: gate("edit_file") });
      }
      send({ type: "text_delta", delta: "Done." });
      result({ sessionId, stopReason: "end_turn", finalText: "Done." });
    }
    default: {
      const usage = { inputTokens: 120, outputTokens: 7, cacheReadTokens: 100, cacheWriteTokens: 10 };
      send({ type: "thinking_start" });
      send({ type: "thinking_delta", delta: "A greeting." });
      send({ type: "thinking_end", text: "A greeting." });
      send({ type: "text_delta", delta: "Hi." });
      send({ type: "model_request_end", model: "deepseek/deepseek-v4-flash", usage, stopReason: "stop" });
      send({ type: "message_end", content: [{ type: "text", text: "Hi." }] });
      send({ type: "turn_end", turnNumber: 1, hadToolCalls: false, usage });
      send({ type: "run_end", result: { finalText: "Hi.", stopReason: "end_turn", turnCount: 1, usage } });
      result({ sessionId, stopReason: "end_turn", usage, finalText: "Hi." });
    }
  }
}
