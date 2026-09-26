import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { basename } from "node:path";
import { agentEnvironment } from "./acp.ts";
import { hunks, toolView, type Hunk, type View } from "./acp-map.ts";
import { unifiedHunks } from "./codex.ts";
import type { Availability, Capabilities } from "./provider.ts";
import { lastLine } from "./shell.ts";
import { event, log } from "./wire.ts";

// A thread on Pi, through the user's own `pi --mode rpc`: commands on its stdin and responses and
// events on its stdout, one JSON object to a line, one process per thread. Pi keeps each thread's
// session as a file under ~/.pi/agent/sessions, where `pi --resume` lists it beside the user's
// own; the app keeps that file's path as the thread's session. Pi never asks before it runs a
// tool, so a thread on it runs unsupervised, and nothing here waits on the user.

/// How to run the user's pi, and what goes before its arguments, which is how the tests run a
/// stand-in under node.
export type PiBinary = { command: string; args?: string[]; env?: Record<string, string> };

export type PiSendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  /// Pi's provider and its model id, `anthropic/claude-opus-4-5`. OpenRouter's ids have slashes
  /// of their own, so only the first one splits.
  model?: string;
  /// Pi's thinking level, off to max.
  effort?: string;
  permissionMode?: string;
  attachments?: { mediaType: string; data: string }[];
  costSoFar?: number;
  id?: string;
  /// Sent during a turn, it waits until Pi has nothing left to do in it rather than joining at the
  /// next step: how a queued message goes.
  followUp?: boolean;
};

/// What a thread on Pi can do. Pi has no permission modes and never asks, which K-176 reads as a
/// thread that says it runs unsupervised and offers no permission tiles.
export const capabilities: Capabilities & { unsupervised: boolean } = {
  steer: true,
  resume: true,
  modeLive: false,
  attachments: true,
  heads: false,
  stopTask: false,
  limits: false,
  usage: false,
  commands: true,
  compact: false,
  commitMessage: false,
  handoff: "pi --session {session}",
  unsupervised: true,
};

export const levels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

type Usage = { input: number; output: number; cacheRead: number; cacheWrite: number; totalTokens: number; cost?: { total: number } };

type Message = { role: string; content?: unknown; usage?: Usage; stopReason?: string; errorMessage?: string };

type ToolOutcome = { content?: { type: string; text?: string }[]; details?: { patch?: unknown } };

type Waiting = { id?: string; text: string };

/// The session a thread on Pi talks to, one `pi --mode rpc` per thread. It implements
/// provider.ts's Session once it's wired.
export class PiSession {
  readonly id: string;
  private binary: PiBinary;
  private rpc: Rpc | undefined;
  private cwd = "";
  /// The session file Pi writes the thread to, which the app keeps and a new process resumes.
  private sessionFile: string | undefined;
  /// What this process has been told, so a send changes only what it asks for.
  private model: string | undefined;
  private effort: string | undefined;
  private window = 0;
  private running = false;
  /// Between Pi's agent_start and agent_settled, while a message sent to it joins the run.
  private streaming = false;
  private interrupted = false;
  private errored = false;
  /// Counts turns, so what a finished one leaves behind can't reach the next.
  private turns = 0;
  private turnStart = 0;
  /// The turn's own prompt hasn't come back from Pi as a user message yet.
  private prompted = false;
  /// Pi started this run by itself, with a message that came as the last one settled.
  private adopted = false;
  /// Sent during a turn before Pi's run had started, when a second prompt would race the first.
  private held: PiSendParams[] = [];
  /// Sent into the run and not yet seen in it, oldest first.
  private pending: Waiting[] = [];
  /// This turn's tool calls by id, whose arguments Pi doesn't repeat when the call ends.
  private calls = new Map<string, Record<string, unknown>>();
  private spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  private cost = 0;
  private context: { used: number; window: number } | undefined;
  private stopReason = "end_turn";
  private lastError: string | undefined;
  private idleSince: number | undefined;
  onIdle: (() => void) | undefined;

  constructor(id: string, binary: PiBinary = { command: "pi" }) {
    this.id = id;
    this.binary = binary;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// A send during a turn joins it, and the reply says it's waiting. Otherwise it starts a turn,
  /// and what happens comes as events.
  async send(params: PiSendParams): Promise<boolean> {
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    if (this.running) {
      if (this.streaming) this.join(params);
      else this.held.push(params);
      return true;
    }
    this.begin(params);
    return false;
  }

  /// Stop: what was sent and not yet taken comes off Pi's queue first, since Pi runs whatever is
  /// left on it after an abort, and then the run is aborted. Pi ends it as settled.
  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.interrupted = true;
    this.cancelWaiting();
    if (!this.streaming) return;
    await this.request("clear_queue", {}).catch((error) => log(`clear_queue for thread=${this.id}: ${describe(error)}`));
    await this.request("abort", {}).catch((error) => log(`abort for thread=${this.id}: ${describe(error)}`));
  }

  async setMode(_mode: string): Promise<boolean> {
    return false;
  }

  async setFast(_fast: boolean): Promise<boolean> {
    return false;
  }

  watchHeads(_on: boolean): void {}

  async stopTask(_taskId: string): Promise<void> {}

  /// Pi's extension commands, prompt templates and skills, each run by sending its name after a
  /// slash.
  async commands(): Promise<{ name: string; description: string; argumentHint: string }[] | undefined> {
    if (!this.rpc) return undefined;
    const reply: { commands: { name: string; description?: string }[] } | undefined = await this.request("get_commands", {}).catch(() => undefined);
    return reply?.commands.map((command) => ({ name: command.name, description: command.description ?? "", argumentHint: "" }));
  }

  /// Ends the process of a thread idle this long. The next send starts one on the same session file.
  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.rpc || this.running || this.pending.length > 0 || this.idleSince === undefined) return false;
    if (now - this.idleSince < idleMs) return false;
    this.close();
    return true;
  }

  idleLeft(idleMs: number, now = Date.now()): number | undefined {
    if (!this.rpc || this.running || this.idleSince === undefined) return undefined;
    return Math.max(0, this.idleSince + idleMs - now);
  }

  /// The thread is gone or the engine is going. A turn still running ends with nothing said, as
  /// a Claude thread's does.
  close(): void {
    this.running = false;
    this.stop();
  }

  private stop(): void {
    const rpc = this.rpc;
    this.rpc = undefined;
    this.streaming = false;
    rpc?.close();
  }

  private begin(params: PiSendParams): void {
    log(`send thread=${this.id} agent=pi model=${params.model ?? "default"} effort=${params.effort ?? "default"}`);
    this.open();
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    void this.turn(params, this.turns);
  }

  private open(): void {
    this.running = true;
    this.streaming = false;
    this.interrupted = false;
    this.errored = false;
    this.adopted = false;
    this.lastError = undefined;
    this.stopReason = "end_turn";
    this.turnStart = Date.now();
    this.calls.clear();
    this.spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
    this.cost = 0;
    this.turns += 1;
  }

  private async turn(params: PiSendParams, turn: number): Promise<void> {
    try {
      if (this.rpc && params.cwd !== this.cwd) this.stop();
      if (!this.rpc) await this.start(params);
      if (this.interrupted) return this.finish(turn, "interrupted");
      if (params.model && params.model !== this.model) {
        const model: { contextWindow?: number } = await this.request("set_model", modelRef(params.model));
        this.model = params.model;
        this.window = model.contextWindow ?? this.window;
      }
      if (params.effort && params.effort !== this.effort) {
        await this.request("set_thinking_level", { level: params.effort });
        this.effort = params.effort;
      }
      event("turn.started", { threadId: this.id, sessionId: this.sessionFile });
      this.prompted = true;
      await this.request("prompt", { message: params.text, images: images(params) });
      // An extension command, or an extension that takes the text itself, is handled without a
      // run, and nothing would end the turn. Pi's run is active by the time it answers a prompt
      // it runs, so a state that isn't streaming, with no run seen, is one of those.
      const state: { isStreaming: boolean } = await this.request("get_state", {});
      if (turn === this.turns && !this.streaming && !state.isStreaming) this.finish(turn, "end_turn");
    } catch (error) {
      // The process going says so itself; a close says nothing.
      if (turn !== this.turns || !this.running) return;
      this.fail(describe(error));
      this.finish(turn, "error_during_execution");
    }
  }

  /// Starts Pi on the thread's session: a file it wrote before, or an id it knows. A file that's
  /// gone is said to be, and the turn goes on in a new session. An id goes by --session-id, which
  /// opens it or makes it; --session would ask on stdin whether to fork a match from another
  /// folder, and read the next command as the answer.
  private async start(params: PiSendParams): Promise<void> {
    const earlier = params.sessionId ?? this.sessionFile;
    const args: string[] = [];
    if (earlier && !earlier.includes("/")) args.push("--session-id", earlier);
    else if (earlier && existsSync(earlier)) args.push("--session", earlier);
    else if (earlier) {
      log(`session ${earlier} not resumed for thread=${this.id}: the file is gone`);
      event("session.lost", { threadId: this.id });
    }
    log(`start thread=${this.id} ${this.binary.command} --mode rpc cwd=${params.cwd}`);
    const rpc = new Rpc(this.binary, args, params.cwd);
    this.rpc = rpc;
    this.cwd = params.cwd;
    this.model = undefined;
    this.effort = undefined;
    rpc.onEvent = (message) => {
      if (rpc === this.rpc) this.received(message);
    };
    rpc.onExit = (message) => this.exited(rpc, message);
    const state: { sessionFile?: string; sessionId: string; model?: { contextWindow?: number } } = await rpc.request("get_state", {});
    this.sessionFile = state.sessionFile ?? state.sessionId;
    this.window = state.model?.contextWindow ?? 0;
  }

  /// Into the running turn: as a steer, which Pi takes after the tools it's running, or as a
  /// follow-up, which it takes once it has nothing left to do. Both go as a prompt that says how
  /// to wait, since Pi's own steer command queues a message even after the run has settled, where
  /// nothing would take it up; a prompt that arrives then starts a run of its own.
  private join(params: PiSendParams): void {
    const how = params.followUp ? "followUp" : "steer";
    log(`${how} thread=${this.id}`);
    const waiting: Waiting = { id: params.id, text: params.text };
    this.pending.push(waiting);
    this.request("prompt", { message: params.text, images: images(params), streamingBehavior: how }).catch((error) => {
      // Pi refused it, as it refuses an extension command during a run: it goes back to the user.
      const at = this.pending.indexOf(waiting);
      if (at === -1) return;
      this.pending.splice(at, 1);
      log(`${how} refused for thread=${this.id}: ${describe(error)}`);
      if (waiting.id) event("message.cancelled", { threadId: this.id, messageId: waiting.id });
    });
  }

  private cancelWaiting(): void {
    for (const waiting of [...this.held.splice(0), ...this.pending.splice(0)]) {
      if (waiting.id) event("message.cancelled", { threadId: this.id, messageId: waiting.id });
    }
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  private finish(turn: number, reason: string): void {
    if (turn !== this.turns || !this.running) return;
    this.running = false;
    this.streaming = false;
    this.idleSince = Date.now();
    event("turn.done", {
      threadId: this.id,
      sessionId: this.sessionFile,
      stopReason: this.interrupted ? "interrupted" : reason,
      durationMs: Date.now() - this.turnStart,
      costUSD: this.cost,
      usage: this.spent,
      context: this.context,
      waiting: this.held.length + this.pending.length,
    });
    // A message still pending reached Pi as its run settled, and Pi runs it itself, which the
    // held ones then join. With none, the first held starts a turn and the rest join it.
    if (this.pending.length === 0) {
      const next = this.held.shift();
      if (next) this.begin(next);
    }
    if (!this.running && this.pending.length === 0) this.onIdle?.();
  }

  /// Pi has gone, whether it quit, crashed or never started. A turn it was in ends as the engine's
  /// stopping, and what was sent to it with it.
  private exited(rpc: Rpc, message: string): void {
    if (rpc !== this.rpc) return;
    log(`thread=${this.id} ${message}`);
    this.rpc = undefined;
    this.streaming = false;
    this.cancelWaiting();
    if (!this.running) return;
    this.fail(message);
    this.finish(this.turns, "engine_stopped");
  }

  private request(type: string, fields: object): Promise<any> {
    if (!this.rpc) return Promise.reject(new Error("Pi isn't running."));
    return this.rpc.request(type, fields);
  }

  private received(message: any): void {
    if (message.type === "agent_start") {
      if (!this.running) {
        log(`thread=${this.id} Pi started a run with a message sent as the last one settled`);
        this.open();
        this.adopted = true;
        this.prompted = false;
        event("turn.started", { threadId: this.id, sessionId: this.sessionFile });
      }
      this.streaming = true;
      if (this.interrupted) void this.request("abort", {}).catch(() => {});
      for (const params of this.held.splice(0)) this.join(params);
      return;
    }
    if (!this.running) return;
    switch (message.type) {
      case "message_start":
        if (message.message.role === "user") this.userMessage(message.message);
        return;
      case "message_update": {
        const update = message.assistantMessageEvent;
        if (update.type === "text_delta") event("text", { threadId: this.id, delta: update.delta });
        else if (update.type === "thinking_delta") event("thinking", { threadId: this.id, delta: update.delta });
        return;
      }
      case "message_end":
        if (message.message.role === "assistant") this.answered(message.message);
        return;
      case "tool_execution_start":
        return this.toolStarted(message.toolCallId, message.toolName, message.args ?? {});
      case "tool_execution_end": {
        const result = toolResult(message.toolName, this.calls.get(message.toolCallId) ?? {}, message.result, message.isError === true);
        event("tool.result", { threadId: this.id, toolUseId: message.toolCallId, content: result.content, isError: message.isError === true, patch: result.patch });
        return;
      }
      case "auto_retry_start":
        log(`thread=${this.id} Pi retrying: ${message.errorMessage}`);
        this.lastError = undefined;
        return;
      case "auto_retry_end":
        if (!message.success) this.lastError = message.finalError ?? this.lastError;
        return;
      case "agent_settled":
        if (this.lastError && !this.interrupted) this.fail(this.lastError);
        this.finish(this.turns, this.lastError ? "error_during_execution" : this.stopReason);
        return;
    }
  }

  /// The turn's prompt, or a message sent into it, as Pi takes it up. Pi may have expanded a skill
  /// or a template in it, so one whose text isn't found is the oldest still waiting.
  private userMessage(message: Message): void {
    if (this.prompted) {
      this.prompted = false;
      return;
    }
    if (this.pending.length === 0) return;
    const text = textOf(message.content);
    const at = this.pending.findIndex((waiting) => waiting.text === text);
    const [taken] = this.pending.splice(Math.max(0, at), 1);
    if (taken.id) event("message.taken", { threadId: this.id, messageId: taken.id, newTurn: this.adopted });
    this.adopted = false;
  }

  /// One call to the model: its usage and cost, the context it left, and how it stopped.
  private answered(message: Message): void {
    const usage = message.usage;
    if (usage) {
      this.spent.input += usage.input;
      this.spent.output += usage.output;
      this.spent.cacheRead += usage.cacheRead;
      this.spent.cacheWrite += usage.cacheWrite;
      this.cost += usage.cost?.total ?? 0;
      if (usage.totalTokens > 0) this.context = { used: usage.totalTokens, window: this.window };
    }
    switch (message.stopReason) {
      case "error":
        this.lastError = message.errorMessage ?? "Pi couldn't finish the turn.";
        return;
      case "aborted":
        this.stopReason = "interrupted";
        return;
      case "length":
        this.stopReason = "max_tokens";
        return;
      case "stop":
        this.stopReason = "end_turn";
        return;
    }
  }

  private toolStarted(id: string, tool: string, args: Record<string, unknown>): void {
    if (this.calls.has(id)) return;
    this.calls.set(id, args);
    const call = toolCall(tool, args);
    event("tool.use", { threadId: this.id, toolUseId: id, name: call.name, input: args, kind: call.kind, view: call.view });
  }
}

/// Pi's built-in tools under Claude Code's names, with K-175's kinds. An extension's tool keeps
/// its own name.
export function toolCall(tool: string, args: Record<string, unknown>): { name: string; kind: string; view: View } {
  const view = toolView(args, null, null);
  switch (tool) {
    case "read":
      return { name: "Read", kind: "read", view };
    case "bash":
      return { name: "Bash", kind: "run", view };
    case "edit":
      return { name: "Edit", kind: "edit", view };
    case "write":
      return { name: "Write", kind: "write", view };
    case "grep":
      return { name: "Grep", kind: "search", view };
    case "find":
      return { name: "Glob", kind: "search", view };
    case "ls":
      return { name: "LS", kind: "list", view };
    default:
      return { name: tool, kind: "other", view };
  }
}

/// What a finished tool says. An edit carries the unified patch Pi made of it; a write carries
/// only the text it wrote, so a file it replaced shows as all new.
export function toolResult(tool: string, args: Record<string, unknown>, outcome: ToolOutcome | undefined, isError: boolean): { content: string; patch?: Hunk[] } {
  const content = (outcome?.content ?? []).flatMap((block) => (block.type === "text" && block.text ? [block.text] : [])).join("\n");
  if (isError) return { content };
  if (tool === "edit" && typeof outcome?.details?.patch === "string") return { content, patch: unifiedHunks(outcome.details.patch) };
  if (tool === "write" && typeof args.content === "string") return { content, patch: hunks(null, args.content) };
  return { content };
}

/// A model id as set_model takes it.
export function modelRef(model: string): { provider: string; modelId: string } {
  const slash = model.indexOf("/");
  return { provider: model.slice(0, slash), modelId: model.slice(slash + 1) };
}

function images(params: PiSendParams): { type: "image"; data: string; mimeType: string }[] | undefined {
  if (!params.attachments?.length) return undefined;
  return params.attachments.map((image) => ({ type: "image", data: image.data, mimeType: image.mediaType }));
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap((block: { type?: string; text?: string }) => (block.type === "text" && block.text ? [block.text] : [])).join("\n");
}

/// A maker whose subscription login pi reuses outside the maker's own CLI, which the maker's terms
/// keep to its own apps: claude.ai through Claude Code's client id, xAI's through grok-cli's, and
/// Meta's through Muse Code's. A model reached that way stays off until turned on in Settings ›
/// Agents under the maker's sentence (K-177).
export type Maker = "anthropic" | "xai" | "meta";

const forbiddenLogins: Record<string, Maker> = { anthropic: "anthropic", xai: "xai", meta: "meta" };

export type PiModel = {
  /// Pi's provider and its model id, as a send names it.
  id: string;
  name: string;
  provider: string;
  /// How pi reaches the provider: by an API key, or a login made with pi's /login, which is a
  /// subscription for Anthropic, OpenAI Codex, Copilot, xAI, Meta and Kimi and mints a key for
  /// OpenRouter.
  auth: "key" | "login";
  forbidden?: Maker;
  efforts: string[];
  images: boolean;
  contextWindow: number;
  isDefault: boolean;
};

type RawModel = { id: string; name: string; provider: string; reasoning: boolean; input: string[]; contextWindow: number; thinkingLevelMap?: Record<string, string | null> };

/// The models the user's pi can reach, grouped by pi's provider. Pi lists only providers it holds
/// a key or a login for, and says which each is when asked with `pi auth check`, which prints no
/// credential; OriCode reads nothing of pi's auth.json. It asks a short-lived pi, offline and
/// without a session, which reaches no model.
export async function listModels(binary: PiBinary = { command: "pi" }): Promise<{ provider: string; models: PiModel[] }[]> {
  const { models, current } = await withRpc(binary, async (rpc) => {
    const listed: { models: RawModel[] } = await rpc.request("get_available_models", {});
    const state: { model?: RawModel } = await rpc.request("get_state", {});
    return { models: listed.models, current: state.model };
  });
  const providers = [...new Set(models.map((model) => model.provider))];
  const logins = new Map(await Promise.all(providers.map(async (provider) => [provider, await authType(binary, provider)] as const)));
  return providers.map((provider) => ({
    provider,
    models: models
      .filter((model) => model.provider === provider)
      .map((model) => {
        const auth = logins.get(provider) === "oauth" ? "login" : "key";
        const forbidden = auth === "login" ? forbiddenLogins[provider] : undefined;
        return {
          id: `${model.provider}/${model.id}`,
          name: model.name,
          provider,
          auth,
          ...(forbidden ? { forbidden } : {}),
          efforts: efforts(model),
          images: model.input.includes("image"),
          contextWindow: model.contextWindow,
          isDefault: current?.provider === model.provider && current.id === model.id,
        };
      }),
  }));
}

/// The levels a model takes, as pi decides them: off alone without reasoning, and xhigh and max
/// only where the model maps them.
export function efforts(model: Pick<RawModel, "reasoning" | "thinkingLevelMap">): string[] {
  if (!model.reasoning) return ["off"];
  return levels.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    return level === "xhigh" || level === "max" ? mapped !== undefined : true;
  });
}

async function authType(binary: PiBinary, provider: string): Promise<string | undefined> {
  const output = await run(binary, ["auth", "check", "--provider", provider, "--json", "--no-refresh"]);
  try {
    return (JSON.parse(output.stdout) as { authType?: string }).authType;
  } catch {
    log(`pi auth check --provider ${provider}: ${lastLine(output.stdout + output.stderr)}`);
    return undefined;
  }
}

const install = "Pi isn't installed. Install it with `npm install -g --ignore-scripts @earendil-works/pi-coding-agent`, then run `pi` and /login.";

/// Whether the user's pi is there and can reach a model: signed in means it holds a key or a
/// login for at least one provider.
export async function availability(binary: PiBinary = { command: "pi" }): Promise<Availability> {
  const found = await run(binary, ["--version"]);
  if (found.missing) return { state: "missing", cli: null, version: null, hint: install };
  const version = lastLine(found.stdout) || null;
  const models: { models: unknown[] } | undefined = await withRpc(binary, (rpc) => rpc.request("get_available_models", {})).catch((error) => {
    log(`pi get_available_models: ${describe(error)}`);
    return undefined;
  });
  if (!models?.models.length) return { state: "signedOut", cli: binary.command, version, hint: "Run `pi` in Terminal, then /login." };
  return { state: "ready", cli: binary.command, version, hint: null };
}

function run(binary: PiBinary, args: string[]): Promise<{ stdout: string; stderr: string; missing: boolean }> {
  return new Promise((resolve) => {
    execFile(binary.command, [...(binary.args ?? []), ...args], { env: agentEnvironment(binary.env), timeout: 10_000 }, (error, stdout, stderr) => {
      resolve({ stdout, stderr, missing: (error as NodeJS.ErrnoException | null)?.code === "ENOENT" });
    });
  });
}

async function withRpc<T>(binary: PiBinary, use: (rpc: Rpc) => Promise<T>): Promise<T> {
  const rpc = new Rpc(binary, ["--no-session", "--offline"], homedir());
  try {
    return await use(rpc);
  } finally {
    rpc.close();
  }
}

/// One `pi --mode rpc` and the JSON lines spoken with it.
class Rpc {
  private child: ChildProcessWithoutNullStreams;
  private nextId = 0;
  private pending = new Map<string, { resolve: (data: any) => void; reject: (error: Error) => void }>();
  /// What has come of the line being read.
  private partial = "";
  /// The last of what it wrote to stderr, which says why it went when it goes.
  private stderr = "";
  private gone = false;
  onEvent: (message: any) => void = () => {};
  onExit: (message: string) => void = () => {};

  constructor(binary: PiBinary, args: string[], cwd: string) {
    const child = spawn(binary.command, [...(binary.args ?? []), "--mode", "rpc", ...args], { cwd, env: agentEnvironment(binary.env), stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    // Written to after it has gone, its stdin fails with EPIPE, which unheard ends the engine.
    child.stdin.on("error", () => {});
    child.stderr.on("data", (chunk: Buffer) => {
      process.stderr.write(chunk);
      this.stderr = (this.stderr + chunk.toString("utf8")).slice(-4096);
    });
    // Split on LF alone: readline also splits on U+2028 and U+2029, which a JSON string may hold.
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      const lines = (this.partial + chunk).split("\n");
      this.partial = lines.pop() ?? "";
      for (const line of lines) this.receive(line.endsWith("\r") ? line.slice(0, -1) : line);
    });
    child.on("error", (error) => this.exit(`Couldn't start Pi: ${error.message}`));
    // Once its pipes have closed, so the last of its stderr has been read.
    child.on("close", (code, signal) => this.exit(`Pi stopped${lastLine(this.stderr) ? `: ${lastLine(this.stderr)}` : signal ? ` (${signal}).` : ` (exit code ${code}).`}`));
  }

  request(type: string, fields: object): Promise<any> {
    if (this.gone) return Promise.reject(new Error("Pi isn't running."));
    const id = String(this.nextId++);
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.write({ id, type, ...fields });
    });
  }

  /// Pi shuts down in order once its stdin closes, saving the session as it goes.
  close(): void {
    const child = this.child;
    this.exit("Pi was closed.");
    child.stdin.end();
    // One that doesn't would hold its memory for good.
    setTimeout(() => {
      if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    }, 3000).unref();
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
    let message: { type?: string; id?: string; success?: boolean; data?: unknown; error?: string; method?: string };
    try {
      message = JSON.parse(line);
    } catch {
      if (line.trim()) log(`Pi wrote a line that isn't JSON: ${line.slice(0, 200)}`);
      return;
    }
    if (message.type === "response") {
      const request = message.id === undefined ? undefined : this.pending.get(message.id);
      if (!request) return log(`Pi answered nothing asked: ${line.slice(0, 200)}`);
      this.pending.delete(message.id!);
      if (message.success) request.resolve(message.data ?? {});
      else request.reject(new Error(message.error ?? "Pi refused it."));
      return;
    }
    if (message.type === "extension_ui_request") {
      // An extension's dialog has nowhere to show yet, and one left unanswered holds its run.
      if (["select", "confirm", "input", "editor"].includes(message.method ?? "")) {
        log(`Pi's extension asked for ${message.method}, which isn't offered`);
        this.write({ type: "extension_ui_response", id: message.id, cancelled: true });
      }
      return;
    }
    this.onEvent(message);
  }
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
