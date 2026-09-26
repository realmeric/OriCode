// A stand-in for `codex app-server` and `codex login status`, for the engine's tests: JSON-RPC
// over NDJSON with no "jsonrpc" on its lines, as Codex 0.157.1 writes them, a scripted turn for
// each prompt, and no model anywhere. Every message it's sent goes to CODEX_LOG, one per line.
// CODEX_SIGNED_OUT=1 makes it signed out.
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const signedOut = process.env.CODEX_SIGNED_OUT === "1";

if (process.argv[2] === "login") {
  process.stdout.write(signedOut ? "Not logged in\n" : "Logged in using ChatGPT\n");
  process.exit(signedOut ? 1 : 0);
}

const logFile = process.env.CODEX_LOG;
const record = (entry: unknown) => logFile && appendFileSync(logFile, JSON.stringify(entry) + "\n");
record({ env: Object.keys(process.env).filter((key) => key.startsWith("CLAUDE")), cwd: process.cwd() });

const send = (message: object) => process.stdout.write(JSON.stringify(message) + "\n");
const pause = (ms = 5) => new Promise((resolve) => setTimeout(resolve, ms));

let threadId = "";
let turnId = "";
let turns = 0;
let nextId = 0;
const waiting = new Map<number, (result: any) => void>();
let steered: ((params: any) => void) | undefined;
let interrupted: (() => void) | undefined;

const notify = (method: string, params: object = {}) => send({ method, params: { threadId, turnId, ...params } });

function ask(method: string, params: object): Promise<any> {
  const id = nextId++;
  send({ id, method, params: { threadId, turnId, ...params } });
  return new Promise((resolve) => waiting.set(id, resolve));
}

function say(id: string, text: string): void {
  notify("item/started", { item: { type: "agentMessage", id, text: "", phase: "final_answer" } });
  notify("item/agentMessage/delta", { itemId: id, delta: text });
  notify("item/completed", { item: { type: "agentMessage", id, text, phase: "final_answer" } });
}

const usage = (input: number, cached: number, output: number) => {
  const last = { totalTokens: input + output, inputTokens: input, cachedInputTokens: cached, cacheWriteInputTokens: 0, outputTokens: output, reasoningOutputTokens: 0 };
  notify("thread/tokenUsage/updated", { tokenUsage: { total: last, last, modelContextWindow: 258400 } });
};

const limits = (usedPercent: number) =>
  send({
    method: "account/rateLimits/updated",
    params: { rateLimits: { limitId: "codex", primary: { usedPercent, windowDurationMins: 43200, resetsAt: 1792439399 }, secondary: null, planType: "go", rateLimitReachedType: usedPercent >= 100 ? "primary" : null } },
  });

const complete = (status: string, error: object | null = null) => notify("turn/completed", { turn: { id: turnId, items: [], status, error } });

const command = (id: string, text: string, actions: object[], extra: object = {}) => ({
  type: "commandExecution",
  id,
  command: `/bin/zsh -lc '${text}'`,
  cwd: process.cwd(),
  processId: null,
  source: "agent",
  status: "inProgress",
  commandActions: actions,
  aggregatedOutput: null,
  exitCode: null,
  durationMs: null,
  ...extra,
});

async function turn(text: string, clientId: string | null): Promise<void> {
  notify("turn/started", { turn: { id: turnId, items: [], status: "inProgress" } });
  const user = { type: "userMessage", id: `user-${turns}`, clientId, content: [{ type: "text", text, text_elements: [] }] };
  notify("item/started", { item: user });
  notify("item/completed", { item: user });
  if (text === "hello") {
    say("m-1", "Hi.");
    usage(100, 0, 3);
    return complete("completed");
  }
  if (text === "work") {
    notify("item/started", { item: { type: "reasoning", id: "r-1", summary: [], content: [] } });
    notify("item/reasoning/summaryTextDelta", { itemId: "r-1", delta: "Reading first.", summaryIndex: 0 });
    notify("item/reasoning/summaryTextDelta", { itemId: "r-1", delta: "Then the edit.", summaryIndex: 1 });
    say("m-1", "Let me look.");
    const read = command("exec-1", "cat a.txt", [{ type: "read", command: "cat a.txt", name: "a.txt", path: "/w/a.txt" }]);
    notify("item/started", { item: read });
    notify("item/completed", { item: { ...read, status: "completed", aggregatedOutput: "one\ntwo\nthree\n", exitCode: 0 } });
    const plan = [
      { step: "Read a.txt", status: "completed" },
      { step: "Edit a.txt", status: "inProgress" },
      { step: "Run the tests", status: "pending" },
    ];
    notify("turn/plan/updated", { explanation: null, plan });
    notify("turn/plan/updated", { explanation: null, plan });
    const test = command("exec-2", "make test", [{ type: "unknown", command: "make test" }]);
    notify("item/started", { item: test });
    const run = await ask("item/commandExecution/requestApproval", {
      kind: "command",
      itemId: "exec-2",
      command: test.command,
      cwd: process.cwd(),
      commandActions: test.commandActions,
      availableDecisions: ["accept", { acceptWithExecpolicyAmendment: { execpolicy_amendment: ["make", "test"] } }, "cancel"],
    });
    const ran = run.decision === "accept";
    notify("item/completed", { item: { ...test, status: ran ? "completed" : "declined", aggregatedOutput: ran ? "ok\n" : null, exitCode: ran ? 0 : null } });
    const edit = {
      type: "fileChange",
      id: "patch-1",
      status: "inProgress",
      changes: [
        { path: "/w/a.txt", kind: { type: "update", move_path: null }, diff: "@@ -1,3 +1,3 @@\n one\n-two\n+2\n three\n" },
        { path: "/w/b.txt", kind: { type: "add" }, diff: "new\nfile\n" },
      ],
    };
    notify("item/started", { item: edit });
    const edited = await ask("item/fileChange/requestApproval", { itemId: "patch-1", reason: null });
    notify("item/completed", { item: { ...edit, status: edited.decision.startsWith("accept") ? "completed" : "declined" } });
    usage(1000, 800, 20);
    usage(1200, 1000, 30);
    limits(1);
    limits(1);
    limits(2);
    say("m-2", "Done.");
    return complete("completed");
  }
  if (text === "slow") {
    notify("item/agentMessage/delta", { itemId: "m-1", delta: "Working." });
    const steer = await new Promise<any>((resolve) => {
      steered = resolve;
      interrupted = () => resolve(undefined);
    });
    if (!steer) return complete("interrupted");
    notify("item/started", { item: { type: "userMessage", id: "user-steer", clientId: steer.clientUserMessageId, content: steer.input } });
    notify("item/agentMessage/delta", { itemId: "m-2", delta: "Got it." });
    return complete("completed");
  }
  if (text === "wait") {
    const rm = command("exec-3", "rm -rf build", [{ type: "unknown", command: "rm -rf build" }]);
    notify("item/started", { item: rm });
    void ask("item/commandExecution/requestApproval", { kind: "command", itemId: "exec-3", command: rm.command, availableDecisions: ["accept", "acceptForSession", "decline", "cancel"] });
    await new Promise<void>((resolve) => (interrupted = resolve));
    return complete("interrupted");
  }
  if (text === "question") {
    await ask("item/tool/requestUserInput", {
      itemId: "q-1",
      isBlocking: true,
      autoResolutionMs: null,
      questions: [{ id: "color", header: "Colour", question: "Which colour?", isOther: false, isSecret: false, options: [{ label: "Red", description: "Warm" }, { label: "Blue", description: "Cool" }] }],
    });
    return complete("completed");
  }
  if (text === "limit") {
    limits(100);
    notify("error", { error: { message: "You've hit your usage limit.", codexErrorInfo: "usageLimitExceeded", additionalDetails: null }, willRetry: false });
    return complete("failed", { message: "You've hit your usage limit.", codexErrorInfo: "usageLimitExceeded", additionalDetails: null });
  }
  if (text === "die") {
    notify("item/agentMessage/delta", { itemId: "m-1", delta: "About to go." });
    const rm = command("exec-4", "rm x", [{ type: "unknown", command: "rm x" }]);
    notify("item/started", { item: rm });
    void ask("item/commandExecution/requestApproval", { kind: "command", itemId: "exec-4", command: rm.command });
    await pause(50);
    process.stderr.write("codex: out of memory\n");
    process.exit(1);
  }
  complete("completed");
}

const models = [
  {
    id: "gpt-small",
    model: "gpt-small",
    displayName: "GPT Small",
    description: "Quick",
    hidden: false,
    supportedReasoningEfforts: [{ reasoningEffort: "low" }, { reasoningEffort: "medium" }, { reasoningEffort: "high" }],
    defaultReasoningEffort: "medium",
    isDefault: false,
  },
  {
    id: "gpt-large",
    model: "gpt-large",
    displayName: "GPT Large",
    description: "Deep",
    hidden: false,
    supportedReasoningEfforts: ["low", "medium", "high", "xhigh", "max", "ultra"].map((reasoningEffort) => ({ reasoningEffort, description: "" })),
    defaultReasoningEffort: "high",
    isDefault: true,
  },
];

async function handle(message: any): Promise<void> {
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      return send({ id, result: { userAgent: "stand-in", codexHome: "/nowhere", platformFamily: "unix", platformOs: "macos" } });
    case "initialized":
      return;
    case "account/read":
      return send({ id, result: signedOut ? { account: null, requiresOpenaiAuth: true } : { account: { type: "chatgpt", email: "someone@example.com", planType: "go" }, requiresOpenaiAuth: true } });
    case "model/list":
      return send({ id, result: params.cursor ? { data: [models[1]], nextCursor: null } : { data: [models[0]], nextCursor: "page-2" } });
    case "thread/start":
      threadId = "t-1";
      return send({ id, result: { thread: { id: threadId }, model: params.model ?? "gpt-small", cwd: params.cwd, approvalPolicy: params.approvalPolicy } });
    case "thread/resume":
      if (params.threadId === "gone") return send({ id, error: { code: -32600, message: "no rollout found for thread id gone" } });
      threadId = params.threadId;
      return send({ id, result: { thread: { id: threadId, turns: [] } } });
    case "turn/start":
      turnId = `turn-${++turns}`;
      send({ id, result: { turn: { id: turnId, items: [], status: "inProgress" } } });
      return turn(params.input.find((part: any) => part.type === "text")?.text ?? "", params.clientUserMessageId ?? null);
    case "turn/steer":
      if (params.expectedTurnId !== turnId || !steered) return send({ id, error: { code: -32600, message: "no active turn to steer" } });
      send({ id, result: { turnId } });
      return steered(params);
    case "turn/interrupt":
      send({ id, result: {} });
      return interrupted?.();
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
