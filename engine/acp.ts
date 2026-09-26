import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { basename } from "node:path";
import { createInterface } from "node:readline";
import { diffOf, hunks, resultText, stopReason, todos, toolKind, toolView, type Location, type PlanEntry, type Todo, type ToolContent } from "./acp-map.ts";
import { lastLine } from "./shell.ts";
import { version } from "./version.ts";
import { event, log } from "./wire.ts";

// A thread on an agent that speaks the Agent Client Protocol, v1: Cursor, Copilot, OpenCode, Grok
// Build, Devin. The engine runs the agent's own binary and talks JSON-RPC to it over the same
// newline-delimited JSON it speaks to the app. @agentclientprotocol/sdk would do the talking, but
// with zod, its peer, it's 14MB on disk and 21MB of memory once imported, for the few hundred
// lines below.

/// How a provider starts its agent: `cursor-agent acp`, `copilot --acp`, `opencode acp`,
/// `grok agent stdio`, `devin acp`.
export type AcpAgent = {
  /// The maker's name for it, which its errors carry.
  name: string;
  command: string;
  args: string[];
  /// Added to the scrubbed environment for this process only, such as OPENCODE_PERMISSION.
  env?: Record<string, string>;
  /// A sign-in the agent runs itself from the login its user made in Terminal, such as
  /// cursor_login. The engine never hands it a key.
  authMethod?: string;
};

export type AcpSendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  /// The agent's own model id.
  model?: string;
  /// The agent's own mode id. A mode it doesn't have, one of Claude's, leaves its mode alone.
  permissionMode?: string;
  attachments?: { mediaType: string; data: string }[];
  costSoFar?: number;
  id?: string;
};

type ConfigValue = { value: string; name: string; description?: string | null };

type ConfigOption = {
  id: string;
  name: string;
  category?: string | null;
  type: string;
  currentValue: string | boolean;
  options?: (ConfigValue | { group: string; name: string; options: ConfigValue[] })[];
};

type SessionModes = { currentModeId: string; availableModes: { id: string; name: string; description?: string | null }[] };

/// Models as Cursor and Copilot send them beside the config options, a field ACP hasn't settled.
type SessionModels = { currentModelId: string; availableModels: { modelId: string; name: string; description?: string | null }[] };

type Capabilities = { loadSession?: boolean; promptCapabilities?: { image?: boolean }; sessionCapabilities?: { resume?: object | null } };

type AuthMethod = { id: string; name: string; description?: string | null };

type SessionReply = { sessionId?: string; modes?: SessionModes | null; configOptions?: ConfigOption[] | null; models?: SessionModels | null };

type ToolCallUpdate = {
  toolCallId: string;
  title?: string | null;
  name?: string | null;
  kind?: string | null;
  status?: string | null;
  rawInput?: unknown;
  rawOutput?: unknown;
  locations?: Location[] | null;
  content?: ToolContent[] | null;
};

type Call = ToolCallUpdate & { used: boolean; done: boolean };

type PermissionOption = { optionId: string; name: string; kind: string };

type Outcome = { outcome: { outcome: "cancelled" } | { outcome: "selected"; optionId: string } };

type Ask = { session: AcpSession; options: PermissionOption[]; resolve: (outcome: Outcome) => void };

/// What an agent sends back for a request it couldn't do.
class AgentError extends Error {
  code: number;
  data: unknown;

  constructor(error: { code: number; message: string; data?: unknown }) {
    super(error.message);
    this.code = error.code;
    this.data = error.data;
  }
}

const authenticationRequired = -32000;

const asks = new Map<string, Ask>();

/// The user's choice for an agent's permission ask: the option they picked, or the agent's own
/// allow once or reject once for a plain yes or no. False when no ACP agent is waiting on it.
export function answer(params: { requestId: string; allow: boolean; optionId?: string }): boolean {
  const ask = asks.get(params.requestId);
  if (!ask) return false;
  asks.delete(params.requestId);
  const wanted = params.allow ? "allow" : "reject";
  const option =
    ask.options.find((option) => option.optionId === params.optionId) ??
    ask.options.find((option) => option.kind === `${wanted}_once`) ??
    ask.options.find((option) => option.kind.startsWith(wanted));
  ask.resolve(option ? { outcome: { outcome: "selected", optionId: option.optionId } } : { outcome: { outcome: "cancelled" } });
  return true;
}

/// The engine's environment without what a Claude Code session leaves in it. This shell exports
/// CLAUDE_CODE_MESSAGING_TOKEN, and no other agent has any business with Claude's variables; nor
/// with AI_AGENT, or a PWD that isn't the folder it runs in.
export function agentEnvironment(extra: Record<string, string> = {}): NodeJS.ProcessEnv {
  const kept: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (key.startsWith("CLAUDE") || key === "AI_AGENT" || key === "PWD" || key === "OLDPWD") continue;
    kept[key] = value;
  }
  return { ...kept, ...extra };
}

/// The session a thread on an ACP agent talks to, one agent process per thread. It implements
/// provider.ts's Session once K-172 lands.
export class AcpSession {
  readonly id: string;
  private agent: AcpAgent;
  private child: ChildProcessWithoutNullStreams | undefined;
  private capabilities: Capabilities = {};
  private authMethods: AuthMethod[] = [];
  private nextId = 0;
  private pending = new Map<number, { resolve: (result: any) => void; reject: (error: Error) => void }>();
  /// The last of what the agent wrote to stderr, which says why it went when it goes.
  private stderr = "";
  private cwd = "";
  private sessionId: string | undefined;
  /// Whether this process has the session open.
  private live = false;
  /// While a load replays the conversation, which the app already has.
  private loading = false;
  private running = false;
  private interrupted = false;
  private errored = false;
  /// Counts turns, so what a finished one leaves behind can't reach the next.
  private turns = 0;
  private turnStart = 0;
  private calls = new Map<string, Call>();
  private lastPlan = "";
  private context: { used: number; window: number } | undefined;
  /// The session's running cost as the agent last said it, and what of it earlier turns account for.
  private cost: number | undefined;
  private costBase = 0;
  private mode: string | undefined;
  private idleSince: number | undefined;
  private availableCommands: { name: string; description: string; input?: { hint?: string } | null }[] | undefined;
  onIdle: (() => void) | undefined;

  /// The session's modes, config options and models as the agent last gave them, which
  /// `modes()` and `listModels()` read.
  sessionModes: SessionModes | undefined;
  configOptions: ConfigOption[] = [];
  sessionModels: SessionModels | undefined;

  constructor(id: string, agent: AcpAgent) {
    this.id = id;
    this.agent = agent;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// A turn always starts a new one here: ACP has no way into a running turn, so the app queues
  /// what's sent meanwhile. The reply doesn't wait for the agent, which can take seconds to
  /// open a session; what happens comes as events.
  async send(params: AcpSendParams): Promise<boolean> {
    if (this.running) throw new Error("A turn is already running in this thread.");
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    log(`send thread=${this.id} agent=${this.agent.name} model=${params.model ?? "default"} mode=${params.permissionMode ?? "default"}`);
    this.running = true;
    this.interrupted = false;
    this.errored = false;
    this.turnStart = Date.now();
    this.calls.clear();
    const turn = ++this.turns;
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    void this.turn(params, turn);
    return false;
  }

  /// Stop: the agent is told to cancel, and every ask of this turn stops waiting. The agent then
  /// answers the prompt as cancelled, which ends the turn.
  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.interrupted = true;
    if (this.live && this.sessionId) this.notify("session/cancel", { sessionId: this.sessionId });
    this.cancelAsks();
  }

  /// The agent's own mode id, applied now when a session is open, and held for the next one.
  async setMode(mode: string): Promise<boolean> {
    this.mode = mode;
    if (!this.live) return true;
    return this.applyMode(mode).catch(() => false);
  }

  /// ACP has no fast mode.
  async setFast(_fast: boolean): Promise<boolean> {
    return false;
  }

  /// ACP says nothing of an agent's subagents.
  watchHeads(_on: boolean): void {}

  async stopTask(_taskId: string): Promise<void> {}

  /// The slash commands the agent listed for the open session, in the shape the SDK gives Claude's.
  async commands(): Promise<{ name: string; description: string; argumentHint: string }[] | undefined> {
    if (!this.child) return undefined;
    return this.availableCommands?.map((command) => ({ name: command.name, description: command.description, argumentHint: command.input?.hint ?? "" }));
  }

  /// Ends the agent of a thread idle this long with nothing asked of the user. The next send
  /// starts one that picks the session up again.
  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.child || this.running || this.idleSince === undefined) return false;
    if (now - this.idleSince < idleMs) return false;
    if ([...asks.values()].some((ask) => ask.session === this)) return false;
    this.close();
    return true;
  }

  idleLeft(idleMs: number, now = Date.now()): number | undefined {
    if (!this.child || this.running || this.idleSince === undefined) return undefined;
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
    const child = this.child;
    this.gone(new Error(`${this.agent.name} was closed.`));
    if (!child) return;
    child.stdin.end();
    child.kill("SIGTERM");
    // One that ignores SIGTERM would hold its memory for good.
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 2000).unref();
  }

  private async turn(params: AcpSendParams, turn: number): Promise<void> {
    try {
      if (this.child && params.cwd !== this.cwd) this.stop();
      if (!this.child) await this.start(params);
      if (!this.live) await this.open(params);
      if (this.interrupted) return this.finish(turn, "interrupted");
      const mode = params.permissionMode ?? this.mode;
      if (mode) await this.applyMode(mode);
      if (params.model) await this.applyModel(params.model);
      event("turn.started", { threadId: this.id, sessionId: this.sessionId });
      const reply: { stopReason?: string; usage?: Record<string, number | null> | null } = await this.request("session/prompt", { sessionId: this.sessionId, prompt: this.prompt(params) });
      this.finish(turn, stopReason(reply.stopReason), reply.usage ?? undefined);
    } catch (error) {
      // The agent going says so itself; a close says nothing.
      if (turn !== this.turns || !this.running) return;
      this.fail(error instanceof AgentError && error.code === authenticationRequired ? this.signInHint(error) : describe(error));
      this.finish(turn, "error_during_execution");
    }
  }

  private async start(params: AcpSendParams): Promise<void> {
    log(`start thread=${this.id} ${this.agent.command} ${this.agent.args.join(" ")} cwd=${params.cwd}`);
    const child = spawn(this.agent.command, this.agent.args, { cwd: params.cwd, env: agentEnvironment(this.agent.env), stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.cwd = params.cwd;
    this.stderr = "";
    // Written to after the agent has gone, its stdin fails with EPIPE, which unheard ends the engine.
    child.stdin.on("error", () => {});
    child.stderr.on("data", (chunk: Buffer) => {
      process.stderr.write(chunk);
      this.stderr = (this.stderr + chunk.toString("utf8")).slice(-4096);
    });
    createInterface({ input: child.stdout }).on("line", (line) => {
      if (child === this.child) this.receive(line);
    });
    child.on("error", (error) => this.exited(child, `Couldn't start ${this.agent.name}: ${error.message}`));
    // Once its pipes have closed, so the last of its stderr has been read.
    child.on("close", (code, signal) => this.exited(child, `${this.agent.name} stopped${lastLine(this.stderr) ? `: ${lastLine(this.stderr)}` : signal ? ` (${signal}).` : ` (exit code ${code}).`}`));
    const init: {
      protocolVersion?: number;
      agentCapabilities?: Capabilities;
      authMethods?: AuthMethod[];
    } = await this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false },
      clientInfo: { name: "oricode", title: "OriCode", version },
    });
    if (init.protocolVersion !== 1) throw new Error(`${this.agent.name} speaks version ${init.protocolVersion} of the Agent Client Protocol, and OriCode speaks 1.`);
    this.capabilities = init.agentCapabilities ?? {};
    this.authMethods = init.authMethods ?? [];
    const method = this.agent.authMethod;
    if (method && this.authMethods.some((known) => known.id === method)) await this.request("authenticate", { methodId: method });
  }

  /// Opens the thread's session on this process: picked up without its history when the agent
  /// can, since the app has that already, else loaded, else new. One that's gone is said to be,
  /// and the turn goes on in a new one.
  private async open(params: AcpSendParams): Promise<void> {
    const earlier = params.sessionId ?? this.sessionId;
    const setup = { cwd: params.cwd, mcpServers: [] };
    let reply: SessionReply | undefined;
    if (earlier && (this.capabilities.sessionCapabilities?.resume || this.capabilities.loadSession)) {
      const resume = Boolean(this.capabilities.sessionCapabilities?.resume);
      this.loading = !resume;
      try {
        reply = await this.request(resume ? "session/resume" : "session/load", { sessionId: earlier, ...setup });
        this.sessionId = earlier;
        this.costBase = params.costSoFar ?? 0;
      } catch (error) {
        // The agent going, or wanting a sign-in, isn't the session being gone.
        if (!this.child || (error instanceof AgentError && error.code === authenticationRequired)) throw error;
        log(`session ${earlier} not picked up for thread=${this.id}: ${describe(error)}`);
        event("session.lost", { threadId: this.id });
      } finally {
        this.loading = false;
      }
    }
    if (!reply) {
      const fresh: SessionReply = await this.request("session/new", setup);
      this.sessionId = fresh.sessionId;
      this.costBase = 0;
      reply = fresh;
    }
    this.live = true;
    this.cost = undefined;
    this.sessionModes = reply.modes ?? undefined;
    this.configOptions = reply.configOptions ?? [];
    this.sessionModels = reply.models ?? undefined;
  }

  private async applyMode(mode: string): Promise<boolean> {
    const option = this.configOptions.find((option) => option.category === "mode");
    if (option && values(option).some((value) => value.value === mode)) {
      if (option.currentValue !== mode) await this.setConfig(option.id, mode);
      if (this.sessionModes) this.sessionModes.currentModeId = mode;
      return true;
    }
    if (!this.sessionModes?.availableModes.some((known) => known.id === mode)) return false;
    if (this.sessionModes.currentModeId !== mode) {
      await this.request("session/set_mode", { sessionId: this.sessionId, modeId: mode });
      this.sessionModes.currentModeId = mode;
    }
    return true;
  }

  private async applyModel(model: string): Promise<void> {
    const option = this.configOptions.find((option) => option.category === "model");
    if (option && values(option).some((value) => value.value === model)) {
      if (option.currentValue !== model) await this.setConfig(option.id, model);
    } else if (this.sessionModels && this.sessionModels.currentModelId !== model) {
      await this.request("session/set_model", { sessionId: this.sessionId, modelId: model });
      this.sessionModels.currentModelId = model;
    }
  }

  private async setConfig(configId: string, value: string): Promise<void> {
    const reply: { configOptions?: ConfigOption[] } = await this.request("session/set_config_option", { sessionId: this.sessionId, configId, value });
    if (reply.configOptions) this.configOptions = reply.configOptions;
  }

  private prompt(params: AcpSendParams): object[] {
    // An agent that can't see images is sent the words alone.
    const images = this.capabilities.promptCapabilities?.image ? (params.attachments ?? []) : [];
    return [...images.map((image) => ({ type: "image", mimeType: image.mediaType, data: image.data })), { type: "text", text: params.text }];
  }

  /// What a -32000 says to do: the agent's own words, or the Terminal line its sign-in names.
  private signInHint(error: AgentError): string {
    const said = (error.data as { message?: unknown } | undefined)?.message;
    if (typeof said === "string" && said) return said;
    const how = this.authMethods.find((method) => method.description)?.description;
    return how ? `${this.agent.name} isn't signed in. ${how}.` : `${this.agent.name}: ${error.message}.`;
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  private finish(turn: number, reason: string, usage?: Record<string, number | null>): void {
    if (turn !== this.turns || !this.running) return;
    this.running = false;
    this.idleSince = Date.now();
    const cost = this.cost === undefined ? undefined : Math.max(0, this.cost - this.costBase);
    if (this.cost !== undefined) this.costBase = this.cost;
    event("turn.done", {
      threadId: this.id,
      sessionId: this.sessionId,
      stopReason: this.interrupted ? "interrupted" : reason,
      durationMs: Date.now() - this.turnStart,
      costUSD: cost,
      usage: usage && {
        input: usage.inputTokens ?? 0,
        output: usage.outputTokens ?? 0,
        cacheRead: usage.cachedReadTokens ?? 0,
        cacheWrite: usage.cachedWriteTokens ?? 0,
      },
      context: this.context,
      waiting: 0,
    });
    this.onIdle?.();
  }

  private cancelAsks(): void {
    for (const [requestId, ask] of asks) {
      if (ask.session !== this) continue;
      asks.delete(requestId);
      event("ask.cancelled", { threadId: this.id, requestId });
      ask.resolve({ outcome: { outcome: "cancelled" } });
    }
  }

  /// The agent's process has gone, whether it quit, crashed or never started. A turn it was in
  /// ends as the engine's stopping, and its asks with it.
  private exited(child: ChildProcessWithoutNullStreams, message: string): void {
    if (child !== this.child) return;
    log(`thread=${this.id} ${message}`);
    this.cancelAsks();
    this.gone(new Error(message));
    if (!this.running) return;
    this.fail(message);
    this.finish(this.turns, "engine_stopped");
  }

  /// Everything asked of this process fails, and the next send starts another.
  private gone(error: Error): void {
    this.child = undefined;
    this.live = false;
    this.availableCommands = undefined;
    const pending = [...this.pending.values()];
    this.pending.clear();
    for (const request of pending) request.reject(error);
  }

  private request(method: string, params: object): Promise<any> {
    if (!this.child) return Promise.reject(new Error(`${this.agent.name} isn't running.`));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ jsonrpc: "2.0", id, method, params });
    });
  }

  private notify(method: string, params: object): void {
    this.write({ jsonrpc: "2.0", method, params });
  }

  private write(message: object): void {
    this.child?.stdin.write(JSON.stringify(message) + "\n");
  }

  private receive(line: string): void {
    let message: { id?: number | string; method?: string; params?: any; result?: unknown; error?: { code: number; message: string; data?: unknown } };
    try {
      message = JSON.parse(line);
    } catch {
      if (line.trim()) log(`${this.agent.name} wrote a line that isn't JSON: ${line.slice(0, 200)}`);
      return;
    }
    if (message.method === undefined) {
      const request = this.pending.get(message.id as number);
      if (!request) return;
      this.pending.delete(message.id as number);
      if (message.error) request.reject(new AgentError(message.error));
      else request.resolve(message.result ?? {});
      return;
    }
    if (message.id === undefined) {
      if (message.method === "session/update") this.update(message.params.update);
      return;
    }
    const id = message.id;
    // fs and terminal are turned off in initialize, so a request for them is one we don't know.
    const answered: Promise<unknown> =
      message.method === "session/request_permission" ? this.permission(message.params) : Promise.reject(new AgentError({ code: -32601, message: `${message.method} isn't offered.` }));
    answered.then(
      (result) => this.write({ jsonrpc: "2.0", id, result }),
      (error: AgentError) => this.write({ jsonrpc: "2.0", id, error: { code: error.code ?? -32603, message: error.message } }),
    );
  }

  private update(update: { sessionUpdate: string; [field: string]: any }): void {
    switch (update.sessionUpdate) {
      case "available_commands_update":
        this.availableCommands = update.availableCommands;
        return;
      case "current_mode_update":
        if (this.sessionModes) this.sessionModes.currentModeId = update.currentModeId;
        for (const option of this.configOptions) if (option.category === "mode") option.currentValue = update.currentModeId;
        return;
      case "config_option_update":
        this.configOptions = update.configOptions ?? [];
        return;
      case "usage_update":
        this.context = { used: update.used, window: update.size };
        if (update.cost?.currency === "USD") this.cost = update.cost.amount;
        return;
    }
    // A load replays the conversation, and what comes between turns belongs to none.
    if (this.loading || !this.running) return;
    switch (update.sessionUpdate) {
      case "agent_message_chunk":
        // TODO(K-182): Copilot sends its errors as ordinary text, "Error: Authorization error…",
        // which shows as the reply until that card tells them apart.
        if (update.content?.type === "text") event("text", { threadId: this.id, delta: update.content.text });
        return;
      case "agent_thought_chunk":
        if (update.content?.type === "text") event("thinking", { threadId: this.id, delta: update.content.text });
        return;
      case "tool_call":
      case "tool_call_update":
        this.track(update as unknown as ToolCallUpdate);
        return;
      case "plan":
        this.plan(update.entries ?? []);
        return;
    }
  }

  /// A call builds up over several updates, Cursor's input coming only after the call. It's told
  /// to the app once it says what it's on, or once it runs or is asked about, and its result
  /// once it has finished.
  private track(update: ToolCallUpdate): Call {
    let call = this.calls.get(update.toolCallId);
    if (!call) {
      call = { toolCallId: update.toolCallId, used: false, done: false };
      this.calls.set(update.toolCallId, call);
    }
    // OpenCode's permission request names the call with an empty input and no locations, which
    // mustn't wipe out the ones its last update gave.
    for (const [key, value] of Object.entries(update)) {
      if (value === null || value === undefined || (typeof value === "object" && Object.keys(value).length === 0)) continue;
      (call as Record<string, unknown>)[key] = value;
    }
    const input = call.rawInput && typeof call.rawInput === "object" && Object.keys(call.rawInput).length > 0;
    if (!call.used && (input || call.locations?.length || diffOf(call.content) || (call.status ?? "pending") !== "pending")) this.use(call);
    if (!call.done && (call.status === "completed" || call.status === "failed")) {
      call.done = true;
      const diff = diffOf(call.content);
      event("tool.result", {
        threadId: this.id,
        toolUseId: call.toolCallId,
        content: resultText(call.content, call.rawOutput),
        isError: call.status === "failed",
        patch: diff && call.status === "completed" ? hunks(diff.oldText, diff.newText) : undefined,
      });
    }
    return call;
  }

  private use(call: Call): void {
    if (call.used) return;
    call.used = true;
    event("tool.use", {
      threadId: this.id,
      toolUseId: call.toolCallId,
      name: call.name ?? call.title ?? "Tool",
      input: call.rawInput ?? {},
      kind: toolKind(call.kind),
      view: toolView(call.rawInput, call.locations, call.content),
    });
  }

  /// ACP's plan is no tool call, and comes whole each time it changes. Each is told as a
  /// TodoWrite call, which the plan card already folds into the one it started.
  private plan(entries: PlanEntry[]): void {
    const list: Todo[] = todos(entries);
    const told = JSON.stringify(list);
    if (told === this.lastPlan) return;
    this.lastPlan = told;
    const toolUseId = `plan-${randomUUID()}`;
    event("tool.use", { threadId: this.id, toolUseId, name: "TodoWrite", input: { todos: list }, kind: "plan", view: { todos: list } });
    event("tool.result", { threadId: this.id, toolUseId, content: "", isError: false });
  }

  /// The agent's own options become the ask's choices, and the one picked goes back by its id.
  private permission(params: { toolCall: ToolCallUpdate; options: PermissionOption[] }): Promise<Outcome> {
    const call = this.track(params.toolCall);
    this.use(call);
    const requestId = randomUUID();
    return new Promise((resolve) => {
      asks.set(requestId, { session: this, options: params.options, resolve });
      event("ask", {
        threadId: this.id,
        requestId,
        kind: "permission",
        tool: call.name ?? call.title ?? "Tool",
        toolUseId: call.toolCallId,
        input: call.rawInput ?? {},
        view: toolView(call.rawInput, call.locations, call.content),
        choices: params.options.map((option) => ({ id: option.optionId, name: option.name, kind: option.kind })),
      });
    });
  }
}

/// The models a session offers and the one it's on: from its config option of category model,
/// or from the models field Cursor and Copilot send beside it.
export function listModels(session: AcpSession): { current: string | null; models: { id: string; name: string; description: string | null }[] } {
  const option = session.configOptions.find((option) => option.category === "model");
  if (option) return { current: String(option.currentValue), models: values(option).map((value) => ({ id: value.value, name: value.name, description: value.description ?? null })) };
  const models = session.sessionModels;
  return {
    current: models?.currentModelId ?? null,
    models: (models?.availableModels ?? []).map((model) => ({ id: model.modelId, name: model.name, description: model.description ?? null })),
  };
}

/// The modes a session offers and the one it's in, from its config option of category mode or
/// from its modes.
export function modes(session: AcpSession): { current: string | null; modes: { id: string; name: string; description: string | null }[] } {
  const option = session.configOptions.find((option) => option.category === "mode");
  if (option) return { current: String(option.currentValue), modes: values(option).map((value) => ({ id: value.value, name: value.name, description: value.description ?? null })) };
  const known = session.sessionModes;
  return {
    current: known?.currentModeId ?? null,
    modes: (known?.availableModes ?? []).map((mode) => ({ id: mode.id, name: mode.name, description: mode.description ?? null })),
  };
}

/// A select option's values, its groups flattened.
function values(option: ConfigOption): ConfigValue[] {
  return (option.options ?? []).flatMap((entry) => ("group" in entry ? entry.options : [entry]));
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
