import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import {
  getSessionInfo,
  query,
  type EffortLevel,
  type FastModeDisabledReason,
  type FastModeState,
  type HookJSONOutput,
  type PermissionMode,
  type PermissionResult,
  type Query,
  type SDKMessage,
  type SDKRateLimitInfo,
  type SDKUserMessage,
  type SlashCommand,
} from "@anthropic-ai/claude-agent-sdk";
import { within } from "./child.ts";
import { cleanEnvironment, cliDebugFile } from "./claude.ts";
import { adaptive, applied, type Applied } from "./models.ts";
import { subagentTranscript } from "./follow.ts";
import { Heads } from "./heads.ts";
import { asks, told, toolsServer, toolsTimeout, type Answer, type Grant, type SendParams, type Session } from "./provider.ts";
import { event, log } from "./wire.ts";
import { finalShape, stampEnds, workflowProgress, workflowShape, type WorkflowShape } from "./workflow.ts";

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

/// A thread's Claude Code pointed at a model API's endpoint with its key, Anthropic's or another maker's.
export type Elsewhere = {
  /// The maker, as the thread's error lines name it.
  agent: string;
  /// The CLI's environment for the thread's model, read as each CLI starts since it holds the key
  /// from the Keychain.
  environment: (model?: string) => Promise<Record<string, string | undefined>>;
};

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
  /// The API's refusal of this turn's request, said once the result shows whether it ended the session.
  private apiError: string | undefined;
  /// Whether the session had no turn before the one running, so nothing older in it can be what
  /// broke it. Said as `held` on a spent turn; what the app sends again it judges by the thread.
  private fresh = true;
  /// Whether the thread has a title of its own, the app's or one told from the session already.
  private titled = false;
  /// The send in flight while the CLI resumes a session, so it can go again fresh if that session is gone.
  private resuming: SendParams | undefined;
  private streamed = new Set<string>();
  /// Subagents and other tasks the CLI is running for this thread, in the foreground or not.
  private heads: Heads;
  /// Workflows the thread started, by task, with the call that started them, their last snapshot
  /// and the folder their agents' transcripts are written to, which the call's result names. One
  /// the CLI has said is over stays until its notification brings the run's last snapshot.
  /// `began` and `ends`, in seconds, are when it started and when each of its agents was seen over.
  private workflows = new Map<
    string,
    { toolUseId: string | null; name: string; shape: WorkflowShape; transcriptDir: string | null; ended: boolean; began: number; ends: number[] }
  >();
  /// The Task subagents the thread's own loop started, by task, each a thread under this one in the
  /// app, with where the CLI writes its transcript. One the CLI has said is over stays until its
  /// notification brings what it returned.
  private subagents = new Map<string, { label: string; transcript: string | null; ended: boolean }>();
  /// The commands out in the background, by their task and by the call that started each,
  /// until the CLI says how each ended. Kept here and not read off the heads, which let a
  /// background task go as soon as the CLI stops listing it, before its notification.
  private commandCalls = new Map<string, string>();
  /// What of the thread's ended last while no turn ran, and the turn nobody sent that it woke,
  /// which turn.started names as `woke`.
  private ended: string | undefined;
  private woke: string | undefined;
  private backgroundCalls = new Set<string>();
  /// A subagent's calls the app was told of and whose results it's owed, each with its tool.
  private subcalls = new Map<string, string>();
  private costSoFar = 0;
  /// Whether the thread is at its budget, from the latest send under one.
  private over: (() => Promise<boolean>) | undefined;
  private lastContext = 0;
  private fast = false;
  /// The fast mode state last told to the app, so results that repeat it aren't sent again.
  private fastTold = "";
  /// The effort last told to the app, so readings that repeat it aren't sent again.
  private effortTold: Effort | undefined;
  /// The effort this CLI was started with, sent beside each reading so the app can tell a
  /// reading taken on Default, or under Ultracode, from one taken under another pick.
  private asked: string | null = null;
  /// Whether this CLI was started as Ultracode, sent beside each reading too.
  private askedUltracode = false;
  /// Whether this CLI's init listed the Workflow tool, as last told to the app.
  private workflowsTold: boolean | undefined;
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
  /// The model API the CLI is pointed at, or none for Claude Code as the user signed it in.
  private elsewhere: Elsewhere | undefined;
  /// Settled once that endpoint's environment is read, so a send that arrives meanwhile joins the
  /// CLI it starts.
  private starting: Promise<void> | undefined;
  /// The running CLI's environment, for a fresh session started in its place; gone with the CLI.
  private env: Record<string, string | undefined> = {};
  /// Called once a turn has ended and the CLI sits idle.
  onIdle: (() => void) | undefined;

  /// `launch` is the SDK's query; tests hand in one that starts no CLI.
  constructor(id: string, claude: string, launch: typeof query = query, elsewhere?: Elsewhere) {
    this.id = id;
    this.claude = claude;
    this.launch = launch;
    this.elsewhere = elsewhere;
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
    if (params.titled) this.titled = true;
    if (this.starting) await this.starting;
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
    // Ultracode is a launch setting: switched on in a running CLI, Claude Code saves its launch
    // effort unpins into ~/.claude.json for good. Workflows below xhigh need nothing of the CLI.
    const key = JSON.stringify([params.cwd, params.model ?? null, params.effort ?? null, ultracode(params), params.tools ?? null, params.instructions ?? null, params.spendCap?.limit ?? null]);
    this.over = params.spendCap?.over;
    if (!this.query || key !== this.key) {
      let env = cleanEnvironment();
      if (this.elsewhere) {
        const reading = this.elsewhere.environment(params.model);
        this.starting = reading.then(
          () => undefined,
          () => undefined,
        );
        try {
          env = await reading;
        } finally {
          this.starting = undefined;
        }
      }
      this.close();
      this.start(params, key, env);
    } else {
      if (params.permissionMode !== this.mode) {
        await this.query.setPermissionMode(params.permissionMode);
        this.mode = params.permissionMode;
      }
      if ((params.fast ?? false) !== this.fast) await this.setFast(params.fast ?? false);
    }
    log(`send thread=${this.id} model=${params.model ?? "default"} effort=${params.effort ?? "default"} mode=${params.permissionMode}`);
    this.running = true;
    this.ended = undefined;
    this.started = false;
    this.interrupted = false;
    this.errored = false;
    this.apiError = undefined;
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

  /// Stop means stop everything: the turn, what it left running in the background, and whatever
  /// was sent to it and still waits, which would otherwise start a turn of its own right after.
  /// Messages can wait with no turn running, between the end of one that couldn't take them and
  /// the start of their own.
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
      // What the turn sent to the background goes with it: the interrupt leaves it running, and
      // its ending would wake the thread for a turn nobody asked for.
      for (const taskId of this.heads.background()) await running.stopTask(taskId).catch(() => {});
      await running.interrupt();
    } finally {
      this.stopping = false;
    }
  }

  /// The head's own move, from change_my_model: the running CLI takes the model and the level for
  /// its next request, and the key takes them too, so the send after, which carries them from the
  /// app, doesn't start the CLI again. Never under Ultracode, which a level passed beside turns off.
  async retune(model: string | undefined, effort: string | undefined): Promise<boolean> {
    const running = this.query;
    if (!running || this.askedUltracode) return false;
    if (model !== undefined) await running.setModel(model);
    if (effort !== undefined) await running.applyFlagSettings({ effortLevel: effort as EffortLevel });
    const key = JSON.parse(this.key) as unknown[];
    if (model !== undefined) key[1] = model;
    if (effort !== undefined) {
      key[2] = effort;
      this.asked = effort;
    }
    this.key = JSON.stringify(key);
    log(`retune thread=${this.id} model=${model ?? "same"} effort=${effort ?? "same"}`);
    void this.tellEffort(running);
    return true;
  }

  /// The running turn's spend, from the CLI's own running total less what it stood at when the
  /// turn began: what a budget needs before the turn's result says it.
  async spentThisTurn(): Promise<number | undefined> {
    const running = this.query;
    if (!running || !this.running) return undefined;
    try {
      const usage = await within(running.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }), 3_000, "Claude Code's spend");
      return Math.max(0, usage.session.total_cost_usd - this.costSoFar);
    } catch {
      return undefined;
    }
  }

  /// What the hook before a tool answers: carry on, or not while the thread is at its budget.
  private async spendGate(): Promise<HookJSONOutput> {
    if (!(await this.over?.())) return { continue: true };
    return { continue: false, stopReason: "This thread has spent its budget.", hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: "This thread has spent its budget." } };
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
  /// user. The next send starts one that resumes the session. A workflow or a background command
  /// is out until the CLI says how it ended, not only while the heads list it: they let one go as
  /// soon as the CLI's background list leaves it out, and closing the CLI would end it.
  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.query || this.running || this.waiting.size > 0 || this.heads.size > 0 || this.idleSince === undefined) return false;
    if ([...this.workflows.values()].some((workflow) => !workflow.ended) || this.backgroundCalls.size > 0) return false;
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
    this.env = {};
    this.endHeads();
  }

  /// What the CLI ran goes with it: its workflows and subagents stop, and its heads end with their
  /// watchers.
  private endHeads(): void {
    for (const [taskId, workflow] of this.workflows) if (!workflow.ended) this.tellWorkflow(taskId, "stopped");
    this.workflows.clear();
    for (const [taskId, subagent] of this.subagents) if (!subagent.ended) this.tellSubagent(taskId, "stopped");
    this.subagents.clear();
    this.heads.clear();
    this.commandCalls.clear();
    this.backgroundCalls.clear();
    this.subcalls.clear();
  }

  private start(params: SendParams, key: string, env: Record<string, string | undefined>): void {
    const resume = params.sessionId ?? this.sessionId;
    this.resuming = resume ? params : undefined;
    this.fresh = !resume;
    log(`start thread=${this.id} cwd=${params.cwd} resume=${resume ?? "none"}`);
    this.key = key;
    this.env = env;
    this.heads.cwd = params.cwd;
    this.mode = params.permissionMode;
    this.fast = params.fast ?? false;
    this.costSoFar = resume ? (params.costSoFar ?? 0) : 0;
    // A new CLI reports its first readings again: the app may have let go of the thread's
    // transcript, and what it knew with it, since the last one.
    this.fastTold = "";
    this.effortTold = undefined;
    this.asked = params.effort ?? null;
    const ultra = ultracode(params);
    this.askedUltracode = ultra;
    this.workflowsTold = undefined;
    this.reports = undefined;
    this.initialized = Promise.withResolvers<void>();
    const inbox = new Inbox();
    this.inbox = inbox;
    this.query = this.launch({
      prompt: inbox,
      options: {
        cwd: params.cwd,
        model: params.model,
        // Ultracode sets its own effort, xhigh, and an effort passed beside it turns it off.
        effort: ultra ? undefined : params.effort,
        // Summarized, so the thinking deltas carry text the app can show when asked.
        thinking: adaptive.has(params.model ?? "default") ? { type: "adaptive", display: "summarized" } : undefined,
        permissionMode: params.permissionMode,
        // Claude Code stops the turn at the request that takes this CLI past it.
        maxBudgetUsd: params.spendCap ? Math.max(0, params.spendCap.left) : undefined,
        // Fast mode's is the opt-in the CLI asks of SDK sessions before it serves them fast;
        // Ultracode is a session setting that only flag settings can turn on.
        settings: this.fast || ultra ? { ...(this.fast ? { fastMode: true } : {}), ...(ultra ? { ultracode: true } : {}) } : undefined,
        allowDangerouslySkipPermissions: true,
        resume,
        includePartialMessages: true,
        settingSources: ["user", "project", "local"],
        // That the window draws, and a head's rays, in its system prompt as well as its tools' MCP
        // instructions: the CLI connects MCP servers without holding up the first request, which
        // could go without them.
        systemPrompt: { type: "preset", preset: "claude_code", append: told(params.instructions) },
        pathToClaudeCodeExecutable: this.claude,
        env,
        stderr: (data) => process.stderr.write(data),
        debugFile: cliDebugFile(this.id),
        canUseTool: (tool, input, { signal, toolUseID, agentID }) => this.ask(tool, input, toolUseID, signal, agentID),
        // Under a budget each tool waits on the thread's count, so the request after its result
        // isn't sent once the thread is at the line, its own or its workers' spend taking it there.
        hooks: params.spendCap ? { PreToolUse: [{ hooks: [() => this.spendGate()] }] } : undefined,
        // Loaded with the prompt rather than behind tool search, so a head knows it can start workers.
        mcpServers: params.tools ? { [toolsServer]: { type: "http", url: params.tools, alwaysLoad: true, timeout: toolsTimeout } } : undefined,
      },
    });
    this.pump(this.query);
    void this.tellEffort(this.query);
  }

  /// The few words Claude Code titles a session with, which it writes beside the transcript
  /// once the first turn has been read: the thread takes them in place of its first message.
  /// Looked for at a turn's end and once more a little later, since the CLI may write them after
  /// the result, and never again once found.
  private async tellTitle(sessionId: string, cwd: string, again = true): Promise<void> {
    const info = await getSessionInfo(sessionId, { dir: cwd }).catch(() => undefined);
    const title = info?.customTitle?.trim() || (info && info.summary !== info.firstPrompt ? info.summary.trim() : "");
    if (this.titled) return;
    if (!title) {
      if (again) setTimeout(() => void this.tellTitle(sessionId, cwd, false), 5_000).unref();
      return;
    }
    this.titled = true;
    event("title", { threadId: this.id, title });
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
      event("effort", { threadId: this.id, ...told, asked: this.asked, askedUltracode: this.askedUltracode });
    } catch {}
  }

  /// Whether a call's result is a command's going to the background rather than its ending:
  /// the CLI said so of its task, or the result is the CLI's line for it, which can come first.
  private wentToBackground(toolUseId: string, result: string): boolean {
    if (result.startsWith("Command running in background with ID:")) this.backgroundCalls.add(toolUseId);
    return this.backgroundCalls.has(toolUseId);
  }

  /// A background command's own ending, which its call's result couldn't say. A command that
  /// stayed in the foreground said it on its result, and is only forgotten here, at its
  /// notification: one that wakes the thread is named by it in the turn it wakes.
  private commandEnded(taskId: string, toolUseId: string | undefined, status: string, notified: boolean): void {
    const call = this.commandCalls.get(taskId) ?? toolUseId;
    if (notified) this.commandCalls.delete(taskId);
    if (call && this.backgroundCalls.delete(call)) event("tool.ended", { threadId: this.id, toolUseId: call, status });
  }

  /// Keeps the heads and the workflows in step with the CLI's task messages.
  private trackTask(message: SDKMessage & { type: "system" }): boolean {
    switch (message.subtype) {
      case "task_started":
        if (message.task_type === "local_workflow") {
          const name = message.workflow_name ?? message.description;
          this.workflows.set(message.task_id, {
            toolUseId: message.tool_use_id ?? null,
            name,
            shape: { phases: [], agents: [] },
            transcriptDir: null,
            ended: false,
            began: Date.now() / 1000,
            ends: [],
          });
          this.tellWorkflow(message.task_id, "running");
        }
        // A subagent's own subagents stay calls in its transcript.
        if (message.task_type === "local_agent" && (message.spawn_depth ?? 1) === 1 && !message.ambient) this.subagentStarted(message.task_id, message.description, message.session_id);
        if (message.task_type === "local_bash" && message.tool_use_id) {
          this.commandCalls.set(message.task_id, message.tool_use_id);
          if (message.is_backgrounded) this.backgroundCalls.add(message.tool_use_id);
        }
        break;
      case "task_progress": {
        const workflow = this.workflows.get(message.task_id);
        const progress = (message as { workflow_progress?: unknown }).workflow_progress;
        if (workflow && Array.isArray(progress)) {
          workflow.shape = workflowShape(progress);
          stampEnds(workflow.shape, workflow.ends, Date.now() / 1000);
          this.tellWorkflow(message.task_id, "running");
        }
        break;
      }
      case "task_notification":
        if (!this.running) this.ended = this.endedWhat(message.task_id, message.status, message.summary) ?? this.ended;
        if (this.resuming && !this.heads.has(message.task_id)) this.orphaned = true;
        this.commandEnded(message.task_id, message.tool_use_id, message.status, true);
        if (this.workflows.has(message.task_id)) void this.endWorkflow(message.task_id, message.status, message.summary, message.output_file || null);
        if (this.subagents.has(message.task_id)) {
          this.tellSubagent(message.task_id, subagentState(message.status), message.summary);
          this.subagents.delete(message.task_id);
        }
        break;
      case "task_updated":
        if (message.patch.is_backgrounded) {
          const call = this.commandCalls.get(message.task_id);
          if (call) this.backgroundCalls.add(call);
        }
        if (message.patch.status && !["pending", "running", "paused"].includes(message.patch.status)) {
          const status = message.patch.status === "killed" ? "stopped" : message.patch.status;
          // Its notification follows with the run's last snapshot, and the workflow goes then.
          this.tellWorkflow(message.task_id, status);
          const workflow = this.workflows.get(message.task_id);
          if (workflow) workflow.ended = true;
          const subagent = this.subagents.get(message.task_id);
          if (subagent) {
            subagent.ended = true;
            this.tellSubagent(message.task_id, subagentState(status));
          }
          this.commandEnded(message.task_id, undefined, status, false);
        }
        break;
    }
    return this.heads.track(message);
  }

  /// Something the thread left running that has ended, as a name and a verb: "review done",
  /// "Sleep 90 failed · 1".
  private endedWhat(taskId: string, status: string, summary: string): string | undefined {
    const how = status === "completed" ? "done" : status === "failed" ? "failed" : "stopped";
    const workflow = this.workflows.get(taskId);
    if (workflow) return `${workflow.name} ${how}`;
    const subagent = this.subagents.get(taskId);
    if (subagent) return `${subagent.label} ${how}`;
    if (this.commandCalls.has(taskId)) return commandEnded(summary, how);
    return undefined;
  }

  /// A subagent the thread's loop started, or one it picked up again, which the app makes a thread
  /// under this one. Its transcript is wherever the CLI keeps this session.
  private subagentStarted(taskId: string, label: string, sessionId: string | undefined): void {
    const session = sessionId ?? this.sessionId;
    const config = this.env.CLAUDE_CONFIG_DIR ?? process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude");
    const transcript = this.subagents.get(taskId)?.transcript ?? (session ? subagentTranscript(join(config, "projects"), this.heads.cwd, session, taskId) : null);
    this.subagents.set(taskId, { label, transcript, ended: false });
    this.tellSubagent(taskId, "running");
  }

  /// A subagent's state for its thread, and once it's over what it returned.
  private tellSubagent(taskId: string, state: string, result?: string): void {
    const subagent = this.subagents.get(taskId);
    if (!subagent) return;
    event("agent.thread", { threadId: this.id, agentId: taskId, kind: "subagent", label: subagent.label, state, transcript: subagent.transcript, ...(result !== undefined ? { result } : {}) });
  }

  /// Where a workflow the thread started has got, with its last snapshot, whole each time.
  private tellWorkflow(taskId: string, state: string, summary?: string): void {
    const workflow = this.workflows.get(taskId);
    if (!workflow) return;
    const progress = workflowProgress(workflow.shape, workflow.began, workflow.ends, Date.now() / 1000);
    event("workflow", { threadId: this.id, taskId, toolUseId: workflow.toolUseId, name: workflow.name, state, ...workflow.shape, progress, summary: summary ?? null, transcriptDir: workflow.transcriptDir });
  }

  /// A workflow's end, with what every agent returned: the snapshots are thinned out while it
  /// runs, and none comes as it ends, so the run's last one is read from where the CLI wrote it.
  private async endWorkflow(taskId: string, status: string, summary: string, outputFile: string | null): Promise<void> {
    const workflow = this.workflows.get(taskId);
    if (!workflow) return;
    const shape = await finalShape(outputFile, workflow.transcriptDir);
    if (this.workflows.get(taskId) !== workflow) return;
    if (shape) {
      workflow.shape = shape;
      stampEnds(shape, workflow.ends, Date.now() / 1000);
    }
    this.tellWorkflow(taskId, status, summary);
    this.workflows.delete(taskId);
  }

  /// The Workflow call's result names the folder its agents' transcripts go to.
  private workflowLaunched(output: unknown): void {
    const launched = output as { taskId?: unknown; transcriptDir?: unknown } | undefined;
    if (typeof launched?.taskId !== "string" || typeof launched.transcriptDir !== "string") return;
    const workflow = this.workflows.get(launched.taskId);
    if (!workflow || workflow.transcriptDir) return;
    workflow.transcriptDir = launched.transcriptDir;
    this.tellWorkflow(launched.taskId, "running");
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
    this.ended = undefined;
    this.started = false;
    this.interrupted = stopped;
    this.errored = false;
    this.apiError = undefined;
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
    const env = this.env;
    this.close();
    event("session.lost", { threadId: this.id });
    this.start(fresh, key, env);
    this.started = false;
    this.push(fresh);
  }

  /// `agentId` is the subagent or workflow agent that asks, which the app counts the ask under.
  private ask(tool: string, input: Record<string, unknown>, toolUseId: string, signal: AbortSignal, agentId?: string): Promise<PermissionResult> {
    // The thread allowed workers, and what each worker does is asked about as it does it.
    if (tool.startsWith(`mcp__${toolsServer}__`)) return Promise.resolve({ behavior: "allow", updatedInput: input });
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
        ...(agentId ? { agentId } : {}),
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
    if (this.apiError) this.fail(this.apiError);
    this.apiError = undefined;
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
    if (!this.running && (message.type === "stream_event" || message.type === "assistant") && !message.parent_tool_use_id) {
      const ended = this.ended;
      this.begin();
      this.woke = ended;
    }
    if (this.running && !this.started && this.sessionId) {
      this.started = true;
      event("turn.started", { threadId: this.id, sessionId: this.sessionId, ...(this.woke ? { woke: this.woke } : {}) });
      this.woke = undefined;
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
          // A subagent's commands, edits and subagents go to the app under the call that started
          // it, where the review reads what it ran and what it edited. Its words stay its own,
          // and so does what it read or searched, which nothing in the app would look at.
          for (const block of message.message.content) {
            if (block.type !== "tool_use" || !subagentKept.has(block.name)) continue;
            this.subcalls.set(block.id, block.name);
            event("tool.use", { threadId: this.id, toolUseId: block.id, name: block.name, input: block.input, parent: message.parent_tool_use_id, ...(subagentTools.has(block.name) ? { subcalls: true } : {}) });
          }
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
          // A request the API refused waits for the result, which says whether it ended the session.
          if (message.error === "invalid_request") this.apiError = errorText(message.error, this.elsewhere?.agent);
          else this.fail(errorText(message.error, this.elsewhere?.agent));
          return;
        }
        const streamed = this.streamed.has(message.message.id);
        for (const block of message.message.content) {
          if (block.type === "tool_use") {
            event("tool.use", { threadId: this.id, toolUseId: block.id, name: block.name, input: block.input, ...(subagentTools.has(block.name) ? { subcalls: true } : {}) });
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
        const patch = patchOf(message.tool_use_result);
        this.workflowLaunched(message.tool_use_result);
        for (const block of blocks) {
          if (block.type !== "tool_result") continue;
          const tool = this.subcalls.get(block.tool_use_id);
          if (message.parent_tool_use_id && !tool) continue;
          this.subcalls.delete(block.tool_use_id);
          // Of a subagent's results only a command's words are read; an edit's is its patch.
          const content = !message.parent_tool_use_id || tool === "Bash" ? resultText(block.content) : "";
          event("tool.result", {
            threadId: this.id,
            toolUseId: block.tool_use_id,
            content,
            isError: block.is_error ?? false,
            patch,
            // Sent to the background, by its call or by the CLI when it ran long: this result is
            // only where its output goes, and how it ended comes later as `tool.ended`.
            ...(this.wentToBackground(block.tool_use_id, content) ? { background: true } : {}),
            ...(message.parent_tool_use_id ? { parent: message.parent_tool_use_id } : {}),
          });
        }
        return;
      }
      case "rate_limit_event": {
        // Claude's plan's limits, which a model API's key has nothing to do with.
        if (this.elsewhere) return;
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
          // Workflows on need the Workflow tool, which workflows off in /config take away. An
          // init that lists no tools at all says nothing about it.
          const workflows = message.tools?.includes("Workflow");
          if (workflows !== undefined && workflows !== this.workflowsTold) {
            this.workflowsTold = workflows;
            event("workflowTool", { threadId: this.id, available: workflows });
          }
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
          else this.fail(errorText("rate_limit", this.elsewhere?.agent));
        }
        this.idleSince = Date.now();
        this.streamed.clear();
        this.tellFast(message);
        if (this.query) void this.tellEffort(this.query);
        // total_cost_usd is the running total of this CLI process, so the turn's cost is the difference.
        const cost = message.total_cost_usd - this.costSoFar;
        this.costSoFar = message.total_cost_usd;
        const window = Object.values(message.modelUsage).reduce((largest, usage) => Math.max(largest, usage.contextWindow ?? 0), 0);
        const spent = spentBy(message);
        const held = !this.fresh;
        this.fresh = false;
        if (this.apiError && !spent) this.fail(this.apiError);
        this.apiError = undefined;
        // Messages sent into a spent turn would start a turn of their own in that session, sending
        // it all again, paid for, and failing the same; they go back to the app before it ends.
        if (spent) this.dropWaiting();
        // The CLI is at its cap for good, so the next send starts one with what the thread has left.
        if (message.subtype === "error_max_budget_usd") this.key = "";
        // An interrupt ends the turn as error_during_execution with a diagnostic nobody needs to read.
        if (message.subtype !== "success" && message.errors.length && !this.interrupted && !spent) {
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
          // The session can't be sent to the model again, and the app goes on in a new one.
          ...(spent ? { spent, held } : {}),
          // Messages sent during the turn that it ended without taking up: each runs as a turn
          // of its own, starting now.
          waiting: this.waiting.size,
        });
        // Said for this turn. A Stop from here on is for the turn a waiting message starts, and
        // so is one still on its way, which the CLI may get once it has started that turn.
        this.interrupted = this.stopping;
        if (!this.titled && message.subtype === "success") void this.tellTitle(message.session_id, this.heads.cwd);
        if (spent) {
          // The CLI goes with the session, so nothing more is sent there, and the next send starts
          // a new session, as one that's gone does.
          this.sessionId = undefined;
          this.close();
        }
        this.onIdle?.();
        return;
      }
    }
  }
}

/// The tools that start a subagent, whose own calls follow with `parent`.
const subagentTools = new Set(["Task", "Agent"]);
/// What of a subagent's calls the app is told: the rest would be stored and never read.
const subagentKept = new Set(["Bash", "Edit", "MultiEdit", "Write", ...subagentTools]);

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

/// A task's ending in the words an agent's thread keeps.
function subagentState(status: string): string {
  return status === "completed" ? "done" : status === "failed" ? "failed" : "stopped";
}

/// Whether a send starts its CLI as Ultracode: workflows on at xhigh, which Claude Code runs as
/// its own Ultracode, with the standing reminders and authoring reference that come with it.
export function ultracode(params: Pick<SendParams, "effort" | "workflows">): boolean {
  return params.workflows === true && params.effort === "xhigh";
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

/// Why a turn left its session one the model can't be sent again, which the CLI says itself:
/// `long` when the session no longer fits the model's window, which a single message can't be
/// compacted out of, and `refused` when the model stopped on it and the CLI asks for a new session.
/// Each later turn of that session sends the same and fails the same, and is paid for.
export function spentBy(result: { terminal_reason?: string; stop_reason?: string | null }): "long" | "refused" | undefined {
  if (result.terminal_reason === "prompt_too_long") return "long";
  if (result.stop_reason === "refusal") return "refused";
  return undefined;
}

/// `maker` is the endpoint's, when the thread's Claude Code is pointed at another maker's.
export function errorText(error: string, maker?: string): string {
  const agent = maker ?? "Claude";
  switch (error) {
    case "authentication_failed":
      return maker ? `${maker} didn't take the key. Check it in Settings › Agents.` : "Claude isn't logged in. Run `claude` in Terminal and log in.";
    case "rate_limit":
      return `${agent} is limiting requests for a moment. Try again shortly.`;
    case "server_error":
    case "unknown":
      return `Couldn't reach ${agent}. Check the network, then send again.`;
    case "overloaded":
      return `${agent} is overloaded right now.`;
    case "billing_error":
      return `There's a billing problem with this ${agent} account.`;
    default:
      return `${agent} returned an error (${error}).`;
  }
}

export function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/// Claude Code's line for a background command that ended, 'Background command "Sleep 90" completed
/// (exit code 0)', as its name and how it ended, with the exit code only when it isn't 0.
export function commandEnded(summary: string, how: string): string {
  const named = /^Background command "(.+)"/.exec(summary)?.[1];
  const code = /\(exit code (-?\d+)\)/.exec(summary)?.[1];
  const ended = code !== undefined && code !== "0" ? "failed" : how;
  if (!named) return summary || `Command ${ended}`;
  return code !== undefined && code !== "0" ? `${named} ${ended} · ${code}` : `${named} ${ended}`;
}
