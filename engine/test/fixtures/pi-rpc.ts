// A stand-in for `pi --mode rpc`, `pi --version` and `pi auth check`, for the engine's tests:
// JSON lines as Pi 0.87.1 writes them, a scripted run for each prompt, and no model anywhere.
// Every command it's sent goes to PI_LOG, one per line, after a line with its arguments. PI_AUTH
// holds the auth type `pi auth check` says for each provider; PI_EMPTY=1 makes it hold none.
import { appendFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

const args = process.argv.slice(2);
const auth: Record<string, string> = JSON.parse(process.env.PI_AUTH ?? "{}");

if (args[0] === "--version") {
  process.stdout.write("0.87.1\n");
  process.exit(0);
}

if (args[0] === "auth") {
  const provider = args[args.indexOf("--provider") + 1];
  const type = auth[provider];
  process.stdout.write(JSON.stringify(type ? { status: "ready", provider, authType: type } : { status: "not_ready", provider, reason: "credentials_not_configured" }) + "\n");
  process.exit(type ? 0 : 1);
}

const logFile = process.env.PI_LOG;
const record = (entry: unknown) => logFile && appendFileSync(logFile, JSON.stringify(entry) + "\n");
record({ args, env: Object.keys(process.env).filter((key) => key.startsWith("CLAUDE")), cwd: process.cwd() });

const send = (message: object) => process.stdout.write(JSON.stringify(message) + "\n");
const pause = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms));

const catalog = [
  { id: "claude-opus", name: "Claude Opus", api: "anthropic-messages", provider: "anthropic", reasoning: true, input: ["text", "image"], contextWindow: 200000, maxTokens: 64000, thinkingLevelMap: { xhigh: "xhigh", max: "max" } },
  { id: "gpt-5.5", name: "GPT-5.5", api: "openai-responses", provider: "openai", reasoning: true, input: ["text", "image"], contextWindow: 272000, maxTokens: 128000, thinkingLevelMap: { off: "none", minimal: null, low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: null } },
  { id: "gpt-4", name: "GPT-4", api: "openai-responses", provider: "openai", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 8192 },
  { id: "grok-5", name: "Grok 5", api: "openai-responses", provider: "xai", reasoning: true, input: ["text"], contextWindow: 256000, maxTokens: 32000 },
  { id: "muse-1", name: "Muse 1", api: "openai-completions", provider: "meta", reasoning: false, input: ["text"], contextWindow: 128000, maxTokens: 8192 },
  { id: "anthropic/claude-haiku", name: "Claude Haiku", api: "openai-completions", provider: "openrouter", reasoning: false, input: ["text"], contextWindow: 200000, maxTokens: 8192 },
];
const models = process.env.PI_EMPTY === "1" ? [] : catalog;

const flag = (name: string) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const sessions = join(process.cwd(), "sessions");
const sessionId = flag("--session-id") ?? `s-${process.pid}`;
const sessionFile = flag("--session") ?? join(sessions, `${sessionId}.jsonl`);
let model = models[1];
let streaming = false;
/// A message sent into a run that the script takes up, and whoever waits on an abort.
let joined: ((prompt: any) => void) | undefined;
let aborted: (() => void) | undefined;
let settled: (() => void) | undefined;
const queue: string[] = [];

const usage = (input: number, output: number, cacheRead: number, cost: number) => ({
  input,
  output,
  cacheRead,
  cacheWrite: 0,
  totalTokens: input + output + cacheRead,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: cost },
});

const assistant = (content: object[], stopReason: string, used = usage(0, 0, 0, 0), errorMessage?: string) => ({
  role: "assistant",
  content,
  api: model.api,
  provider: model.provider,
  model: model.id,
  usage: used,
  stopReason,
  ...(errorMessage ? { errorMessage } : {}),
  timestamp: Date.now(),
});

function user(text: string): void {
  const message = { role: "user", content: [{ type: "text", text }], timestamp: Date.now() };
  send({ type: "message_start", message });
  send({ type: "message_end", message });
}

/// One assistant message that says `text`, thinking first when there's thinking to say.
function say(text: string, stopReason = "stop", used = usage(0, 0, 0, 0), thinking: string[] = []): void {
  send({ type: "message_start", message: assistant([], "pending") });
  const content: object[] = [];
  if (thinking.length) {
    send({ type: "message_update", usage: used, assistantMessageEvent: { type: "thinking_start", contentIndex: 0 } });
    for (const delta of thinking) send({ type: "message_update", usage: used, assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta } });
    send({ type: "message_update", usage: used, assistantMessageEvent: { type: "thinking_end", contentIndex: 0, content: thinking.join("") } });
    content.push({ type: "thinking", thinking: thinking.join("") });
  }
  const index = content.length;
  send({ type: "message_update", usage: used, assistantMessageEvent: { type: "text_start", contentIndex: index } });
  send({ type: "message_update", usage: used, assistantMessageEvent: { type: "text_delta", contentIndex: index, delta: text } });
  send({ type: "message_update", usage: used, assistantMessageEvent: { type: "text_end", contentIndex: index, content: text } });
  content.push({ type: "text", text });
  send({ type: "message_end", message: assistant(content, stopReason, used) });
}

function tool(id: string, name: string, toolArgs: object, result: object, isError = false): void {
  send({ type: "tool_execution_start", toolCallId: id, toolName: name, args: toolArgs });
  send({ type: "tool_execution_end", toolCallId: id, toolName: name, result, isError });
}

function end(): void {
  send({ type: "agent_end", messages: [], willRetry: false });
  streaming = false;
  send({ type: "agent_settled" });
  settled?.();
}

/// The run a prompt starts, as Pi's agent loop sends it.
async function run(text: string): Promise<void> {
  streaming = true;
  send({ type: "agent_start" });
  send({ type: "turn_start" });
  user(text);
  mkdirSync(sessions, { recursive: true });
  writeFileSync(sessionFile, JSON.stringify({ type: "session", version: 3, id: sessionId }) + "\n", { flag: "a" });
  if (text === "hello") {
    say("Hi. There", "stop", usage(100, 3, 0, 0.001));
    return end();
  }
  if (text === "work") {
    send({ type: "message_start", message: assistant([], "pending") });
    for (const delta of ["Reading first.", " Then the edit."]) {
      send({ type: "message_update", usage: usage(0, 0, 0, 0), assistantMessageEvent: { type: "thinking_delta", contentIndex: 0, delta } });
    }
    send({ type: "message_update", usage: usage(0, 0, 0, 0), assistantMessageEvent: { type: "text_delta", contentIndex: 1, delta: "Let me look." } });
    send({ type: "message_end", message: assistant([], "toolUse", usage(1000, 20, 800, 0.01)) });
    tool("call-1", "read", { path: "a.txt" }, { content: [{ type: "text", text: "one\ntwo\nthree\n" }], details: {} });
    send({ type: "extension_ui_request", id: "ui-1", method: "confirm", title: "Allow?", message: "An extension asks" });
    tool(
      "call-2",
      "edit",
      { path: "a.txt", edits: [{ oldText: "two", newText: "2" }] },
      {
        content: [{ type: "text", text: "Successfully replaced 1 block(s) in a.txt." }],
        details: { diff: " 1 one\n-2 two\n+2 2\n 3 three", patch: "Index: a.txt\n===================================================================\n--- a.txt\n+++ a.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n", firstChangedLine: 2 },
      },
    );
    tool("call-3", "write", { path: "b.txt", content: "new\nfile\n" }, { content: [{ type: "text", text: "Successfully wrote 9 bytes to b.txt" }] });
    tool("call-4", "bash", { command: "make test" }, { content: [{ type: "text", text: "boom" }], details: {} }, true);
    send({ type: "turn_end", message: assistant([], "toolUse"), toolResults: [] });
    say("Done.", "stop", usage(1200, 30, 1000, 0.02));
    return end();
  }
  if (text === "slow" || text === "wait") {
    send({ type: "message_update", usage: usage(0, 0, 0, 0), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "Working." } });
    const next = await new Promise<any>((resolve) => {
      joined = text === "slow" ? resolve : undefined;
      aborted = () => resolve(undefined);
    });
    joined = undefined;
    if (!next) {
      send({ type: "message_end", message: assistant([{ type: "text", text: "Working." }], "aborted", usage(0, 0, 0, 0), "Request was aborted") });
      return end();
    }
    send({ type: "message_end", message: assistant([{ type: "text", text: "Working." }], "toolUse") });
    user(next.message);
    say("Got it.", "stop", usage(50, 5, 0, 0.001));
    return end();
  }
  if (text === "fail") {
    send({ type: "message_start", message: assistant([], "pending") });
    send({ type: "message_end", message: assistant([], "error", usage(0, 0, 0, 0), "401 invalid x-api-key") });
    return end();
  }
  if (text === "die") {
    send({ type: "message_update", usage: usage(0, 0, 0, 0), assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "About to go." } });
    await pause(50);
    process.stderr.write("pi: out of memory\n");
    process.exit(1);
  }
  say("");
  end();
}

async function handle(command: any): Promise<void> {
  const { id, type } = command;
  const ok = (data?: object) => send({ id, type: "response", command: type, success: true, ...(data ? { data } : {}) });
  const refuse = (error: string) => send({ id, type: "response", command: type, success: false, error });
  switch (type) {
    case "get_state":
      return ok({ model, thinkingLevel: "medium", isStreaming: streaming, isCompacting: false, sessionFile, sessionId, messageCount: 0, pendingMessageCount: queue.length });
    case "get_available_models":
      return ok({ models });
    case "get_commands":
      return ok({ commands: [{ name: "fix-tests", description: "Fix failing tests", source: "prompt" }, { name: "llama", source: "extension" }] });
    case "set_model": {
      const found = models.find((candidate) => candidate.provider === command.provider && candidate.id === command.modelId);
      if (!found) return refuse(`Model not found: ${command.provider}/${command.modelId}`);
      model = found;
      return ok(found);
    }
    case "set_thinking_level":
      return ok();
    case "prompt":
      if (streaming) {
        if (!command.streamingBehavior) return refuse("Agent is already processing. Specify streamingBehavior ('steer' or 'followUp') to queue the message.");
        queue.push(command.message);
        send({ type: "queue_update", steering: command.streamingBehavior === "steer" ? [...queue] : [], followUp: command.streamingBehavior === "followUp" ? [...queue] : [] });
        ok();
        if (joined) {
          queue.splice(0);
          joined(command);
        }
        return;
      }
      if (command.message === "nokey") return refuse('No API key found for anthropic.\n\nUse /login or set an API key environment variable.');
      if (command.message === "/llama") return ok();
      ok();
      return run(command.message);
    case "clear_queue": {
      const steering = queue.splice(0);
      send({ type: "queue_update", steering: [], followUp: [] });
      return ok({ steering, followUp: [] });
    }
    case "abort":
      if (streaming) {
        const done = new Promise<void>((resolve) => (settled = resolve));
        aborted?.();
        await done;
      }
      return ok();
    default:
      if (id !== undefined) refuse(`Unknown command: ${type}`);
  }
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  record(message);
  if (message.type === "extension_ui_response") return;
  void handle(message);
});
