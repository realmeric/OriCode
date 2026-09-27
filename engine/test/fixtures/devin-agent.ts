// A stand-in for Devin's `devin`, for the engine's tests: `--version`, `auth status`, and `acp`
// as devin 3000.11.3 answered a client named "oricode" in a scratch home on 2026-09-27, with a
// scripted turn for each prompt and no model anywhere. It takes any clientInfo, as that Devin did.
// DEVIN_LOGIN=1 stands for the credentials `devin auth login` stores. Each process logs its
// arguments and environment, and every message it's sent, to DEVIN_LOG.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
const loggedIn = process.env.DEVIN_LOGIN === "1";

if (argv[0] === "--version") {
  process.stdout.write("devin 3000.11.3 (9c803229faa4)\n");
  process.exit(0);
}
if (argv[0] === "auth" && argv[1] === "status") {
  // Exit 0 either way, as Devin's does.
  process.stdout.write(
    loggedIn
      ? "Logged in as meric@example.com\n"
      : "Not logged in.\n  Credentials path: /Users/me/.local/share/devin/credentials.toml\nRun `devin auth login` to authenticate.\n",
  );
  process.exit(0);
}

const record = (entry: unknown) => process.env.DEVIN_LOG && appendFileSync(process.env.DEVIN_LOG, JSON.stringify(entry) + "\n");
record({ argv, claude: Object.keys(process.env).filter((key) => key.startsWith("CLAUDE")) });

const send = (message: object) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
const update = (sessionId: string, body: object) => send({ method: "session/update", params: { sessionId, update: body } });

let nextId = 100;
const waiting = new Map<number, (result: any) => void>();
function ask(method: string, params: object): Promise<any> {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

let cancelled: (() => void) | undefined;
let mode = "accept-edits";
let model = "swe-1-6-fast";

const icon = (name: string) => ({ "cognition.ai/icon": name });
const modeValues = [
  { value: "accept-edits", name: "Code", description: "Write and edit code", _meta: icon("code") },
  { value: "ask", name: "Ask", description: "Answer questions without code changes", _meta: icon("message-circle") },
  { value: "plan", name: "Plan", description: "Plan changes before implementing", _meta: icon("file-text") },
  { value: "bypass", name: "Bypass Permissions", description: "Auto-approve all tool calls", _meta: icon("shield-off") },
];
// Signed out, Devin lists no models; the names here stand in for an account's.
const modelValues = loggedIn
  ? [
      { value: "swe-1-6-fast", name: "SWE-1.6 Fast" },
      { value: "adaptive", name: "Adaptive" },
      { value: "claude-opus-4-7", name: "Claude Opus 4.7" },
    ]
  : [];
const configOptions = () => [
  { id: "mode", name: "Session Mode", category: "mode", type: "select", currentValue: mode, options: modeValues },
  { id: "model", name: "Model", description: "AI model to use", category: "model", type: "select", currentValue: model, options: modelValues },
];
const modes = () => ({ currentModeId: mode, availableModes: modeValues.map((value) => ({ id: value.value, name: value.name })) });

const history = [
  { sessionUpdate: "user_message_chunk", content: { type: "text", text: "Earlier question" } },
  { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "old reply" } },
];

async function prompt(sessionId: string, text: string, cwd: string): Promise<object> {
  update(sessionId, { sessionUpdate: "session_info_update", title: text });
  if (text === "hello") {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hi." } });
    return { stopReason: "end_turn" };
  }
  const options = [
    { optionId: "allow_once", name: "Approve once", kind: "allow_once" },
    { optionId: "allow_session", name: "This session", kind: "allow_always" },
    { optionId: "reject_once", name: "Reject", kind: "reject_once" },
  ];
  if (text === "work") {
    update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Run it, then edit." } });
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Looking." } });
    const run = { toolCallId: "tc-exec", title: "echo hi", kind: "execute", status: "pending", rawInput: { command: "echo hi" } };
    update(sessionId, { sessionUpdate: "tool_call", ...run });
    if (mode !== "bypass") record({ answered: await ask("session/request_permission", { sessionId, toolCall: run, options }) });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-exec", status: "completed", content: [{ type: "content", content: { type: "text", text: "hi\n" } }] });
    // Code mode approves an edit in the workspace without asking.
    const path = `${cwd}/hello.txt`;
    const diff = { type: "diff", path, oldText: "zero\none\nend\n", newText: "zero\ntwo\nend\n" };
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: "tc-edit", title: "Edit hello.txt", kind: "edit", status: "in_progress", rawInput: { file_path: path }, locations: [{ path }], content: [diff] });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-edit", status: "completed", content: [diff] });
    update(sessionId, {
      sessionUpdate: "plan",
      entries: [
        { content: "Run echo", priority: "medium", status: "completed" },
        { content: "Edit hello.txt", priority: "medium", status: "completed" },
      ],
    });
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Done." } });
    return { stopReason: "end_turn" };
  }
  if (text === "wait") {
    const run = { toolCallId: "tc-sleep", title: "sleep 60", kind: "execute", status: "pending", rawInput: { command: "sleep 60" } };
    update(sessionId, { sessionUpdate: "tool_call", ...run });
    const stopped = new Promise<void>((resolve) => (cancelled = resolve));
    if (mode !== "bypass") void ask("session/request_permission", { sessionId, toolCall: run, options });
    else update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "tc-sleep", status: "in_progress" });
    await stopped;
    return { stopReason: "cancelled" };
  }
  return { stopReason: "end_turn" };
}

const cwds = new Map<string, string>();

async function handle(message: any): Promise<void> {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      return send({
        id,
        result: {
          protocolVersion: 1,
          agentCapabilities: {
            loadSession: true,
            promptCapabilities: { image: true, audio: false, embeddedContext: true },
            mcpCapabilities: { http: true, sse: true },
            sessionCapabilities: { list: {}, delete: {}, additionalDirectories: {} },
            auth: {},
          },
          authMethods: [{ id: "devin-browser", name: "Log in with browser", description: "Sign in via your browser" }],
          agentInfo: { name: "affogato", title: "Devin Agent", version: "0.0.0-dev" },
        },
      });
    case "authenticate":
      // Would open a browser.
      return send({ id, error: { code: -32000, message: "the stand-in won't open a browser" } });
    case "session/new": {
      const sessionId = "mirage-robin";
      cwds.set(sessionId, params.cwd);
      send({ method: "_cognition.ai/mcp/serversChanged", params: {} });
      update(sessionId, { sessionUpdate: "config_option_update", configOptions: configOptions() });
      update(sessionId, { sessionUpdate: "current_mode_update", currentModeId: mode });
      send({ id, result: { sessionId, modes: modes(), configOptions: configOptions(), _meta: { "cognition.ai/isLocked": false, "cognition.ai/lockHolderPid": null } } });
      return update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "compact", description: "Force conversation compaction" }] });
    }
    case "session/load":
      cwds.set(params.sessionId, params.cwd);
      for (const body of history) update(params.sessionId, body);
      return send({ id, result: { modes: modes(), configOptions: configOptions() } });
    case "session/set_config_option":
      if (params.configId === "mode") mode = params.value;
      if (params.configId === "model") model = params.value;
      send({ id, result: { configOptions: configOptions() } });
      if (params.configId === "mode") update(params.sessionId, { sessionUpdate: "current_mode_update", currentModeId: mode });
      return;
    case "session/prompt": {
      const text = params.prompt.find((block: any) => block.type === "text")?.text ?? "";
      if (!loggedIn) {
        update(params.sessionId, { sessionUpdate: "session_info_update", title: text });
        send({ method: "_cognition.ai/agent_stopped", params: { cause: "auth_required", errorMessage: "Please authenticate to continue. Run `/login` to log in.", sessionId: params.sessionId } });
        return send({ id, error: { code: -32000, message: "Please log in to use Devin. Use `/login` to authenticate again." } });
      }
      return send({ id, result: await prompt(params.sessionId, text, cwds.get(params.sessionId) ?? process.cwd()) });
    }
    case "session/cancel":
      cancelled?.();
      return;
    default:
      if (id !== undefined) send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
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
