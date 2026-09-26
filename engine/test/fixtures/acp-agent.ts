// A stand-in ACP agent for the engine's tests: NDJSON JSON-RPC on stdin and stdout, a scripted
// turn for each prompt, and no model anywhere. Every message it's sent goes to ACP_LOG, one per
// line, so a test can read what the engine said. ACP_AUTH=required makes it signed out.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const logFile = process.env.ACP_LOG;
const record = (entry: unknown) => logFile && appendFileSync(logFile, JSON.stringify(entry) + "\n");
record({ env: Object.keys(process.env).filter((key) => key.startsWith("CLAUDE")), extra: process.env.ACP_EXTRA ?? null, cwd: process.cwd() });

const send = (message: object) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
const update = (sessionId: string, body: object) => send({ method: "session/update", params: { sessionId, update: body } });
const pause = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms));

let nextId = 100;
const waiting = new Map<number, (result: any) => void>();
function ask(method: string, params: object): Promise<any> {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

let cancelled: (() => void) | undefined;
let mode = "agent";
let model = "small";

const modes = () => ({
  currentModeId: mode,
  availableModes: [
    { id: "agent", name: "Agent" },
    { id: "plan", name: "Plan", description: "Read-only" },
  ],
});
const configOptions = () => [
  { id: "model", name: "Model", category: "model", type: "select", currentValue: model, options: [{ value: "small", name: "Small" }, { value: "large", name: "Large" }] },
];

const history = [
  { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Earlier question" } },
  { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "old reply" } },
  { sessionUpdate: "tool_call", toolCallId: "replay-0", title: "Read", kind: "read", status: "completed", rawInput: { path: "/x" } },
];

async function prompt(sessionId: string, text: string): Promise<object> {
  if (text === "hello") {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hi." } });
    return { stopReason: "end_turn" };
  }
  if (text === "work") {
    update(sessionId, { sessionUpdate: "session_info_update", title: "Work" });
    update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Reading first." } });
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Let me look." } });
    // Cursor's ids carry a newline, and its input comes after the call.
    const read = "call-1-0\nfc_1_0";
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: read, title: "Read File", kind: "read", status: "pending", rawInput: {} });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: read, title: "Read /w/a.txt", rawInput: { path: "/w/a.txt" }, locations: [{ path: "/w/a.txt" }] });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: read, status: "in_progress" });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: read, status: "completed", rawOutput: { content: "one\ntwo\n" } });
    const diff = { type: "diff", path: "/w/a.txt", oldText: "one\ntwo\nthree\n", newText: "one\n2\nthree\n" };
    const edit = { toolCallId: "edit-1", title: "Edit a.txt", kind: "edit", status: "pending", rawInput: { path: "/w/a.txt" }, content: [diff] };
    update(sessionId, { sessionUpdate: "tool_call", ...edit });
    const answer = await ask("session/request_permission", {
      sessionId,
      toolCall: edit,
      options: [
        { optionId: "once", kind: "allow_once", name: "Allow once" },
        { optionId: "always", kind: "allow_always", name: "Always allow" },
        { optionId: "reject", kind: "reject_once", name: "Reject" },
      ],
    });
    const allowed = answer.outcome.outcome === "selected" && answer.outcome.optionId !== "reject";
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "edit-1", status: allowed ? "completed" : "failed", content: [diff] });
    const plan = [
      { content: "Read a.txt", priority: "high", status: "completed" },
      { content: "Edit a.txt", priority: "high", status: "in_progress" },
      { content: "Check it", priority: "low", status: "pending" },
    ];
    update(sessionId, { sessionUpdate: "plan", entries: plan });
    update(sessionId, { sessionUpdate: "plan", entries: plan });
    update(sessionId, { sessionUpdate: "usage_update", used: 1200, size: 200000, cost: { amount: 0.25, currency: "USD" } });
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } });
    return { stopReason: "end_turn", usage: { inputTokens: 10, outputTokens: 5, totalTokens: 1200, cachedReadTokens: 1185 } };
  }
  if (text === "wait") {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Running it." } });
    const run = { toolCallId: "run-1", title: "make", kind: "execute", status: "pending", rawInput: { command: ["make", "test"] } };
    update(sessionId, { sessionUpdate: "tool_call", ...run });
    const stopped = new Promise<void>((resolve) => (cancelled = resolve));
    // As OpenCode does, the ask names the call with an empty input.
    const answer = ask("session/request_permission", { sessionId, toolCall: { ...run, rawInput: {}, locations: [] }, options: [{ optionId: "yes", kind: "allow_once", name: "Yes" }] });
    await stopped;
    record({ permission: await answer });
    return { stopReason: "cancelled" };
  }
  if (text === "die") {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "About to go." } });
    void ask("session/request_permission", { sessionId, toolCall: { toolCallId: "run-2", title: "rm", kind: "execute", rawInput: { command: "rm x" } }, options: [{ optionId: "yes", kind: "allow_once", name: "Yes" }] });
    await pause(50);
    process.stderr.write("stand-in: out of memory\n");
    process.exit(1);
  }
  return { stopReason: "end_turn" };
}

async function handle(message: any): Promise<void> {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      return send({
        id,
        result: {
          protocolVersion: 1,
          agentCapabilities: { loadSession: true, promptCapabilities: { image: false } },
          authMethods: [{ id: "stand_in_login", name: "Stand-in login", description: "Run `stand-in login` in Terminal" }],
          agentInfo: { name: "stand-in" },
        },
      });
    case "authenticate":
      return send({ id, result: {} });
    case "session/new":
      if (process.env.ACP_AUTH === "required") {
        return send({ id, error: { code: -32000, message: "Authentication required", data: { message: "Run `stand-in login` in Terminal, then try again." } } });
      }
      send({ id, result: { sessionId: "s-1", modes: modes(), configOptions: configOptions() } });
      await pause();
      return update("s-1", { sessionUpdate: "available_commands_update", availableCommands: [{ name: "review", description: "Review the changes", input: { hint: "branch" } }] });
    case "session/load":
      if (params.sessionId === "gone") return send({ id, error: { code: -32002, message: "Session not found" } });
      for (const body of history) update(params.sessionId, body);
      return send({ id, result: { modes: modes(), configOptions: configOptions() } });
    case "session/set_config_option":
      if (params.configId === "model") model = params.value;
      return send({ id, result: { configOptions: configOptions() } });
    case "session/set_mode":
      mode = params.modeId;
      send({ id, result: {} });
      return update(params.sessionId, { sessionUpdate: "current_mode_update", currentModeId: mode });
    case "session/prompt":
      return send({ id, result: await prompt(params.sessionId, params.prompt.find((block: any) => block.type === "text")?.text ?? "") });
    case "session/cancel":
      cancelled?.();
      return;
    default:
      if (id !== undefined) send({ id, error: { code: -32601, message: `No ${method} here` } });
  }
}

createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  record(message);
  if (message.method === undefined) {
    waiting.get(message.id)?.(message.result);
    waiting.delete(message.id);
    return;
  }
  void handle(message);
});
