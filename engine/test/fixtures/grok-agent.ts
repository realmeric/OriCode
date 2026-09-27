// A stand-in for Grok Build's `grok`, for the engine's tests: `--version`, and `agent stdio` as
// grok 1.0.41 speaks ACP (github.com/xai-org/grok-build, crates/codegen/xai-grok-shell), with a
// scripted turn for each prompt and no model anywhere. GROK_LOGIN=1 stands for the session a
// `grok login` leaves in ~/.grok/auth.json. Each process logs its arguments and environment, and
// every message it's sent, to GROK_LOG.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const argv = process.argv.slice(2);
if (argv.includes("--version")) {
  process.stdout.write("grok 1.0.41 (4220f3b224a6)\n");
  process.exit(0);
}

const record = (entry: unknown) => process.env.GROK_LOG && appendFileSync(process.env.GROK_LOG, JSON.stringify(entry) + "\n");
record({
  argv,
  disabled: process.env.GROK_DISABLE_API_KEY_AUTH ?? null,
  claude: Object.keys(process.env).filter((key) => key.startsWith("CLAUDE")),
});

const loggedIn = process.env.GROK_LOGIN === "1";
// xAI's lockdown switch: with it set, xai.api_key is neither offered nor taken.
const keyAllowed = process.env.XAI_API_KEY !== undefined && !["1", "true"].includes(process.env.GROK_DISABLE_API_KEY_AUTH ?? "");
const flag = argv.indexOf("--permission-mode");
const alwaysApprove = flag !== -1 && ["bypassPermissions", "always-approve"].includes(argv[flag + 1]);

const send = (message: object) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
const update = (sessionId: string, body: object) => send({ method: "session/update", params: { sessionId, update: body } });

let nextId = 100;
const waiting = new Map<number, (result: any) => void>();
function ask(method: string, params: object): Promise<any> {
  const id = nextId++;
  send({ id, method, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

let authenticated = false;
let cancelled: (() => void) | undefined;

const efforts = (values: string[]) => values.map((value) => ({ id: value, value, label: value, default: value === "high" }));
const bundled = [
  { modelId: "grok-4.6", name: "Grok 4.6", description: "SpaceXAI's latest frontier model", _meta: { supportsReasoningEffort: true, reasoningEffort: "high", reasoningEfforts: efforts(["xhigh", "high", "medium", "low"]) } },
  { modelId: "grok-4.5", name: "Grok 4.5", _meta: { supportsReasoningEffort: true, reasoningEffort: "high", reasoningEfforts: efforts(["high", "medium", "low"]) } },
  { modelId: "grok-code-fast-1", name: "Grok Code Fast", _meta: { supportsReasoningEffort: false } },
];
let catalog = bundled;
let model = "grok-4.6";
let effort = "high";

const models = () => ({ currentModelId: model, availableModels: catalog });
const configOptions = () => [
  { id: "model", name: "Model", category: "model", type: "select", currentValue: model, options: catalog.map((known) => ({ value: known.modelId, name: known.name })) },
  { id: "reasoning_effort", name: "Reasoning Effort", category: "thought_level", type: "select", currentValue: effort, options: ["xhigh", "high", "medium", "low"].map((value) => ({ value, name: value })) },
];

const authRequired = (id: number) => send({ id, error: { code: -32000, message: "Authentication required", data: "no auth method id provided" } });

async function prompt(sessionId: string, text: string, cwd: string): Promise<object> {
  if (text === "hello") {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Hi." } });
    return { stopReason: "end_turn" };
  }
  if (text === "catalog") {
    // What a finished catalog refresh sends, for the whole process.
    catalog = [{ modelId: "grok-4.7", name: "Grok 4.7", _meta: { supportsReasoningEffort: true, reasoningEffort: "high", reasoningEfforts: efforts(["xhigh", "high", "low"]) } }, ...bundled];
    send({ method: "_x.ai/models/update", params: models() });
    return { stopReason: "end_turn" };
  }
  if (text === "work") {
    update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Run it, then edit." } });
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Looking." } });
    const run = { toolCallId: "call_bash", title: "echo hi", kind: "execute", status: "pending", rawInput: { command: "echo hi" } };
    update(sessionId, { sessionUpdate: "tool_call", ...run });
    // The options a client that isn't Grok's own TUI is offered for a command.
    const ran = await ask("session/request_permission", {
      sessionId,
      toolCall: run,
      options: [
        { optionId: "always-allow", name: "Yes, and don't ask again for bash commands", kind: "allow_always" },
        { optionId: "allow-once", name: "Yes, proceed", kind: "allow_once" },
        { optionId: "reject-once", name: "No, and tell Grok what to do differently", kind: "reject_once" },
        { optionId: "reject-always", name: "No, and don't ask again for this command", kind: "reject_always" },
      ],
    });
    record({ answered: ran });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "call_bash", status: "completed", content: [{ type: "content", content: { type: "text", text: "hi\n" } }] });
    const path = `${cwd}/hello.txt`;
    const edit = { toolCallId: "call_edit", title: "Edit hello.txt", kind: "edit", status: "pending", rawInput: { file_path: path, old_string: "one", new_string: "two" }, locations: [{ path }] };
    update(sessionId, { sessionUpdate: "tool_call", ...edit });
    const edited = await ask("session/request_permission", {
      sessionId,
      toolCall: edit,
      options: [
        { optionId: "allow-edits-session", name: "Yes, allow all edits during this session", kind: "allow_always" },
        { optionId: "allow-once", name: "Yes", kind: "allow_once" },
        { optionId: "reject-once", name: "No, and tell Grok what to do differently", kind: "reject_once" },
      ],
    });
    record({ answered: edited });
    // Its search and replace: the diff holds only the strings swapped, and its _meta where.
    const place = { old_string: "one", old_line: 2, new_string: "two", new_line: 2, context_before: "zero\n", context_after: "\nend", line_prefix: "" };
    update(sessionId, {
      sessionUpdate: "tool_call_update",
      toolCallId: "call_edit",
      status: "completed",
      content: [{ type: "diff", path, oldText: "one", newText: "two", _meta: { details: [place] } }],
      rawOutput: { SearchReplace: { EditsApplied: { old_string: "one", new_string: "two", tool_output_for_prompt: "", absolute_path: path, edits: { details: [place] } } } },
    });
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
    const run = { toolCallId: "call_sleep", title: "sleep 60", kind: "execute", status: "pending", rawInput: { command: "sleep 60" } };
    update(sessionId, { sessionUpdate: "tool_call", ...run });
    const stopped = new Promise<void>((resolve) => (cancelled = resolve));
    // Always-approve runs it unasked.
    if (!alwaysApprove) void ask("session/request_permission", { sessionId, toolCall: run, options: [{ optionId: "allow-once", name: "Yes, proceed", kind: "allow_once" }] });
    else update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "call_sleep", status: "in_progress" });
    await stopped;
    return { stopReason: "cancelled" };
  }
  return { stopReason: "end_turn" };
}

const cwds = new Map<string, string>();

async function handle(message: any): Promise<void> {
  const { id, method, params } = message;
  switch (method) {
    case "initialize": {
      const authMethods = [
        ...(keyAllowed ? [{ id: "xai.api_key", name: "xai.api_key", description: "XAI_API_KEY or api_key/env_key in config.toml" }] : []),
        ...(loggedIn ? [{ id: "cached_token", name: "cached_token", description: "Cached token from ~/.grok/auth.json" }] : []),
        { id: "grok.com", name: "Grok", description: "Sign in with Grok" },
      ];
      return send({
        id,
        result: {
          protocolVersion: 1,
          agentCapabilities: { loadSession: true, promptCapabilities: { image: false, audio: false, embeddedContext: true }, sessionCapabilities: { list: {}, resume: {}, close: {} } },
          authMethods,
          _meta: { grokShell: true, defaultAuthMethodId: loggedIn ? "cached_token" : keyAllowed ? "xai.api_key" : null, agentVersion: "1.0.41", modelState: models() },
        },
      });
    }
    case "authenticate":
      if (params.methodId === "cached_token" && loggedIn) {
        authenticated = true;
        return send({ id, result: {} });
      }
      // grok.com would open a browser, and xai.api_key take a key: neither is OriCode's to start.
      return send({ id, error: { code: -32000, message: "Authentication required", data: `the stand-in won't run ${params.methodId}` } });
    case "session/new": {
      if (!authenticated) return authRequired(id);
      const sessionId = "019a0e24-0000-7000-8000-000000000001";
      cwds.set(sessionId, params.cwd);
      send({ id, result: { sessionId, models: models(), configOptions: configOptions(), _meta: { currentWorkingDirectory: params.cwd } } });
      return update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: [{ name: "compact", description: "Compress conversation history to save context window", input: { hint: "optional context about what to preserve" } }] });
    }
    case "session/resume":
      if (!authenticated) return authRequired(id);
      cwds.set(params.sessionId, params.cwd);
      return send({ id, result: { models: models(), configOptions: configOptions() } });
    case "session/set_mode":
      send({ id, result: {} });
      return update(params.sessionId, { sessionUpdate: "current_mode_update", currentModeId: params.modeId });
    case "session/set_config_option":
      if (params.configId === "model") model = params.value;
      if (params.configId === "reasoning_effort") effort = params.value;
      return send({ id, result: { configOptions: configOptions() } });
    case "session/prompt": {
      const text = params.prompt.find((block: any) => block.type === "text")?.text ?? "";
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
