import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import {
  query,
  type EffortLevel,
  type PermissionMode,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment, cliDebugFile } from "./claude.ts";
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
  private streamed = new Set<string>();
  private costSoFar = 0;
  private lastContext = 0;

  constructor(id: string, claude: string) {
    this.id = id;
    this.claude = claude;
  }

  get isRunning(): boolean {
    return this.running;
  }

  async send(params: SendParams): Promise<void> {
    if (this.running) throw new Error("A turn is already running in this thread.");
    if (!existsSync(params.cwd)) throw new Error(`The folder ${params.cwd} is gone.`);
    const key = JSON.stringify([params.cwd, params.model ?? null, params.effort ?? null]);
    if (!this.query || key !== this.key) {
      this.close();
      this.start(params, key);
    } else if (params.permissionMode !== this.mode) {
      await this.query.setPermissionMode(params.permissionMode);
      this.mode = params.permissionMode;
    }
    log(`send thread=${this.id} model=${params.model ?? "default"} effort=${params.effort ?? "default"} mode=${params.permissionMode}`);
    this.running = true;
    this.started = false;
    this.interrupted = false;
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

  close(): void {
    this.inbox?.close();
    this.query?.close();
    this.query = undefined;
    this.inbox = undefined;
  }

  private start(params: SendParams, key: string): void {
    const resume = params.sessionId ?? this.sessionId;
    log(`start thread=${this.id} cwd=${params.cwd} resume=${resume ?? "none"}`);
    this.key = key;
    this.mode = params.permissionMode;
    this.costSoFar = 0;
    const inbox = new Inbox();
    this.inbox = inbox;
    this.query = query({
      prompt: inbox,
      options: {
        cwd: params.cwd,
        model: params.model,
        effort: params.effort,
        permissionMode: params.permissionMode,
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
        const streamed = this.streamed.has(message.message.id);
        for (const block of message.message.content) {
          if (block.type === "tool_use") {
            event("tool.use", { threadId: this.id, toolUseId: block.id, name: block.name, input: block.input });
          } else if (block.type === "text" && !streamed) {
            // Synthetic messages (API errors, a missing login) arrive whole, never as deltas.
            event("text", { threadId: this.id, delta: block.text });
          }
        }
        if (message.error) event("error", { threadId: this.id, message: errorText(message.error) });
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
        if (message.subtype === "compact_boundary") event("compacted", { threadId: this.id });
        return;
      }
      case "result": {
        this.running = false;
        this.streamed.clear();
        // total_cost_usd is the running total of this CLI process, so the turn's cost is the difference.
        const cost = message.total_cost_usd - this.costSoFar;
        this.costSoFar = message.total_cost_usd;
        const window = Object.values(message.modelUsage).reduce((largest, usage) => Math.max(largest, usage.contextWindow ?? 0), 0);
        // An interrupt ends the turn as error_during_execution with a diagnostic nobody needs to read.
        if (message.subtype !== "success" && message.errors.length && !this.interrupted) {
          event("error", { threadId: this.id, message: message.errors.join("\n") });
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
