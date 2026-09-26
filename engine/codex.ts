import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import { createInterface } from "node:readline";
import { agentEnvironment } from "./acp.ts";
import { hunks, todos, toolView, type Hunk, type Todo, type View } from "./acp-map.ts";
import { lastLine } from "./shell.ts";
import { version } from "./version.ts";
import { event, log } from "./wire.ts";

// A thread on Codex, through the user's own `codex app-server`: JSON-RPC over newline-delimited
// JSON on its stdin and stdout, one process per thread. The server leaves "jsonrpc" off its
// lines, so they're read as whatever JSON they are. Codex keeps each thread OriCode opens in the
// user's own Codex history under ~/.codex/sessions, tagged with OriCode's client name, where
// `codex resume` lists it beside their own. The hooks and MCP servers in the user's ~/.codex start
// with each thread, as they would in Codex.

/// How to run the user's codex, and what goes before `app-server` or `login status`, which is
/// how the tests run a stand-in under node.
export type CodexBinary = { command: string; args?: string[]; env?: Record<string, string> };

export type CodexSendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
  attachments?: { mediaType: string; data: string }[];
  costSoFar?: number;
  id?: string;
};

export type Answer = { requestId: string; allow: boolean; optionId?: string; answers?: Record<string, string> };

/// One of an approval request's `availableDecisions`: a word, or a word keying what it amends.
type Decision = string | Record<string, any>;

type Item = { type: string; id: string; [field: string]: any };

type ToolCall = { id: string; name: string; input: Record<string, unknown>; kind: string; view: View };

type ToolResult = { id: string; content: string; isError: boolean; patch?: Hunk[] };

type Breakdown = { totalTokens: number; inputTokens: number; cachedInputTokens: number; cacheWriteInputTokens: number; outputTokens: number };

type RateLimitWindow = { usedPercent: number; windowDurationMins: number | null; resetsAt: number | null };

type RateLimits = { primary: RateLimitWindow | null; secondary: RateLimitWindow | null; planType: string | null; rateLimitReachedType: string | null };

type TurnError = { message: string; codexErrorInfo: unknown; additionalDetails: string | null };

type Ask = { session: CodexSession; serverId: number | string; reply: (answer: Answer | undefined) => void };

/// What Codex sends that nothing here reads, turned off in initialize so it isn't parsed a
/// token at a time: a command's output as it streams, MCP servers starting, hooks running.
const quiet = [
  "item/commandExecution/outputDelta",
  "item/commandExecution/terminalInteraction",
  "item/fileChange/outputDelta",
  "mcpServer/startupStatus/updated",
  "hook/started",
  "hook/completed",
  "thread/settings/updated",
  "thread/status/changed",
];

/// What an approval request offers when it doesn't say, as the schema of 0.157.1 has it.
const decisions: Decision[] = ["accept", "acceptForSession", "decline", "cancel"];

const signIn = "Codex isn't signed in. Run `codex login` in Terminal, then try again.";

const asks = new Map<string, Ask>();

/// The user's choice for a Codex ask: the decision they picked, or Codex's plain yes or no, or
/// their answers to its questions. False when no Codex thread is waiting on it.
export function answer(params: Answer): boolean {
  const ask = asks.get(params.requestId);
  if (!ask) return false;
  asks.delete(params.requestId);
  ask.reply(params);
  return true;
}

/// A thread's mode as Codex's approval policy and sandbox. Ask asks before anything Codex doesn't
/// know to be read-only. Accept edits lets it write inside the folder unasked; Codex can't tell
/// an edit from a command that writes, so a command inside the folder runs unasked too. Auto
/// leaves the sandbox to the user's config.toml and Codex to judge when to ask. Plan reads and
/// never asks, so nothing it does can change a file. Don't ask runs anything anywhere.
export function policy(mode: string | undefined): { approvalPolicy: string; sandbox?: string } {
  switch (mode) {
    case "acceptEdits":
      return { approvalPolicy: "on-request", sandbox: "workspace-write" };
    case "auto":
      return { approvalPolicy: "on-request" };
    case "plan":
      return { approvalPolicy: "never", sandbox: "read-only" };
    case "bypassPermissions":
      return { approvalPolicy: "never", sandbox: "danger-full-access" };
    default:
      return { approvalPolicy: "untrusted" };
  }
}

/// A decision as an ask's choice, worded as Codex's own prompt words it.
export function choiceOf(decision: Decision): { id: string; name: string; kind: string } {
  const id = typeof decision === "string" ? decision : (Object.keys(decision)[0] ?? "");
  const body = typeof decision === "string" ? undefined : decision[id];
  switch (id) {
    case "accept":
      return { id, name: "Yes", kind: "allow_once" };
    case "acceptForSession":
      return { id, name: "Yes, for this thread", kind: "allow_always" };
    case "acceptWithExecpolicyAmendment": {
      const prefix = body?.execpolicy_amendment;
      return { id, name: Array.isArray(prefix) ? `Yes, and don't ask again for \`${prefix.join(" ")}\`` : "Yes, and don't ask again", kind: "allow_always" };
    }
    case "applyNetworkPolicyAmendment": {
      const rule = body?.network_policy_amendment;
      const allow = rule?.action !== "deny";
      return { id, name: `${allow ? "Always allow" : "Never allow"} ${rule?.host ?? "this host"}`, kind: allow ? "allow_always" : "reject_always" };
    }
    case "decline":
      return { id, name: "No", kind: "reject_once" };
    case "cancel":
      return { id, name: "No, and stop", kind: "reject_once" };
    default:
      return { id, name: id, kind: "other" };
  }
}

function decide(offered: Decision[], answer: Answer): Decision {
  const wanted = answer.allow ? "allow_once" : "reject_once";
  return offered.find((decision) => choiceOf(decision).id === answer.optionId) ?? offered.find((decision) => choiceOf(decision).kind === wanted) ?? (answer.allow ? "accept" : "decline");
}

/// The session a thread on Codex talks to, one app-server per thread. It implements
/// provider.ts's Session once K-172 lands.
export class CodexSession {
  readonly id: string;
  private binary: CodexBinary;
  private server: AppServer | undefined;
  private cwd = "";
  /// Codex's thread, which is the session the app keeps.
  private threadId: string | undefined;
  /// Whether this process has the thread open, and under which mode.
  private live = false;
  private openedMode: string | undefined;
  private mode: string | undefined;
  private running = false;
  private interrupted = false;
  private errored = false;
  /// Counts turns, so what a finished one leaves behind can't reach the next.
  private turns = 0;
  private turnStart = 0;
  private turnId: string | undefined;
  /// This turn's items as Codex last described them, which its approval requests name by id.
  private items = new Map<string, Item>();
  private used = new Set<string>();
  private done = new Set<string>();
  private summaryParts = new Map<string, number>();
  private lastPlan = "";
  private lastError: TurnError | undefined;
  private spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  private context: { used: number; window: number } | undefined;
  private rateLimits: RateLimits | undefined;
  private limitsTold = "";
  /// Sent during a turn before Codex had said the turn's id, which a steer names.
  private steering: CodexSendParams[] = [];
  /// Steered into the turn and not yet seen in it.
  private steered = new Set<string>();
  /// Sent as the turn was ending, too late to steer in: each runs as a turn of its own.
  private queued: CodexSendParams[] = [];
  private idleSince: number | undefined;
  onIdle: (() => void) | undefined;

  constructor(id: string, binary: CodexBinary = { command: "codex" }) {
    this.id = id;
    this.binary = binary;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// A send during a turn steers it, and Codex takes it at its next step; the reply says it's
  /// waiting. Otherwise it starts a turn, and what happens comes as events.
  async send(params: CodexSendParams): Promise<boolean> {
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    if (this.running) {
      this.steer(params);
      return true;
    }
    this.begin(params);
    return false;
  }

  /// Stop: Codex is told to interrupt the turn, which it then ends as interrupted, and every ask
  /// and message still waiting in it is let go.
  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.interrupted = true;
    for (const params of [...this.steering.splice(0), ...this.queued.splice(0)]) {
      if (params.id) event("message.cancelled", { threadId: this.id, messageId: params.id });
    }
    for (const messageId of this.steered) event("message.cancelled", { threadId: this.id, messageId });
    this.steered.clear();
    this.cancelAsks();
    if (this.turnId) await this.stopTurn();
  }

  /// A mode is a policy and a sandbox Codex takes when a thread opens, so a new one reopens the
  /// thread at the next turn. It can't reach the turn that's running.
  async setMode(mode: string): Promise<boolean> {
    this.mode = mode;
    return !this.running;
  }

  async setFast(_fast: boolean): Promise<boolean> {
    return false;
  }

  /// Codex's subagents run as threads of their own, which aren't followed yet.
  watchHeads(_on: boolean): void {}

  async stopTask(_taskId: string): Promise<void> {}

  async commands(): Promise<{ name: string; description: string; argumentHint: string }[] | undefined> {
    return undefined;
  }

  /// Ends the app-server of a thread idle this long with nothing asked of the user. The next
  /// send starts one that resumes the thread.
  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.server || this.running || this.idleSince === undefined) return false;
    if (now - this.idleSince < idleMs) return false;
    if ([...asks.values()].some((ask) => ask.session === this)) return false;
    this.close();
    return true;
  }

  idleLeft(idleMs: number, now = Date.now()): number | undefined {
    if (!this.server || this.running || this.idleSince === undefined) return undefined;
    return Math.max(0, this.idleSince + idleMs - now);
  }

  /// The thread is gone or the engine is going. A turn still running ends with nothing said, as
  /// a Claude thread's does.
  close(): void {
    this.running = false;
    this.cancelAsks();
    this.stop();
  }

  private stop(): void {
    const server = this.server;
    this.server = undefined;
    this.live = false;
    server?.close();
  }

  private begin(params: CodexSendParams): void {
    log(`send thread=${this.id} agent=codex model=${params.model ?? "default"} effort=${params.effort ?? "default"} mode=${params.permissionMode ?? "default"}`);
    this.running = true;
    this.interrupted = false;
    this.errored = false;
    this.lastError = undefined;
    this.turnStart = Date.now();
    this.turnId = undefined;
    this.items.clear();
    this.used.clear();
    this.done.clear();
    this.summaryParts.clear();
    this.spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
    const turn = ++this.turns;
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    void this.turn(params, turn);
  }

  private async turn(params: CodexSendParams, turn: number): Promise<void> {
    try {
      const mode = params.permissionMode ?? this.mode ?? "default";
      this.mode = mode;
      if (this.server && (params.cwd !== this.cwd || mode !== this.openedMode)) this.stop();
      if (!this.server) await this.start(params.cwd);
      if (!this.live) await this.open(params, mode);
      if (this.interrupted) return this.finish(turn, "interrupted");
      event("turn.started", { threadId: this.id, sessionId: this.threadId });
      const reply: { turn: { id: string } } = await this.request("turn/start", {
        threadId: this.threadId,
        input: input(params),
        model: params.model ?? null,
        effort: params.effort ?? null,
        summary: "auto",
        clientUserMessageId: params.id ?? null,
      });
      if (turn !== this.turns) return;
      this.began(reply.turn.id);
      if (this.interrupted) await this.stopTurn();
    } catch (error) {
      // The server going says so itself; a close says nothing.
      if (turn !== this.turns || !this.running) return;
      // A server that found no login keeps finding none, so the next send starts another.
      if (error instanceof SignedOut) this.stop();
      this.fail(error instanceof SignedOut ? signIn : describe(error));
      this.finish(turn, "error_during_execution");
    }
  }

  private async start(cwd: string): Promise<void> {
    log(`start thread=${this.id} ${this.binary.command} app-server cwd=${cwd}`);
    const server = new AppServer(this.binary, cwd);
    this.server = server;
    this.cwd = cwd;
    server.onNotification = (method, params) => this.notified(method, params);
    server.onRequest = (id, method, params) => this.asked(server, id, method, params);
    server.onExit = (message) => this.exited(server, message);
    await server.initialize();
    // Codex would open the thread signed out and fail its first request to the model; asking
    // first says so before anything starts.
    const account: { account: unknown; requiresOpenaiAuth: boolean } = await server.request("account/read", {});
    if (!account.account && account.requiresOpenaiAuth) throw new SignedOut();
  }

  /// Opens the thread on this process: resumed without its turns, which the app has already,
  /// else new. One that's gone is said to be, and the turn goes on in a new one.
  private async open(params: CodexSendParams, mode: string): Promise<void> {
    const earlier = params.sessionId ?? this.threadId;
    const setup = { cwd: params.cwd, model: params.model ?? null, ...policy(mode) };
    let opened = false;
    if (earlier) {
      try {
        await this.request("thread/resume", { threadId: earlier, excludeTurns: true, ...setup });
        this.threadId = earlier;
        opened = true;
      } catch (error) {
        if (!this.server) throw error;
        log(`thread ${earlier} not resumed for thread=${this.id}: ${describe(error)}`);
        event("session.lost", { threadId: this.id });
      }
    }
    if (!opened) {
      const reply: { thread: { id: string } } = await this.request("thread/start", setup);
      this.threadId = reply.thread.id;
    }
    this.live = true;
    this.openedMode = mode;
  }

  private began(turnId: string): void {
    if (this.turnId === turnId) return;
    this.turnId = turnId;
    for (const params of this.steering.splice(0)) this.steer(params);
  }

  private steer(params: CodexSendParams): void {
    if (!this.turnId) {
      this.steering.push(params);
      return;
    }
    log(`steer thread=${this.id} turn=${this.turnId}`);
    if (params.id) this.steered.add(params.id);
    this.request("turn/steer", { threadId: this.threadId, input: input(params), expectedTurnId: this.turnId, clientUserMessageId: params.id ?? null }).catch((error) => {
      // The turn ended before Codex took it: it runs as a turn of its own.
      log(`steer refused for thread=${this.id}: ${describe(error)}`);
      if (params.id) this.steered.delete(params.id);
      if (this.running) this.queued.push(params);
      else this.begin(params);
    });
  }

  private async stopTurn(): Promise<void> {
    await this.request("turn/interrupt", { threadId: this.threadId, turnId: this.turnId }).catch((error) => log(`interrupt for thread=${this.id}: ${describe(error)}`));
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  private finish(turn: number, reason: string): void {
    if (turn !== this.turns || !this.running) return;
    this.running = false;
    this.turnId = undefined;
    this.idleSince = Date.now();
    // Codex takes whatever was steered in before a turn ends, so one it hasn't shown yet is in.
    for (const messageId of this.steered) event("message.taken", { threadId: this.id, messageId, newTurn: false });
    this.steered.clear();
    const waiting = [...this.steering.splice(0), ...this.queued.splice(0)];
    event("turn.done", {
      threadId: this.id,
      sessionId: this.threadId,
      stopReason: this.interrupted ? "interrupted" : reason,
      durationMs: Date.now() - this.turnStart,
      costUSD: undefined,
      usage: this.spent,
      context: this.context,
      waiting: waiting.length,
    });
    // The first starts a turn, and the rest steer into it.
    for (const params of waiting) {
      if (this.running) this.steer(params);
      else this.begin(params);
    }
    if (!this.running) this.onIdle?.();
  }

  /// Codex's turn has ended: completed, interrupted, or failed with why. A usage limit it names
  /// a reset for says so as a limit, not an error.
  private completed(turn: { status: string; error: TurnError | null }): void {
    if (turn.status === "failed") {
      const error = turn.error ?? this.lastError;
      const limit = error?.codexErrorInfo === "usageLimitExceeded" ? this.limitReached() : undefined;
      if (limit) event("limited", { threadId: this.id, ...limit });
      else this.fail(error?.codexErrorInfo === "unauthorized" ? signIn : (error?.message ?? "Codex couldn't finish the turn."));
    }
    this.finish(this.turns, turn.status === "interrupted" ? "interrupted" : turn.status === "failed" ? "error_during_execution" : "end_turn");
  }

  private limitReached(): { resetsAt: number; window: string } | undefined {
    const full = this.rateLimits && limitsOf(this.rateLimits).windows.find((window) => window.used >= 1);
    return full && { resetsAt: full.resetsAt, window: full.id };
  }

  private cancelAsks(): void {
    for (const [requestId, ask] of asks) {
      if (ask.session !== this) continue;
      asks.delete(requestId);
      event("ask.cancelled", { threadId: this.id, requestId });
      ask.reply(undefined);
    }
  }

  /// The app-server has gone, whether it quit, crashed or never started. A turn it was in ends
  /// as the engine's stopping, and its asks with it.
  private exited(server: AppServer, message: string): void {
    if (server !== this.server) return;
    log(`thread=${this.id} ${message}`);
    this.cancelAsks();
    this.server = undefined;
    this.live = false;
    if (!this.running) return;
    this.fail(message);
    this.finish(this.turns, "engine_stopped");
  }

  private request(method: string, params: object): Promise<any> {
    if (!this.server) return Promise.reject(new Error("Codex isn't running."));
    return this.server.request(method, params);
  }

  private notified(method: string, params: any): void {
    // Codex's subagents speak on the same connection under threads of their own.
    if (params?.threadId && this.threadId && params.threadId !== this.threadId) return;
    switch (method) {
      case "thread/tokenUsage/updated": {
        const usage: { last: Breakdown; modelContextWindow: number | null } = params.tokenUsage;
        this.context = { used: usage.last.totalTokens, window: usage.modelContextWindow ?? this.context?.window ?? 0 };
        if (!this.running) return;
        // `last` is one request to the model, and a turn makes several. Codex counts cached input
        // inside its input, which Claude's usage keeps apart.
        this.spent.input += usage.last.inputTokens - usage.last.cachedInputTokens;
        this.spent.output += usage.last.outputTokens;
        this.spent.cacheRead += usage.last.cachedInputTokens;
        this.spent.cacheWrite += usage.last.cacheWriteInputTokens ?? 0;
        return;
      }
      case "account/rateLimits/updated": {
        this.rateLimits = params.rateLimits;
        const limits = limitsOf(params.rateLimits);
        const told = limitsKey(limits);
        if (told === this.limitsTold) return;
        this.limitsTold = told;
        event("limits", { threadId: this.id, ...limits });
        return;
      }
      case "serverRequest/resolved":
        // Codex gave up on an ask itself, as it does when its turn ends.
        for (const [requestId, ask] of asks) {
          if (ask.session !== this || ask.serverId !== params.requestId) continue;
          asks.delete(requestId);
          event("ask.cancelled", { threadId: this.id, requestId });
        }
        return;
    }
    if (!this.running) return;
    switch (method) {
      case "turn/started":
        this.began(params.turn.id);
        return;
      case "item/agentMessage/delta":
        event("text", { threadId: this.id, delta: params.delta });
        return;
      case "item/reasoning/summaryTextDelta": {
        // Each part of a summary is a paragraph of its own.
        const part = this.summaryParts.get(params.itemId);
        this.summaryParts.set(params.itemId, params.summaryIndex);
        const gap = part !== undefined && part !== params.summaryIndex ? "\n\n" : "";
        event("thinking", { threadId: this.id, delta: gap + params.delta });
        return;
      }
      case "item/reasoning/textDelta":
        event("thinking", { threadId: this.id, delta: params.delta });
        return;
      case "item/started":
        this.started(params.item);
        return;
      case "item/completed":
        this.itemDone(params.item);
        return;
      case "turn/plan/updated":
        this.plan(params.plan ?? []);
        return;
      case "error":
        if (params.willRetry) log(`thread=${this.id} Codex retrying: ${params.error?.message}`);
        else this.lastError = params.error;
        return;
      case "turn/completed":
        this.completed(params.turn);
        return;
    }
  }

  private started(item: Item): void {
    if (item.type === "userMessage") {
      if (item.clientId && this.steered.delete(item.clientId)) event("message.taken", { threadId: this.id, messageId: item.clientId, newTurn: false });
      return;
    }
    this.items.set(item.id, item);
    this.use(item);
  }

  private itemDone(item: Item): void {
    this.items.set(item.id, item);
    this.use(item);
    for (const result of toolResults(item)) {
      if (this.done.has(result.id)) continue;
      this.done.add(result.id);
      event("tool.result", { threadId: this.id, toolUseId: result.id, content: result.content, isError: result.isError, patch: result.patch });
    }
  }

  private use(item: Item): void {
    for (const call of toolCalls(item)) {
      if (this.used.has(call.id)) continue;
      this.used.add(call.id);
      event("tool.use", { threadId: this.id, toolUseId: call.id, name: call.name, input: call.input, kind: call.kind, view: call.view });
    }
  }

  /// Codex's plan is no tool call, and comes whole each time it changes. Each is told as a
  /// TodoWrite call, which the plan card already folds into the one it started.
  private plan(steps: { step: string; status: string }[]): void {
    const list: Todo[] = todos(steps.map((step) => ({ content: step.step, status: step.status === "inProgress" ? "in_progress" : step.status })));
    const told = JSON.stringify(list);
    if (told === this.lastPlan) return;
    this.lastPlan = told;
    const toolUseId = `plan-${randomUUID()}`;
    event("tool.use", { threadId: this.id, toolUseId, name: "TodoWrite", input: { todos: list }, kind: "plan", view: { todos: list } });
    event("tool.result", { threadId: this.id, toolUseId, content: "", isError: false });
  }

  private asked(server: AppServer, id: number | string, method: string, params: any): void {
    switch (method) {
      case "item/commandExecution/requestApproval":
      case "item/fileChange/requestApproval":
        return this.approval(server, id, method, params);
      case "item/tool/requestUserInput":
        return this.question(server, id, params);
      case "item/permissions/requestApproval":
        // Wider permissions for the rest of a turn have no ask of their own yet: none are granted,
        // and Codex goes on within the sandbox the thread's mode gave it.
        log(`thread=${this.id} Codex asked for wider permissions, not granted: ${params.reason ?? ""}`);
        return server.respond(id, { permissions: {}, scope: "turn" });
      case "mcpServer/elicitation/request":
        return server.respond(id, { action: "decline", content: null, _meta: null });
      default:
        return server.refuse(id, `${method} isn't offered.`);
    }
  }

  /// A command or an edit Codex wants to run: an ask whose choices are Codex's own decisions,
  /// the one picked going back as it was offered.
  private approval(server: AppServer, id: number | string, method: string, params: any): void {
    const command = method === "item/commandExecution/requestApproval";
    const known = this.items.get(params.itemId);
    const item: Item = known ?? (command ? { type: "commandExecution", id: params.itemId, command: params.command ?? "", cwd: params.cwd, commandActions: params.commandActions ?? [] } : { type: "fileChange", id: params.itemId, changes: [] });
    this.use(item);
    const call = toolCalls(item)[0] ?? { id: params.itemId, name: "Edit", input: {}, kind: "edit", view: {} };
    const offered: Decision[] = params.availableDecisions ?? decisions;
    const stop = offered.includes("cancel") ? "cancel" : "decline";
    const requestId = randomUUID();
    asks.set(requestId, { session: this, serverId: id, reply: (answer) => server.respond(id, { decision: answer ? decide(offered, answer) : stop }) });
    event("ask", {
      threadId: this.id,
      requestId,
      kind: "permission",
      tool: call.name,
      toolUseId: call.id,
      input: call.input,
      toolKind: call.kind,
      view: params.reason ? { ...call.view, description: params.reason } : call.view,
      choices: offered.map(choiceOf),
    });
  }

  /// Codex's questions in AskUserQuestion's shape, which the ask card already draws. The app
  /// answers by each question's words, and Codex wants them by its ids.
  private question(server: AppServer, id: number | string, params: { itemId: string; questions: { id: string; header: string; question: string; options: { label: string; description: string }[] | null }[] }): void {
    const requestId = randomUUID();
    const reply = (answer: Answer | undefined) => {
      const given = answer?.allow ? (answer.answers ?? {}) : {};
      const answers = Object.fromEntries(params.questions.flatMap((question) => (given[question.question] === undefined ? [] : [[question.id, { answers: [given[question.question]] }]])));
      server.respond(id, { answers });
    };
    asks.set(requestId, { session: this, serverId: id, reply });
    const questions = params.questions.map((question) => ({
      question: question.question,
      header: question.header,
      options: (question.options ?? []).map((option) => ({ label: option.label, description: option.description })),
      multiSelect: false,
    }));
    event("ask", { threadId: this.id, requestId, kind: "question", tool: "AskUserQuestion", toolUseId: params.itemId, input: { questions }, toolKind: "question" });
  }
}

/// A Codex item as the tool calls the app draws, a file change being one call for each file.
export function toolCalls(item: Item): ToolCall[] {
  switch (item.type) {
    case "commandExecution": {
      const command = unwrap(item.command ?? "");
      const actions: { type: string; path?: string | null; query?: string | null }[] = item.commandActions ?? [];
      const only = actions.length === 1 ? actions[0] : undefined;
      const input = { command, cwd: item.cwd };
      if (only?.type === "read" && only.path) return [{ id: item.id, name: "Shell", input, kind: "read", view: { path: only.path, command } }];
      if (only?.type === "listFiles") return [{ id: item.id, name: "Shell", input, kind: "list", view: { ...(only.path ? { path: only.path } : {}), command } }];
      if (only?.type === "search") return [{ id: item.id, name: "Shell", input, kind: "search", view: { ...(only.query ? { pattern: only.query } : {}), ...(only.path ? { path: only.path } : {}), command } }];
      return [{ id: item.id, name: "Shell", input, kind: "run", view: { command } }];
    }
    case "fileChange": {
      const changes: { path: string; kind: { type: string; move_path?: string | null } }[] = item.changes ?? [];
      return changes.map((change, index) => {
        const kind = change.kind.type === "add" ? "write" : change.kind.type === "delete" ? "delete" : change.kind.move_path ? "move" : "edit";
        const name = kind === "write" ? "Write" : kind === "delete" ? "Delete" : "Edit";
        const input = change.kind.move_path ? { path: change.path, movePath: change.kind.move_path } : { path: change.path };
        return { id: changeId(item, index), name, input, kind, view: { path: change.path } };
      });
    }
    case "mcpToolCall":
      return [{ id: item.id, name: `mcp__${item.server}__${item.tool}`, input: item.arguments ?? {}, kind: "mcp", view: toolView(item.arguments, null, null) }];
    case "webSearch": {
      const url = item.action?.url;
      return [{ id: item.id, name: "WebSearch", input: { query: item.query }, kind: "web", view: url ? { url } : item.query ? { query: item.query } : {} }];
    }
    default:
      return [];
  }
}

/// What a finished item says, an edit carrying its hunks.
export function toolResults(item: Item): ToolResult[] {
  switch (item.type) {
    case "commandExecution":
      return [{ id: item.id, content: item.aggregatedOutput ?? (item.status === "declined" ? "Declined." : ""), isError: item.status !== "completed" || (item.exitCode ?? 0) !== 0 }];
    case "fileChange": {
      const changes: { path: string; kind: { type: string }; diff: string }[] = item.changes ?? [];
      const applied = item.status === "completed";
      return changes.map((change, index) => ({ id: changeId(item, index), content: applied ? "" : `Not applied: ${item.status}.`, isError: !applied, patch: applied ? patchOf(change) : undefined }));
    }
    case "mcpToolCall": {
      const said = (item.result?.content ?? []).flatMap((block: { type?: string; text?: string }) => (block.type === "text" && block.text ? [block.text] : []));
      return [{ id: item.id, content: item.error?.message ?? said.join("\n"), isError: item.status === "failed" }];
    }
    case "webSearch":
      return [{ id: item.id, content: "", isError: false }];
    default:
      return [];
  }
}

function changeId(item: Item, index: number): string {
  return item.changes.length === 1 ? item.id : `${item.id}:${index}`;
}

/// A change's diff as hunks. Codex sends an edit as a unified diff and a new or deleted file as
/// its whole text.
export function patchOf(change: { kind: { type: string }; diff: string }): Hunk[] {
  if (change.kind.type === "update" || change.diff.startsWith("@@ ")) return unifiedHunks(change.diff);
  return change.kind.type === "add" ? hunks(null, change.diff) : hunks(change.diff, "");
}

export function unifiedHunks(diff: string): Hunk[] {
  const result: Hunk[] = [];
  let hunk: Hunk | undefined;
  for (const line of diff.split("\n")) {
    const header = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line);
    if (header) {
      hunk = { oldStart: Number(header[1]), newStart: Number(header[2]), lines: [] };
      result.push(hunk);
    } else if (hunk && (line[0] === " " || line[0] === "-" || line[0] === "+")) {
      hunk.lines.push(line);
    }
  }
  return result;
}

/// The command inside the login shell Codex wraps it in, `/bin/zsh -lc 'cat hello.txt'`.
export function unwrap(command: string): string {
  const inner = /^\S*\/(?:ba|z)?sh -l?c '([\s\S]*)'$/.exec(command)?.[1];
  return inner === undefined ? command : inner.replaceAll(`'\\''`, "'");
}

type Limits = {
  status: string;
  rateLimitType: string | null;
  utilization: number | null;
  resetsAt: number | null;
  surpassedThreshold: number | null;
  windows: { id: string; label: string; used: number; resetsAt: number }[];
  plan: string | null;
};

/// Codex's rate limits in K-166's shape: fractions used, resets in milliseconds, and each window
/// named by its length. A five-hour and a seven-day window take Claude's ids, so the app names
/// them Session and Weekly as it does Claude's.
export function limitsOf(limits: RateLimits): Limits {
  const windows = [limits.primary, limits.secondary].flatMap((window) =>
    window && window.resetsAt !== null ? [{ ...windowName(window.windowDurationMins), used: window.usedPercent / 100, resetsAt: window.resetsAt * 1000 }] : [],
  );
  const nearest = [...windows].sort((a, b) => b.used - a.used)[0];
  return {
    status: limits.rateLimitReachedType ? "rejected" : "allowed",
    rateLimitType: nearest?.id ?? null,
    utilization: nearest?.used ?? null,
    resetsAt: nearest?.resetsAt ?? null,
    surpassedThreshold: null,
    windows,
    plan: limits.planType,
  };
}

function windowName(minutes: number | null): { id: string; label: string } {
  if (minutes === 300) return { id: "five_hour", label: "5-hour window" };
  if (minutes === 10080) return { id: "seven_day", label: "7-day window" };
  if (!minutes) return { id: "window", label: "Usage window" };
  if (minutes % 1440 === 0) return { id: `${minutes / 1440}_day`, label: `${minutes / 1440}-day window` };
  if (minutes % 60 === 0) return { id: `${minutes / 60}_hour`, label: `${minutes / 60}-hour window` };
  return { id: `${minutes}_minute`, label: `${minutes}-minute window` };
}

/// What the app would see of a report: a reading that moved less than a percent looks the same.
function limitsKey(limits: Limits): string {
  const percent = (fraction: number | null) => (fraction === null ? null : Math.round(fraction * 100));
  return JSON.stringify({ ...limits, utilization: percent(limits.utilization), windows: limits.windows.map((window) => ({ ...window, used: percent(window.used) })) });
}

function input(params: CodexSendParams): object[] {
  const images = (params.attachments ?? []).map((image) => ({ type: "image", url: `data:${image.mediaType};base64,${image.data}` }));
  return [...images, { type: "text", text: params.text, text_elements: [] }];
}

export type CodexModel = { id: string; name: string; description: string; efforts: string[]; defaultEffort: string | null; ultra: boolean; isDefault: boolean };

/// The models the user's Codex offers, each with the levels it takes, from low to max as Codex
/// lists them; ultra is a switch of its own, as Claude's Ultracode is. It asks a short-lived
/// app-server, which reaches no model.
export async function listModels(binary: CodexBinary = { command: "codex" }): Promise<CodexModel[]> {
  return withServer(binary, async (server) => {
    const models: CodexModel[] = [];
    let cursor: string | null = null;
    do {
      const page: { data: { model: string; displayName: string; description: string; hidden: boolean; supportedReasoningEfforts: { reasoningEffort: string }[]; defaultReasoningEffort: string | null; isDefault: boolean }[]; nextCursor: string | null } =
        await server.request("model/list", { cursor, includeHidden: false });
      for (const model of page.data) {
        const levels = model.supportedReasoningEfforts.map((option) => option.reasoningEffort);
        models.push({
          id: model.model,
          name: model.displayName,
          description: model.description,
          efforts: levels.filter((level) => level !== "ultra"),
          defaultEffort: model.defaultReasoningEffort,
          ultra: levels.includes("ultra"),
          isDefault: model.isDefault,
        });
      }
      cursor = page.nextCursor;
    } while (cursor);
    return models;
  });
}

export type CodexAvailability = { state: "ready" | "signedOut" | "missing"; plan: string | null; hint: string | null };

/// Whether the user's codex is there and signed in, asked the way Terminal would, with the plan
/// its account read gives. Nothing that holds the login is read.
export async function availability(binary: CodexBinary = { command: "codex" }): Promise<CodexAvailability> {
  const status = await new Promise<number | "missing">((resolve) => {
    execFile(binary.command, [...(binary.args ?? []), "login", "status"], { env: agentEnvironment(binary.env), timeout: 10_000 }, (error) => {
      if (!error) return resolve(0);
      resolve((error as NodeJS.ErrnoException).code === "ENOENT" ? "missing" : typeof error.code === "number" ? error.code : 1);
    });
  });
  if (status === "missing") return { state: "missing", plan: null, hint: "Codex isn't installed. Install it with `npm install -g @openai/codex`, then run `codex login`." };
  if (status !== 0) return { state: "signedOut", plan: null, hint: "Run `codex login` in Terminal and log in." };
  const account = await withServer(binary, (server) => server.request("account/read", {})).catch((error) => {
    log(`codex account/read: ${describe(error)}`);
    return undefined;
  });
  return { state: "ready", plan: account?.account?.planType ?? account?.account?.type ?? null, hint: null };
}

async function withServer<T>(binary: CodexBinary, use: (server: AppServer) => Promise<T>): Promise<T> {
  const server = new AppServer(binary, homedir());
  try {
    await server.initialize();
    return await use(server);
  } finally {
    server.close();
  }
}

class SignedOut extends Error {}

/// One `codex app-server` and the JSON-RPC spoken with it.
class AppServer {
  private child: ChildProcessWithoutNullStreams;
  private nextId = 0;
  private pending = new Map<number, { resolve: (result: any) => void; reject: (error: Error) => void }>();
  /// The last of what it wrote to stderr, which says why it went when it goes.
  private stderr = "";
  private gone = false;
  onNotification: (method: string, params: any) => void = () => {};
  onRequest: (id: number | string, method: string, params: any) => void = (id, method) => this.refuse(id, `${method} isn't offered.`);
  onExit: (message: string) => void = () => {};

  constructor(binary: CodexBinary, cwd: string) {
    const child = spawn(binary.command, [...(binary.args ?? []), "app-server"], { cwd, env: agentEnvironment(binary.env), stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    // Written to after it has gone, its stdin fails with EPIPE, which unheard ends the engine.
    child.stdin.on("error", () => {});
    child.stderr.on("data", (chunk: Buffer) => {
      process.stderr.write(chunk);
      this.stderr = (this.stderr + chunk.toString("utf8")).slice(-4096);
    });
    createInterface({ input: child.stdout }).on("line", (line) => this.receive(line));
    child.on("error", (error) => this.exit(`Couldn't start Codex: ${error.message}`));
    // Once its pipes have closed, so the last of its stderr has been read.
    child.on("close", (code, signal) => this.exit(`Codex stopped${lastLine(this.stderr) ? `: ${lastLine(this.stderr)}` : signal ? ` (${signal}).` : ` (exit code ${code}).`}`));
  }

  async initialize(): Promise<void> {
    await this.request("initialize", {
      clientInfo: { name: "oricode", title: "OriCode", version },
      capabilities: { experimentalApi: false, requestAttestation: false, optOutNotificationMethods: quiet },
    });
    this.write({ jsonrpc: "2.0", method: "initialized" });
  }

  request(method: string, params: object): Promise<any> {
    if (this.gone) return Promise.reject(new Error("Codex isn't running."));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  respond(id: number | string, result: unknown): void {
    this.write({ jsonrpc: "2.0", id, result });
  }

  refuse(id: number | string, message: string): void {
    this.write({ jsonrpc: "2.0", id, error: { code: -32601, message } });
  }

  close(): void {
    const child = this.child;
    this.exit("Codex was closed.");
    child.stdin.end();
    child.kill("SIGTERM");
    // One that ignores SIGTERM would hold its memory for good.
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 2000).unref();
  }

  private exit(message: string): void {
    if (this.gone) return;
    this.gone = true;
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const request of pending) request.reject(new Error(message));
    this.onExit(message);
  }

  private write(message: object): void {
    if (!this.gone) this.child.stdin.write(JSON.stringify(message) + "\n");
  }

  private receive(line: string): void {
    let message: { id?: number | string; method?: string; params?: any; result?: unknown; error?: { code: number; message: string } };
    try {
      message = JSON.parse(line);
    } catch {
      if (line.trim()) log(`Codex wrote a line that isn't JSON: ${line.slice(0, 200)}`);
      return;
    }
    if (message.method === undefined) {
      const request = this.pending.get(message.id as number);
      if (!request) return;
      this.pending.delete(message.id as number);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result ?? {});
      return;
    }
    if (message.id === undefined) this.onNotification(message.method, message.params ?? {});
    else this.onRequest(message.id, message.method, message.params ?? {});
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
