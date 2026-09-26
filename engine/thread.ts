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
  type SDKRateLimitInfo,
  type SDKUserMessage,
  type SlashCommand,
} from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment, cliDebugFile } from "./claude.ts";
import { adaptive, applied, type Applied } from "./models.ts";
import { Heads } from "./heads.ts";
import { asks, type Answer, type Grant, type SendParams, type Session } from "./provider.ts";
import { event, log } from "./wire.ts";
import { workflowShape, type WorkflowShape } from "./workflow.ts";

/// What an `effort` event tells the app: the level the session sends, null for none, and
/// whether it runs as Ultracode.
type Effort = { level: string | null; ultracode: boolean };

/// The SDK's answer to an ask: a question's answers go back in its input.
function permission(params: Answer, kind: "permission" | "question", input: Record<string, unknown>): PermissionResult {
  if (!params.allow) return { behavior: "deny", message: params.message ?? "The user denied this. Stop and wait for them." };
  const updatedInput = params.updatedInput ?? (kind === "question" ? { ...input, answers: params.answers ?? {} } : input);
  return { behavior: "allow", updatedInput };
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

export class Thread implements Session {
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
  private heads: Heads;
  /// Workflows the thread started, by task, with the call that started them and their last snapshot.
  private workflows = new Map<string, { toolUseId: string | null; name: string; shape: WorkflowShape }>();
  private costSoFar = 0;
  private lastContext = 0;
  private fast = false;
  /// The fast mode state last told to the app, so results that repeat it aren't sent again.
  private fastTold = "";
  /// The effort last told to the app, so readings that repeat it aren't sent again.
  private effortTold: Effort | undefined;
  /// The effort this CLI was started with, sent beside each reading so the app can tell a
  /// reading taken on Default, or under Ultracode, from one taken under another pick.
  private asked: string | null = null;
  /// When the last turn ended, for letting an idle CLI go.
  private idleSince: number | undefined;
  /// The call the user already allowed, until the turn asks about it or ends.
  private grant: Grant | undefined;
  /// A resumed session said a command from its last CLI never finished, which the CLI answers
  /// with a result of its own before it takes up the message sent.
  private orphaned = false;
  /// The plan's limits as the CLI last reported them, and whether this turn was refused by one.
  private limit: SDKRateLimitInfo | undefined;
  private refused = false;
  /// The limits last told to the app, so a report that repeats them isn't sent again.
  private limitsTold = "";

  /// Messages sent during a turn that Claude hasn't taken up yet, by the app's id.
  private waiting = new Set<string>();
  /// Whether this CLI reports on the messages it's sent and can take waiting ones back, from its
  /// init; undefined until that arrives.
  private reports: boolean | undefined;
  /// Settled by the init, or by the CLI going before one came.
  private initialized = Promise.withResolvers<void>();
  /// Waiting messages sent before the init, which the CLI hasn't been given yet.
  private held = new Set<string>();
  /// An interrupt on its way to the CLI, which may land on the turn after the one it was for.
  private stopping = false;
  private launch: typeof query;
  /// Called once a turn has ended and the CLI sits idle.
  onIdle: (() => void) | undefined;

  /// `launch` is the SDK's query; tests hand in one that starts no CLI.
  constructor(id: string, claude: string, launch: typeof query = query) {
    this.id = id;
    this.claude = claude;
    this.launch = launch;
    this.heads = new Heads(id);
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// The commands and skills this thread's CLI knows, when it has one running.
  async commands(): Promise<SlashCommand[] | undefined> {
    return this.query?.supportedCommands();
  }

  /// Returns whether the message waits for the running turn to take it up. Sent during a turn,
  /// it goes into the open inbox, and the CLI folds it into the turn at its next step, or runs
  /// it as a turn of its own right after when the turn has no step left. The model, level, mode
  /// and speed sent with it hold from the next send, as they would between turns.
  async send(params: SendParams): Promise<boolean> {
    if ((this.running || this.waiting.size > 0) && this.query) {
      if (!params.id) throw new Error("A turn is already running in this thread.");
      if (this.reports === undefined) {
        // Until its init the CLI hasn't said whether it reports taking a message up, so the
        // message waits for it here, where a Stop or the CLI going hands it back as they would
        // one the CLI held.
        this.waiting.add(params.id);
        this.held.add(params.id);
        await this.initialized.promise;
        if (!this.held.delete(params.id)) return true;
        this.waiting.delete(params.id);
      }
      // Without the CLI saying when it takes a message up, the app would wait on it for good.
      if (!this.reports) throw new Error("This version of Claude Code can't take a message during a turn. Update it, or send this once the turn is over.");
      log(`send thread=${this.id} into the running turn`);
      this.waiting.add(params.id);
      this.push(params);
      return true;
    }
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
    this.refused = false;
    this.grant = params.grant;
    this.push(params);
    // Meant for a turn that had ended by the time it arrived, the message starts one. Said as an
    // event, it reaches the app after that turn's turn.done, which the reply could overtake.
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    return false;
  }

  private push(params: SendParams): void {
    this.inbox!.push({
      type: "user",
      message: { role: "user", content: content(params) },
      parent_tool_use_id: null,
      uuid: params.id as SDKUserMessage["uuid"],
    });
  }

  /// Stop means stop everything: the turn, and whatever was sent to it and still waits, which
  /// would otherwise start a turn of its own right after. Messages can wait with no turn running,
  /// between the end of one that couldn't take them and the start of their own.
  async interrupt(): Promise<void> {
    const running = this.query;
    if (!running || (!this.running && this.waiting.size === 0)) return;
    this.interrupted = true;
    this.stopping = true;
    for (const [requestId, ask] of asks) {
      if (ask.threadId !== this.id) continue;
      asks.delete(requestId);
      event("ask.cancelled", { threadId: this.id, requestId });
      ask.stop();
    }
    for (const id of this.held) this.cancelled(id);
    this.held.clear();
    try {
      // Each waiting message comes off the CLI's queue by its id before the interrupt, so the
      // turn that ends can't start the next with it. The interrupt itself stays plain: with
      // cancelQueued it would also drop the reports of background agents, commands and
      // workflows queued beside them. The SDK has cancelAsyncMessage but doesn't type it yet;
      // one it can't take back has already gone into the turn the interrupt stops.
      const cancel = running as unknown as { cancelAsyncMessage(uuid: string): Promise<boolean> };
      for (const id of [...this.waiting]) {
        if (await cancel.cancelAsyncMessage(id).catch(() => false)) this.cancelled(id);
      }
      await running.interrupt();
    } finally {
      this.stopping = false;
    }
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

  /// Ends the CLI of a thread idle this long, with no subagents out and nothing asked of the
  /// user. The next send starts one that resumes the session.
  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.query || this.running || this.waiting.size > 0 || this.heads.size > 0 || this.idleSince === undefined) return false;
    if (now - this.idleSince < idleMs) return false;
    if ([...asks.values()].some((ask) => ask.threadId === this.id)) return false;
    this.close();
    return true;
  }

  /// How long until the CLI has been idle `idleMs`, 0 once it has; undefined with no CLI, or
  /// while a turn runs, whose end calls onIdle.
  idleLeft(idleMs: number, now = Date.now()): number | undefined {
    if (!this.query || this.running || this.idleSince === undefined) return undefined;
    return Math.max(0, this.idleSince + idleMs - now);
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

  /// What each head is doing goes out only while the app's Heads surface shows this thread.
  watchHeads(on: boolean): void {
    this.heads.watch(on);
  }

  async stopTask(taskId: string): Promise<void> {
    if (!this.query || !this.heads.has(taskId)) throw new Error("That has already stopped.");
    await this.query.stopTask(taskId);
  }

  close(): void {
    this.dropWaiting();
    this.inbox?.close();
    this.query?.close();
    this.query = undefined;
    this.inbox = undefined;
    this.endHeads();
  }

  /// What the CLI ran goes with it: its workflows stop, and its heads end with their watchers.
  private endHeads(): void {
    for (const taskId of this.workflows.keys()) this.tellWorkflow(taskId, "stopped");
    this.workflows.clear();
    this.heads.clear();
  }

  private start(params: SendParams, key: string): void {
    const resume = params.sessionId ?? this.sessionId;
    this.resuming = resume ? params : undefined;
    log(`start thread=${this.id} cwd=${params.cwd} resume=${resume ?? "none"}`);
    this.key = key;
    this.heads.cwd = params.cwd;
    this.mode = params.permissionMode;
    this.fast = params.fast ?? false;
    this.costSoFar = resume ? (params.costSoFar ?? 0) : 0;
    // A new CLI reports its first readings again: the app may have let go of the thread's
    // transcript, and what it knew with it, since the last one.
    this.fastTold = "";
    this.effortTold = undefined;
    this.asked = params.effort ?? null;
    this.reports = undefined;
    this.initialized = Promise.withResolvers<void>();
    const inbox = new Inbox();
    this.inbox = inbox;
    const ultra = params.effort === "ultracode";
    this.query = this.launch({
      prompt: inbox,
      options: {
        cwd: params.cwd,
        model: params.model,
        // Ultracode sets its own effort, xhigh.
        effort: ultra ? undefined : (params.effort as EffortLevel | undefined),
        // Summarized, so the thinking deltas carry text the app can show when asked.
        thinking: adaptive.has(params.model ?? "default") ? { type: "adaptive", display: "summarized" } : undefined,
        permissionMode: params.permissionMode,
        // Fast mode's is the opt-in the CLI asks of SDK sessions before it serves them fast;
        // Ultracode is a session setting that only flag settings can turn on.
        settings: this.fast || ultra ? { ...(this.fast ? { fastMode: true } : {}), ...(ultra ? { ultracode: true } : {}) } : undefined,
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
    void this.tellEffort(this.query);
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

  /// The level the session will actually send and whether it runs as Ultracode, when either
  /// changes: a cap in the user's settings, or a model without the level, can make them differ
  /// from the thread's pick. Read beside the turn once the CLI is up; a CLI that can't say
  /// tells the app nothing.
  private async tellEffort(running: Query): Promise<void> {
    try {
      await running.initializationResult();
      const now = await applied(running);
      if (running !== this.query) return;
      const told = changedEffort(this.effortTold, now);
      if (!told) return;
      this.effortTold = told;
      event("effort", { threadId: this.id, ...told, asked: this.asked });
    } catch {}
  }

  /// Keeps the heads and the workflows in step with the CLI's task messages.
  private trackTask(message: SDKMessage & { type: "system" }): boolean {
    switch (message.subtype) {
      case "task_started":
        if (message.task_type === "local_workflow") {
          const name = message.workflow_name ?? message.description;
          this.workflows.set(message.task_id, { toolUseId: message.tool_use_id ?? null, name, shape: { phases: [], agents: [] } });
          this.tellWorkflow(message.task_id, "running");
        }
        break;
      case "task_progress": {
        const workflow = this.workflows.get(message.task_id);
        const progress = (message as { workflow_progress?: unknown }).workflow_progress;
        if (workflow && Array.isArray(progress)) {
          workflow.shape = workflowShape(progress);
          this.tellWorkflow(message.task_id, "running");
        }
        break;
      }
      case "task_notification":
        if (this.resuming && !this.heads.has(message.task_id)) this.orphaned = true;
        this.tellWorkflow(message.task_id, message.status, message.summary);
        this.workflows.delete(message.task_id);
        break;
      case "task_updated":
        if (message.patch.status && !["pending", "running", "paused"].includes(message.patch.status)) {
          this.tellWorkflow(message.task_id, message.patch.status === "killed" ? "stopped" : message.patch.status);
        }
        break;
    }
    return this.heads.track(message);
  }

  /// Where a workflow the thread started has got, with its last snapshot, whole each time.
  private tellWorkflow(taskId: string, state: string, summary?: string): void {
    const workflow = this.workflows.get(taskId);
    if (!workflow) return;
    event("workflow", { threadId: this.id, taskId, toolUseId: workflow.toolUseId, name: workflow.name, state, ...workflow.shape, summary: summary ?? null });
  }

  /// The CLI holding them is going, so what still waits will never run.
  private dropWaiting(): void {
    for (const id of this.waiting) this.cancelled(id);
    this.held.clear();
    this.initialized.resolve();
  }

  private cancelled(id: string): void {
    if (this.waiting.delete(id)) event("message.cancelled", { threadId: this.id, messageId: id });
  }

  /// A turn the app didn't start with a send: a background agent reporting back, or a message
  /// that waited through the end of the turn it was sent to. `stopped` is a Stop that came
  /// between the two turns and reaches the second.
  private begin(stopped = false): void {
    this.running = true;
    this.started = false;
    this.interrupted = stopped;
    this.errored = false;
    this.refused = false;
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
    if (this.grant && sameCall(this.grant, tool, input)) {
      this.grant = undefined;
      log(`thread=${this.id} ${tool} allowed before the quit`);
      return Promise.resolve({ behavior: "allow", updatedInput: input });
    }
    const requestId = randomUUID();
    const kind = tool === "AskUserQuestion" ? "question" : "permission";
    return new Promise((resolve) => {
      asks.set(requestId, {
        threadId: this.id,
        answer: (params) => resolve(permission(params, kind, input)),
        stop: () => resolve({ behavior: "deny", message: "The user stopped this turn.", interrupt: true }),
      });
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
    // The CLI went away under us, and what it ran went with it. The next send starts a fresh one
    // that resumes the session.
    this.query = undefined;
    this.inbox = undefined;
    this.endHeads();
    this.dropWaiting();
    if (this.running) {
      this.running = false;
      event("turn.done", { threadId: this.id, sessionId: this.sessionId, stopReason: "engine_stopped", durationMs: 0, costUSD: 0, usage: emptyUsage, waiting: 0 });
    }
  }

  private handle(message: SDKMessage): void {
    if ("session_id" in message && message.session_id) this.sessionId = message.session_id;
    if ((message as { type: string }).type === "command_lifecycle") {
      const told = lifecycleEvent(message as unknown as Lifecycle, this.waiting, this.running);
      if (!told) return;
      this.waiting.delete(told.id);
      event(told.name, { threadId: this.id, ...told.fields });
      // Taken up after the turn it was sent to, the message is a turn of its own, which Stop
      // can reach from here on. A Stop pressed since the last turn ended, after the CLI had
      // already started this one, stops this one.
      if (told.name !== "message.taken" || !told.fields.newTurn) return;
      this.begin(this.interrupted);
    }
    // A background agent reporting back makes the CLI start a turn nobody sent.
    if (!this.running && (message.type === "stream_event" || message.type === "assistant") && !message.parent_tool_use_id) this.begin();
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
        if (message.parent_tool_use_id) {
          this.heads.frame(message.parent_tool_use_id, message.message.content);
          return;
        }
        const usage = message.message.usage;
        if (usage) {
          this.lastContext = (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.output_tokens ?? 0);
        }
        if (message.error === "rate_limit") {
          // Said once the turn ends, when the limit that refused it has been reported too.
          this.refused = true;
          return;
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
        const blocks = message.message.content;
        if (typeof blocks === "string") return;
        for (const block of blocks) {
          if (block.type === "tool_result") this.heads.result(block.tool_use_id, resultText(block.content));
        }
        if (message.parent_tool_use_id) return;
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
      case "rate_limit_event": {
        this.limit = message.rate_limit_info;
        const limits = limitsOf(message.rate_limit_info);
        const told = limitsKey(limits);
        if (told === this.limitsTold) return;
        this.limitsTold = told;
        event("limits", { threadId: this.id, ...limits });
        return;
      }
      case "system": {
        if (message.subtype === "init") {
          this.tellFast(message);
          const capabilities = message.capabilities ?? [];
          this.reports = capabilities.includes("msg_lifecycle_v1") && capabilities.includes("interrupt_cancel_queued_v1");
          this.initialized.resolve();
        }
        if (this.trackTask(message)) return;
        // What Claude Code shows in its own transcript, such as the wrap-up it starts near a limit.
        if (message.subtype === "informational") {
          if (message.level === "notice" || message.level === "warning") event("note", { threadId: this.id, text: message.content });
          return;
        }
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
        // Nothing asked the model for that one; the turn sent is still to come.
        if (this.orphaned && message.num_turns === 0) {
          this.orphaned = false;
          return;
        }
        this.orphaned = false;
        if (this.resuming && message.subtype !== "success" && message.errors.some((error) => error.startsWith("No conversation found"))) {
          this.startFresh(this.resuming);
          return;
        }
        this.resuming = undefined;
        this.running = false;
        this.grant = undefined;
        if (this.refused) {
          this.refused = false;
          const limited = limitReached(this.limit);
          if (limited) event("limited", { threadId: this.id, ...limited });
          else if (this.limit?.status === "rejected") this.fail("Stopped at one of Claude's usage limits.");
          else this.fail(errorText("rate_limit"));
        }
        this.idleSince = Date.now();
        this.streamed.clear();
        this.tellFast(message);
        if (this.query) void this.tellEffort(this.query);
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
          // Messages sent during the turn that it ended without taking up: each runs as a turn
          // of its own, starting now.
          waiting: this.waiting.size,
        });
        // Said for this turn. A Stop from here on is for the turn a waiting message starts, and
        // so is one still on its way, which the CLI may get once it has started that turn.
        this.interrupted = this.stopping;
        this.onIdle?.();
        return;
      }
    }
  }
}

const emptyUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };

/// What the CLI says about a message that has a uuid, in frames the SDK doesn't type yet.
/// Besides these states its schema lists discarded and refused, and it may add more.
export type Lifecycle = { type: "command_lifecycle"; command_uuid: string; state: "queued" | "started" | "completed" | "cancelled" | (string & {}) };

export type Told =
  | { name: "message.taken"; id: string; fields: { messageId: string; newTurn: boolean } }
  | { name: "message.cancelled"; id: string; fields: { messageId: string } };

/// The app hears about a waiting message once more: when Claude takes it up, into the running
/// turn or as a turn of its own when none is running, or when it won't run. A message sent
/// between turns has an id too, but never waits, so frames about it are nobody's business.
/// Any end other than started (cancelled, discarded, refused, or one the CLI sends with no
/// started before it) means the message won't be taken up, and it goes back to the app.
export function lifecycleEvent(frame: Lifecycle, waiting: ReadonlySet<string>, running: boolean): Told | undefined {
  const id = frame.command_uuid;
  if (!waiting.has(id) || frame.state === "queued") return undefined;
  if (frame.state === "started") return { name: "message.taken", id, fields: { messageId: id, newTurn: !running } };
  return { name: "message.cancelled", id, fields: { messageId: id } };
}

/// The effort a reading of the session's settings shows, or undefined when the app was last
/// told the same.
export function changedEffort(told: Effort | undefined, now: Applied): Effort | undefined {
  const level = now.effort ?? null;
  const ultracode = now.ultracode === true;
  if (told && told.level === level && told.ultracode === ultracode) return undefined;
  return { level, ultracode };
}

/// When a turn refused by the plan's limits can go on: the limit's reset, in milliseconds, and
/// which limit it was. Nothing when the CLI hasn't said a limit is reached, or when.
export function limitReached(info: SDKRateLimitInfo | undefined): { resetsAt: number; window: string | null } | undefined {
  if (info?.status !== "rejected" || !info.resetsAt) return undefined;
  return { resetsAt: info.resetsAt * 1000, window: info.rateLimitType ?? null };
}

type Limits = {
  status: SDKRateLimitInfo["status"];
  rateLimitType: string | null;
  utilization: number | null;
  resetsAt: number | null;
  surpassedThreshold: number | null;
  windows: { id: string; used: number; resetsAt: number }[];
};

/// The plan's limits as the app hears them, fractions used and resets in milliseconds. The CLI
/// names one limit, the one nearest its ceiling; `windows` is each window's reading, which the
/// CLI sends without its types listing it, so it may be missing.
function limitsOf(info: SDKRateLimitInfo): Limits {
  const unified = (info as { unifiedWindows?: Record<string, { utilization?: number; resetsAt?: number } | undefined> }).unifiedWindows ?? {};
  const windows = Object.entries(unified).flatMap(([id, window]) =>
    typeof window?.utilization === "number" && typeof window.resetsAt === "number" ? [{ id, used: window.utilization, resetsAt: window.resetsAt * 1000 }] : [],
  );
  return {
    status: info.status,
    rateLimitType: info.rateLimitType ?? null,
    utilization: info.utilization ?? null,
    resetsAt: info.resetsAt ? info.resetsAt * 1000 : null,
    surpassedThreshold: info.surpassedThreshold ?? null,
    windows,
  };
}

/// What the app would see of a report: a reading that moved less than a percent looks the same.
function limitsKey(limits: Limits): string {
  const percent = (fraction: number | null) => (fraction === null ? null : Math.round(fraction * 100));
  return JSON.stringify({
    ...limits,
    utilization: percent(limits.utilization),
    windows: limits.windows.map((window) => ({ ...window, used: percent(window.used) })),
  });
}

/// Whether a call is the one the user allowed. Claude words a command's description afresh when
/// it makes the call again, so that's left out; everything else must match.
export function sameCall(grant: Grant, tool: string, input: Record<string, unknown>): boolean {
  if (grant.tool !== tool) return false;
  const essence = (call: Record<string, unknown>) => JSON.stringify(sorted({ ...call, description: undefined }));
  return essence(grant.input) === essence(input);
}

/// The value with every object's keys in order, so two calls compare by what they say.
function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (!value || typeof value !== "object") return value;
  const object = value as Record<string, unknown>;
  return Object.fromEntries(Object.keys(object).sort().map((key) => [key, sorted(object[key])]));
}

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
      return "Claude is limiting requests for a moment. Try again shortly.";
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
