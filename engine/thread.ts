import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { basename } from "node:path";
import {
  query,
  type EffortLevel,
  type FastModeDisabledReason,
  type FastModeState,
  type PermissionMode,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
  type SlashCommand,
} from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment, cliDebugFile } from "./claude.ts";
import { adaptive } from "./models.ts";
import { event, log } from "./wire.ts";

export type Attachment = { mediaType: string; data: string };

export type SendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  model?: string;
  effort?: EffortLevel;
  permissionMode: PermissionMode;
  attachments?: Attachment[];
  /// Fast mode for the thread. SDK sessions get it only when their flag settings ask for it.
  fast?: boolean;
  /// What the thread's turns have cost so far. A resumed CLI reports the session's saved
  /// running total in its first result, so this is the baseline a turn's cost is taken from.
  costSoFar?: number;
};

type Ask = {
  threadId: string;
  kind: "permission" | "question";
  input: Record<string, unknown>;
  resolve: (result: PermissionResult) => void;
};

export type Answer = {
  requestId: string;
  allow: boolean;
  updatedInput?: Record<string, unknown>;
  answers?: Record<string, string>;
  message?: string;
};

const asks = new Map<string, Ask>();

export function answer(params: Answer): void {
  const ask = asks.get(params.requestId);
  if (!ask) throw new Error("That question is no longer waiting.");
  asks.delete(params.requestId);
  if (!params.allow) {
    ask.resolve({ behavior: "deny", message: params.message ?? "The user denied this. Stop and wait for them." });
    return;
  }
  const updatedInput =
    params.updatedInput ?? (ask.kind === "question" ? { ...ask.input, answers: params.answers ?? {} } : ask.input);
  ask.resolve({ behavior: "allow", updatedInput });
}

/// A queue the SDK reads user messages from. Keeping one open per thread is what
/// lets a running turn take `setPermissionMode` and `interrupt`.
class Inbox implements AsyncIterable<SDKUserMessage> {
  private waiting: ((result: IteratorResult<SDKUserMessage>) => void) | undefined;
  private queued: SDKUserMessage[] = [];
  private closed = false;

  push(message: SDKUserMessage): void {
    if (this.waiting) {
      this.waiting({ value: message, done: false });
      this.waiting = undefined;
    } else {
      this.queued.push(message);
    }
  }

  close(): void {
    this.closed = true;
    this.waiting?.({ value: undefined, done: true });
    this.waiting = undefined;
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: () => {
        const message = this.queued.shift();
        if (message) return Promise.resolve({ value: message, done: false });
        if (this.closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => (this.waiting = resolve));
      },
    };
  }
}

export class Thread {
  readonly id: string;
  private claude: string;
  private query: Query | undefined;
  private inbox: Inbox | undefined;
  private key = "";
  private mode: PermissionMode = "default";
  private sessionId: string | undefined;
  private running = false;
  private started = false;
  private interrupted = false;
  /// One error line per turn: the CLI can report the same failure as a message and in the result.
  private errored = false;
  /// The send in flight while the CLI resumes a session, so it can go again fresh if that session is gone.
  private resuming: SendParams | undefined;
  private streamed = new Set<string>();
  /// Subagents and other tasks the CLI is running for this thread, in the foreground or not.
  private tasks = new Map<string, { description: string; background: boolean }>();
  private costSoFar = 0;
  private lastContext = 0;
  private fast = false;
  /// The fast mode state last told to the app, so results that repeat it aren't sent again.
  private fastTold = "";

  constructor(id: string, claude: string) {
    this.id = id;
    this.claude = claude;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// The commands and skills this thread's CLI knows, when it has one running.
  async commands(): Promise<SlashCommand[] | undefined> {
    return this.query?.supportedCommands();
  }

  async send(params: SendParams): Promise<void> {
    if (this.running) throw new Error("A turn is already running in this thread.");
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    const key = JSON.stringify([params.cwd, params.model ?? null, params.effort ?? null]);
    if (!this.query || key !== this.key) {
      this.close();
      this.start(params, key);
    } else {
      if (params.permissionMode !== this.mode) {
        await this.query.setPermissionMode(params.permissionMode);
        this.mode = params.permissionMode;
      }
      if ((params.fast ?? false) !== this.fast) await this.setFast(params.fast ?? false);
    }
    log(`send thread=${this.id} model=${params.model ?? "default"} effort=${params.effort ?? "default"} mode=${params.permissionMode}`);
    this.running = true;
    this.started = false;
    this.interrupted = false;
    this.errored = false;
    this.push(params);
  }

  private push(params: SendParams): void {
    this.inbox!.push({
      type: "user",
      message: { role: "user", content: content(params) },
      parent_tool_use_id: null,
    });
  }

  async interrupt(): Promise<void> {
    if (!this.running || !this.query) return;
    this.interrupted = true;
    for (const [requestId, ask] of asks) {
      if (ask.threadId !== this.id) continue;
      asks.delete(requestId);
      event("ask.cancelled", { threadId: this.id, requestId });
      ask.resolve({ behavior: "deny", message: "The user stopped this turn.", interrupt: true });
    }
    await this.query.interrupt();
  }

  /// Returns whether the running turn took the new mode. Between turns there is
  /// nothing to apply it to, so it simply holds from the next send.
  async setMode(mode: PermissionMode): Promise<boolean> {
    if (!this.query || !this.running) {
      if (this.query) {
        await this.query.setPermissionMode(mode).catch(() => {});
      }
      this.mode = mode;
      return true;
    }
    try {
      await this.query.setPermissionMode(mode);
      this.mode = mode;
      return true;
    } catch {
      return false;
    }
  }

  /// Applied to the running CLI through its flag settings; with none running it holds for the next start.
  async setFast(fast: boolean): Promise<boolean> {
    this.fast = fast;
    if (!this.query) return true;
    try {
      await this.query.applyFlagSettings({ fastMode: fast ? true : null });
      return true;
    } catch {
      return false;
    }
  }

  close(): void {
    this.inbox?.close();
    this.query?.close();
    this.query = undefined;
    this.inbox = undefined;
  }

  private start(params: SendParams, key: string): void {
    const resume = params.sessionId ?? this.sessionId;
    this.resuming = resume ? params : undefined;
    log(`start thread=${this.id} cwd=${params.cwd} resume=${resume ?? "none"}`);
    this.key = key;
    this.mode = params.permissionMode;
    this.fast = params.fast ?? false;
    this.costSoFar = resume ? (params.costSoFar ?? 0) : 0;
    const inbox = new Inbox();
    this.inbox = inbox;
    this.query = query({
      prompt: inbox,
      options: {
        cwd: params.cwd,
        model: params.model,
        effort: params.effort,
        // Summarized, so the thinking deltas carry text the app can show when asked.
        thinking: adaptive.has(params.model ?? "default") ? { type: "adaptive", display: "summarized" } : undefined,
        permissionMode: params.permissionMode,
        // The opt-in the CLI asks of SDK sessions before it serves them fast.
        settings: this.fast ? { fastMode: true } : undefined,
        allowDangerouslySkipPermissions: true,
        resume,
        includePartialMessages: true,
        settingSources: ["user", "project", "local"],
        systemPrompt: { type: "preset", preset: "claude_code" },
        pathToClaudeCodeExecutable: this.claude,
        env: cleanEnvironment(),
        stderr: (data) => process.stderr.write(data),
        debugFile: cliDebugFile(this.id),
        canUseTool: (tool, input, { signal, toolUseID }) => this.ask(tool, input, toolUseID, signal),
      },
    });
    this.pump(this.query);
  }

  /// Whether fast mode is on for the thread, or why it can't be, when that changes.
  private tellFast(message: { fast_mode_state?: FastModeState; fast_mode_disabled_reason?: FastModeDisabledReason }): void {
    const state = message.fast_mode_state ?? "off";
    const reason = message.fast_mode_disabled_reason ?? null;
    const told = `${state} ${reason}`;
    if (told === this.fastTold) return;
    this.fastTold = told;
    event("fast", { threadId: this.id, state, reason });
  }

  /// Keeps `tasks` in step with the CLI's task messages and tells the app how many are out.
  private trackTask(message: SDKMessage & { type: "system" }): boolean {
    const before = this.tasks.size;
    switch (message.subtype) {
      case "task_started":
        if (!message.ambient) this.tasks.set(message.task_id, { description: message.description, background: message.is_backgrounded ?? false });
        break;
      case "task_notification":
        this.tasks.delete(message.task_id);
        break;
      case "task_updated":
        if (message.patch.status && !["pending", "running", "paused"].includes(message.patch.status)) this.tasks.delete(message.task_id);
        break;
      case "background_tasks_changed": {
        // The CLI's own list of what's still running in the background: a backgrounded
        // task it no longer lists is over.
        const listed = new Set(message.tasks.filter((task) => !task.ambient).map((task) => task.task_id));
        for (const [id, task] of this.tasks) if (task.background && !listed.has(id)) this.tasks.delete(id);
        for (const task of message.tasks) {
          if (!task.ambient) this.tasks.set(task.task_id, { description: task.description, background: true });
        }
        break;
      }
      default:
        return false;
    }
    if (this.tasks.size !== before || message.subtype === "task_started") {
      event("tasks", { threadId: this.id, running: this.tasks.size, tasks: [...this.tasks.values()].map((task) => task.description) });
    }
    return true;
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  /// The session this thread pointed at is gone (deleted, or from another machine). Say so
  /// once and send the same message again in a new session.
  private startFresh(params: SendParams): void {
    log(`session gone for thread=${this.id}, starting fresh`);
    this.sessionId = undefined;
    const fresh = { ...params, sessionId: undefined };
    const key = this.key;
    this.close();
    event("session.lost", { threadId: this.id });
    this.start(fresh, key);
    this.started = false;
    this.push(fresh);
  }

  private ask(tool: string, input: Record<string, unknown>, toolUseId: string, signal: AbortSignal): Promise<PermissionResult> {
    const requestId = randomUUID();
    const kind = tool === "AskUserQuestion" ? "question" : "permission";
    return new Promise((resolve) => {
      asks.set(requestId, { threadId: this.id, kind, input, resolve });
      signal.addEventListener(
        "abort",
        () => {
          if (!asks.delete(requestId)) return;
          event("ask.cancelled", { threadId: this.id, requestId });
          resolve({ behavior: "deny", message: "Cancelled." });
        },
        { once: true },
      );
      event("ask", {
        threadId: this.id,
        requestId,
        kind,
        tool,
        toolUseId,
        input,
        options: kind === "question" ? input.questions : undefined,
      });
    });
  }

  private async pump(running: Query): Promise<void> {
    try {
      for await (const message of running) this.handle(message);
    } catch (error) {
      if (running === this.query) event("error", { threadId: this.id, message: describe(error) });
    }
    if (running !== this.query) return;
    // The CLI went away under us. The next send starts a fresh one that resumes the session.
    this.query = undefined;
    this.inbox = undefined;
    if (this.running) {
      this.running = false;
      event("turn.done", { threadId: this.id, sessionId: this.sessionId, stopReason: "engine_stopped", durationMs: 0, costUSD: 0, usage: emptyUsage });
    }
  }

  private handle(message: SDKMessage): void {
    if ("session_id" in message && message.session_id) this.sessionId = message.session_id;
    // A background agent reporting back makes the CLI start a turn nobody sent.
    if (!this.running && (message.type === "stream_event" || message.type === "assistant") && !message.parent_tool_use_id) {
      this.running = true;
      this.started = false;
      this.interrupted = false;
      this.errored = false;
    }
    if (this.running && !this.started && this.sessionId) {
      this.started = true;
      event("turn.started", { threadId: this.id, sessionId: this.sessionId });
    }
    switch (message.type) {
      case "stream_event": {
        if (message.parent_tool_use_id) return;
        const raw = message.event;
        if (raw.type === "message_start") this.streamed.add(raw.message.id);
        if (raw.type !== "content_block_delta") return;
        if (raw.delta.type === "text_delta") event("text", { threadId: this.id, delta: raw.delta.text });
        if (raw.delta.type === "thinking_delta" && raw.delta.thinking) event("thinking", { threadId: this.id, delta: raw.delta.thinking });
        return;
      }
      case "assistant": {
        if (message.parent_tool_use_id) return;
        const usage = message.message.usage;
        if (usage) {
          this.lastContext = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.output_tokens ?? 0);
        }
        if (message.error) {
          // An API failure arrives as a synthetic message; its text is the raw error, so say it once, plainly.
          this.fail(errorText(message.error));
          return;
        }
        const streamed = this.streamed.has(message.message.id);
        for (const block of message.message.content) {
          if (block.type === "tool_use") {
            event("tool.use", { threadId: this.id, toolUseId: block.id, name: block.name, input: block.input });
          } else if (block.type === "text" && !streamed) {
            event("text", { threadId: this.id, delta: block.text });
          }
        }
        return;
      }
      case "user": {
        if (message.parent_tool_use_id) return;
        const blocks = message.message.content;
        if (typeof blocks === "string") return;
        const patch = patchOf(message.tool_use_result);
        for (const block of blocks) {
          if (block.type !== "tool_result") continue;
          event("tool.result", {
            threadId: this.id,
            toolUseId: block.tool_use_id,
            content: resultText(block.content),
            isError: block.is_error ?? false,
            patch,
          });
        }
        return;
      }
      case "system": {
        if (message.subtype === "init") this.tellFast(message);
        if (this.trackTask(message)) return;
        if (message.subtype === "api_retry") {
          event("retrying", { threadId: this.id, attempt: message.attempt, max: message.max_retries, error: message.error });
          return;
        }
        if (message.subtype === "compact_boundary") {
          // A compacting turn has no assistant message to take the new size from.
          this.lastContext = message.compact_metadata.post_tokens ?? 0;
          event("compacted", { threadId: this.id, before: message.compact_metadata.pre_tokens, after: this.lastContext });
        }
        return;
      }
      case "result": {
        if (this.resuming && message.subtype !== "success" && message.errors.some((error) => error.startsWith("No conversation found"))) {
          this.startFresh(this.resuming);
          return;
        }
        this.resuming = undefined;
        this.running = false;
        this.streamed.clear();
        this.tellFast(message);
        // total_cost_usd is the running total of this CLI process, so the turn's cost is the difference.
        const cost = message.total_cost_usd - this.costSoFar;
        this.costSoFar = message.total_cost_usd;
        const window = Object.values(message.modelUsage).reduce((largest, usage) => Math.max(largest, usage.contextWindow ?? 0), 0);
        // An interrupt ends the turn as error_during_execution with a diagnostic nobody needs to read.
        if (message.subtype !== "success" && message.errors.length && !this.interrupted) {
          this.fail(message.errors.join("\n"));
        }
        event("turn.done", {
          threadId: this.id,
          sessionId: message.session_id,
          stopReason: this.interrupted ? "interrupted" : message.subtype === "success" ? (message.stop_reason ?? "end_turn") : message.subtype,
          durationMs: message.duration_ms,
          costUSD: Math.max(0, cost),
          usage: {
            input: message.usage.input_tokens,
            output: message.usage.output_tokens,
            cacheRead: message.usage.cache_read_input_tokens,
            cacheWrite: message.usage.cache_creation_input_tokens,
          },
          context: { used: this.lastContext, window },
        });
        return;
      }
    }
  }
}

const emptyUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

function content(params: SendParams): SDKUserMessage["message"]["content"] {
  if (!params.attachments?.length) return params.text;
  return [
    ...params.attachments.map((attachment) => ({
      type: "image" as const,
      source: { type: "base64" as const, media_type: attachment.mediaType as "image/png", data: attachment.data },
    })),
    { type: "text" as const, text: params.text },
  ];
}

/// Edit, MultiEdit and Write report the hunks they applied; the app draws its diff cards from them.
function patchOf(output: unknown): { oldStart: number; newStart: number; lines: string[] }[] | undefined {
  const hunks = (output as { structuredPatch?: unknown } | undefined)?.structuredPatch;
  if (!Array.isArray(hunks)) return undefined;
  return hunks.map((hunk) => ({ oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines }));
}

function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part: { type?: string; text?: string }) => (part.type === "text" ? (part.text ?? "") : `[${part.type}]`))
    .join("\n");
}

function errorText(error: string): string {
  switch (error) {
    case "authentication_failed":
      return "Claude isn't logged in. Run `claude` in Terminal and log in.";
    case "rate_limit":
      return "Rate limited. Try again in a moment.";
    case "server_error":
    case "unknown":
      return "Couldn't reach Claude. Check the network, then send again.";
    case "overloaded":
      return "Claude is overloaded right now.";
    case "billing_error":
      return "There's a billing problem with this Claude account.";
    default:
      return `Claude returned an error (${error}).`;
  }
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
