import { execFile, spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, resolve } from "node:path";
import { createInterface } from "node:readline";
import { agentEnvironment } from "./acp.ts";
import { hunks, toolView, type Hunk, type Todo, type View } from "./acp-map.ts";
import { lastLine } from "./shell.ts";
import { event, log } from "./wire.ts";

// A thread on Command Code, through the user's own `cmd` in headless mode: each turn is one
// `cmd -p --output-format json` in the thread's folder, its prompt on stdin, resuming the thread's
// session after the first. cmd prints a JSON object a line, an event frame for each of its
// AgentEvents and one result frame last. Headless, cmd asks nothing and takes nothing mid-turn:
// what the thread's mode doesn't allow is refused, and the rest runs unsupervised. Its sessions
// stay in cmd's own store, tagged headless, hidden from its interactive /resume, and
// `cmd --resume <id>` opens one in Terminal. The API key reaches it as COMMAND_CODE_API_KEY in
// the binary's env, which cmd prefers to a login of its own.

/// How to run the user's cmd, and what goes before its arguments, which is how the tests run a
/// stand-in under node.
export type CommandCodeBinary = { command: string; args?: string[]; env?: Record<string, string> };

export type CommandCodeSendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  model?: string;
  effort?: string;
  permissionMode?: string;
  id?: string;
};

type Usage = { inputTokens: number; outputTokens: number; cacheReadTokens: number; cacheWriteTokens: number };

type AgentEvent = { type: string; [field: string]: any };

type Result = { type: "result"; subtype: string; sessionId?: string; stopReason?: string; usage: Usage; durationMs: number; finalText: string; error?: string };

type Call = { name: string; input: Record<string, any>; path?: string; before?: Promise<string | null> };

const install = "Command Code isn't installed. Install it with `npm i -g command-code`.";

const noKey = "Command Code has no working API key. Add yours in Settings › Agents.";

/// The tools of cmd 1.66.0 as K-175's kinds. The rest are MCP's or other.
const kinds: Record<string, string> = {
  read_file: "read",
  read_directory: "list",
  glob: "search",
  grep: "search",
  edit_file: "edit",
  write_file: "write",
  shell_command: "run",
  monitor_command: "run",
  kill_shell: "run",
  web_fetch: "fetch",
  web_search: "web",
  todo_write: "plan",
  agent: "agent",
  ask_user_question: "question",
  enter_plan_mode: "planning",
  exit_plan_mode: "planning",
};

/// A thread's mode as cmd's flags. Headless, cmd refuses every edit, write and command unless it
/// was started with --yolo, whatever its permission mode, and anything its mode would have asked
/// about runs, since no one is there to ask, except what it holds too risky, which is refused and
/// ends the turn. So Ask is dont-ask: reads and searches and the user's allow rules, everything
/// else refused. Accept edits and Auto can't edit or run a command either, and run MCP tools and
/// fetches unasked. Plan reads. Don't ask is --yolo, the only mode that writes: everything but the
/// user's deny rules and what cmd holds too risky.
export function modeFlags(mode: string | undefined): string[] {
  switch (mode) {
    case "acceptEdits":
      return ["--permission-mode", "accept-edits"];
    case "auto":
      return ["--permission-mode", "default"];
    case "plan":
      return ["--permission-mode", "plan"];
    case "bypassPermissions":
      return ["--yolo"];
    default:
      return ["--permission-mode", "dont-ask"];
  }
}

/// The session a thread on Command Code talks to, one cmd process per turn. It implements
/// provider.ts's Session once it's wired.
export class CommandCodeSession {
  readonly id: string;
  private binary: CommandCodeBinary;
  /// The running turn's cmd, until its result or its exit.
  private child: ChildProcessWithoutNullStreams | undefined;
  private stderr = "";
  private sessionId: string | undefined;
  private mode: string | undefined;
  private running = false;
  private interrupted = false;
  private errored = false;
  /// Counts turns, so what a finished one leaves behind can't reach the next.
  private turns = 0;
  private turnStart = 0;
  private calls = new Map<string, Call>();
  private spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  /// cmd's lines, handled one after another, since an edit's result waits on reading the file.
  private work: Promise<void> = Promise.resolve();
  /// Sent during a turn: cmd takes nothing mid-turn, so each runs as a turn of its own.
  private queued: CommandCodeSendParams[] = [];
  onIdle: (() => void) | undefined;

  constructor(id: string, binary: CommandCodeBinary = { command: "cmd" }) {
    this.id = id;
    this.binary = binary;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// A send during a turn waits for it to end, and the reply says it's waiting.
  async send(params: CommandCodeSendParams): Promise<boolean> {
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    if (this.running) {
      this.queued.push(params);
      return true;
    }
    this.begin(params);
    return false;
  }

  /// Stop: cmd is sent SIGINT, which it answers by exiting with no result, and every message
  /// still waiting is let go.
  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.interrupted = true;
    for (const params of this.queued.splice(0)) {
      if (params.id) event("message.cancelled", { threadId: this.id, messageId: params.id });
    }
    if (this.child) end(this.child, ["SIGINT", "SIGTERM", "SIGKILL"]);
  }

  /// A mode is a flag each turn's cmd starts with, so it can't reach the running one.
  async setMode(mode: string): Promise<boolean> {
    this.mode = mode;
    return !this.running;
  }

  async setFast(_fast: boolean): Promise<boolean> {
    return false;
  }

  watchHeads(_on: boolean): void {}

  async stopTask(_taskId: string): Promise<void> {}

  async commands(): Promise<{ name: string; description: string; argumentHint: string }[] | undefined> {
    return undefined;
  }

  /// No cmd outlives its turn, so there's nothing to release.
  releaseIfIdle(_idleMs: number, _now = Date.now()): boolean {
    return false;
  }

  idleLeft(_idleMs: number, _now = Date.now()): number | undefined {
    return undefined;
  }

  /// The thread is gone or the engine is going. A turn still running ends with nothing said, as
  /// a Claude thread's does.
  close(): void {
    this.running = false;
    this.queued = [];
    const child = this.child;
    this.child = undefined;
    if (child) end(child, ["SIGTERM", "SIGKILL"]);
  }

  private begin(params: CommandCodeSendParams): void {
    log(`send thread=${this.id} agent=commandcode model=${params.model ?? "default"} effort=${params.effort ?? "default"} mode=${params.permissionMode ?? "default"}`);
    this.running = true;
    this.interrupted = false;
    this.errored = false;
    this.turnStart = Date.now();
    this.calls.clear();
    this.spent = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
    const turn = ++this.turns;
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    this.run(params, turn, params.sessionId ?? this.sessionId);
  }

  private run(params: CommandCodeSendParams, turn: number, resume: string | undefined): void {
    const mode = params.permissionMode ?? this.mode ?? "default";
    this.mode = mode;
    // todo_write is withheld from headless runs unless asked for, and it's how cmd shows a plan.
    const args = [...(this.binary.args ?? []), "-p", "--output-format", "json", ...modeFlags(mode), "--tools-enable", "todo_write"];
    if (params.model) args.push("--model", params.model);
    if (params.effort) args.push("--effort", params.effort);
    if (resume) args.push("--resume", resume);
    log(`start thread=${this.id} ${this.binary.command} ${args.slice(this.binary.args?.length ?? 0).join(" ")} cwd=${params.cwd}`);
    const child = spawn(this.binary.command, args, { cwd: params.cwd, env: agentEnvironment(this.binary.env), stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.stderr = "";
    // Written to after it has gone, its stdin fails with EPIPE, which unheard ends the engine.
    child.stdin.on("error", () => {});
    // On stdin, a prompt that starts with a dash can't be read as a flag.
    child.stdin.end(params.text);
    child.stderr.on("data", (chunk: Buffer) => {
      process.stderr.write(chunk);
      this.stderr = (this.stderr + chunk.toString("utf8")).slice(-4096);
    });
    const handle = (step: () => void | Promise<void>) => {
      this.work = this.work.then(step).catch((error) => log(`thread=${this.id} Command Code line: ${describe(error)}`));
    };
    createInterface({ input: child.stdout }).on("line", (line) => handle(() => this.receive(child, line, params, turn, resume)));
    child.on("error", (error) => handle(() => this.exited(child, turn, (error as NodeJS.ErrnoException).code === "ENOENT" ? install : `Couldn't start Command Code: ${error.message}`)));
    // Once its pipes have closed, so the last of its lines and its stderr have been read.
    child.on("close", (code, signal) =>
      handle(() => this.exited(child, turn, `Command Code stopped${lastLine(this.stderr) ? `: ${lastLine(this.stderr)}` : signal ? ` (${signal}).` : ` (exit code ${code}).`}`)),
    );
  }

  private async receive(child: ChildProcessWithoutNullStreams, line: string, params: CommandCodeSendParams, turn: number, resume: string | undefined): Promise<void> {
    if (child !== this.child || turn !== this.turns) return;
    let frame: { type: "event"; event: AgentEvent } | Result;
    try {
      frame = JSON.parse(line);
    } catch {
      if (line.trim()) log(`Command Code wrote a line that isn't JSON: ${line.slice(0, 200)}`);
      return;
    }
    if (frame.type === "event") return this.told(frame.event, params.cwd);
    if (frame.type === "result") this.ended(frame, params, turn, resume);
  }

  private async told(agentEvent: AgentEvent, cwd: string): Promise<void> {
    switch (agentEvent.type) {
      case "run_start":
        this.sessionId = agentEvent.sessionId ?? this.sessionId;
        event("turn.started", { threadId: this.id, sessionId: this.sessionId });
        return;
      case "text_delta":
        event("text", { threadId: this.id, delta: agentEvent.delta });
        return;
      case "thinking_delta":
        event("thinking", { threadId: this.id, delta: agentEvent.delta });
        return;
      case "model_request_end": {
        // cmd counts cached input inside its input, which Claude's usage keeps apart.
        const usage: Usage = agentEvent.usage;
        this.spent.input += Math.max(0, usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens);
        this.spent.output += usage.outputTokens;
        this.spent.cacheRead += usage.cacheReadTokens;
        this.spent.cacheWrite += usage.cacheWriteTokens;
        return;
      }
      case "tool_queued":
        return this.use(agentEvent.toolCallId, agentEvent.toolName, agentEvent.input ?? {}, cwd);
      case "tool_completed":
        return this.result(agentEvent.toolCallId, textOf(agentEvent.result), false);
      case "tool_errored":
        return this.result(agentEvent.toolCallId, String(agentEvent.error ?? ""), true);
      case "tool_hook_blocked":
        // Headless cmd's own gate on edits, writes and commands says so here, naming --yolo.
        return this.result(agentEvent.toolCallId, String(agentEvent.hookOutput ?? ""), true);
      case "tool_denied":
        return this.result(agentEvent.toolCallId, "Refused in this thread's mode.", true);
    }
  }

  private use(id: string, name: string, input: Record<string, any>, cwd: string): void {
    const call: Call = { name, input };
    this.calls.set(id, call);
    if (name === "todo_write") {
      const list = todosOf(input.todos);
      event("tool.use", { threadId: this.id, toolUseId: id, name: "TodoWrite", input: { todos: list }, kind: "plan", view: { todos: list } });
      return;
    }
    if (name === "edit_file" || name === "write_file") {
      const path = input.file_path ?? input.path;
      if (typeof path === "string") {
        call.path = resolve(cwd, path);
        // Read now, before cmd gets to it; one read too late is rebuilt from the edit itself.
        call.before = readText(call.path);
      }
    }
    event("tool.use", { threadId: this.id, toolUseId: id, name, input, kind: kinds[name] ?? (name.startsWith("mcp__") ? "mcp" : "other"), view: viewOf(name, input) });
  }

  private async result(id: string, content: string, isError: boolean): Promise<void> {
    const call = this.calls.get(id);
    const patch = call && !isError ? await patchOf(call) : undefined;
    event("tool.result", { threadId: this.id, toolUseId: id, content, isError, patch });
  }

  /// The result frame ends the turn. It's written once cmd has saved the session, so the next
  /// turn's --resume finds all of it.
  private ended(result: Result, params: CommandCodeSendParams, turn: number, resume: string | undefined): void {
    this.child = undefined;
    if (result.sessionId) this.sessionId = result.sessionId;
    const error = (result.error ?? "").replace(/^Error:\s*/, "");
    if (result.subtype === "error" && resume && /^No session ".*" found to resume\.?$/.test(error)) {
      log(`session ${resume} not resumed for thread=${this.id}: ${error}`);
      event("session.lost", { threadId: this.id });
      this.sessionId = undefined;
      return this.run(params, turn, undefined);
    }
    if (result.subtype === "error") this.fail(/Not authenticated|Authentication failed/.test(error) ? noKey : error || "Command Code couldn't finish the turn.");
    if (result.stopReason === "permission_denied") this.fail("Command Code stopped at a call it holds too risky to make unasked.");
    this.finish(turn, stopReason(result));
  }

  /// cmd has gone, whether it quit, crashed or never started. One stopped ends as interrupted,
  /// any other with why.
  private exited(child: ChildProcessWithoutNullStreams, turn: number, message: string): void {
    if (child !== this.child) return;
    this.child = undefined;
    log(`thread=${this.id} ${message}`);
    if (turn !== this.turns || !this.running) return;
    if (!this.interrupted) this.fail(message);
    this.finish(turn, "error_during_execution");
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  private finish(turn: number, reason: string): void {
    if (turn !== this.turns || !this.running) return;
    this.running = false;
    const [next, ...rest] = this.queued.splice(0);
    event("turn.done", {
      threadId: this.id,
      sessionId: this.sessionId,
      stopReason: this.interrupted ? "interrupted" : reason,
      durationMs: Date.now() - this.turnStart,
      costUSD: undefined,
      usage: this.spent,
      context: undefined,
      waiting: next ? rest.length + 1 : 0,
    });
    this.queued = rest;
    if (next) this.begin(next);
    else this.onIdle?.();
  }
}

/// A result frame's end as a Claude turn's. A run cut off at cmd's limit on model requests
/// didn't end by itself, so it's an error, and so is one ended on a refused call.
export function stopReason(result: { subtype: string; stopReason?: string }): string {
  if (result.subtype === "error") return "error_during_execution";
  if (result.subtype === "max_turns") return "error_max_turns";
  switch (result.stopReason) {
    case "interrupted":
    case "max_tokens":
      return result.stopReason;
    case "max_turns":
      return "error_max_turns";
    case "permission_denied":
    case "run_error":
      return "error_during_execution";
    default:
      return "end_turn";
  }
}

/// The arguments the app shows. cmd's shell takes its arguments apart from the command, and its
/// read takes a list of paths beside a single one.
export function viewOf(name: string, input: Record<string, any>): View {
  if (name === "shell_command" && typeof input.command === "string") {
    const args = Array.isArray(input.args) ? input.args.filter((arg: unknown) => typeof arg === "string") : [];
    return { command: [input.command, ...args].join(" ") };
  }
  if (name === "read_file" && !input.file_path && Array.isArray(input.paths) && typeof input.paths[0] === "string") return { path: input.paths[0] };
  return toolView(input, null, null);
}

function todosOf(todos: unknown): Todo[] {
  if (!Array.isArray(todos)) return [];
  return todos.map((todo: { content?: string; activeForm?: string; status?: string }) => ({
    content: todo.content ?? "",
    activeForm: todo.activeForm || todo.content || "",
    status: todo.status === "in_progress" || todo.status === "completed" ? todo.status : "pending",
  }));
}

/// An edit's or a write's hunks, from the file before it and after. A before read after cmd had
/// written reads the same as after, and an edit's is then its new string put back to its old.
async function patchOf(call: Call): Promise<Hunk[] | undefined> {
  if (!call.path || !call.before) return undefined;
  const before = await call.before;
  const after = call.name === "write_file" && typeof call.input.content === "string" ? call.input.content : await readText(call.path);
  if (after === null) return undefined;
  if (before !== after) return hunks(before, after);
  const undone = undo(after, call.input);
  return undone === undefined || undone === after ? undefined : hunks(undone, after);
}

export function undo(after: string, input: { old_string?: unknown; new_string?: unknown; replace_all?: unknown }): string | undefined {
  const { old_string: old, new_string: now } = input;
  if (typeof old !== "string" || typeof now !== "string" || now === "") return undefined;
  return input.replace_all === true ? after.replaceAll(now, () => old) : after.replace(now, () => old);
}

function readText(path: string): Promise<string | null> {
  return readFile(path, "utf8").catch(() => null);
}

function textOf(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap((block: { type?: string; text?: string }) => (block.type === "text" && block.text ? [block.text] : [])).join("\n");
}

/// Sends each signal in turn, two seconds apart, until the process has gone. cmd exits on
/// SIGINT or SIGTERM once its mods are torn down; SIGKILL is for one that doesn't, which would
/// otherwise hold its memory for good.
function end(child: ChildProcess, signals: NodeJS.Signals[]): void {
  const [signal, ...rest] = signals;
  if (!signal || child.exitCode !== null || child.signalCode !== null) return;
  child.kill(signal);
  if (rest.length) setTimeout(() => end(child, rest), 2000).unref();
}

export type CommandCodeAvailability = { state: "ready" | "signedOut" | "missing"; version: string | null; hint: string | null };

/// Whether the user's cmd is there and has a key, as `cmd status --json` says, which reads only
/// cmd's own env and login and reaches no server. A key in the env counts without being checked.
export async function availability(binary: CommandCodeBinary = { command: "cmd" }): Promise<CommandCodeAvailability> {
  return new Promise((resolve) => {
    execFile(binary.command, [...(binary.args ?? []), "status", "--json"], { env: agentEnvironment(binary.env), timeout: 10_000 }, (error, stdout) => {
      if ((error as NodeJS.ErrnoException | null)?.code === "ENOENT") return resolve({ state: "missing", version: null, hint: install });
      let status: { authenticated?: boolean; version?: string; error?: string } = {};
      try {
        status = JSON.parse(stdout);
      } catch {
        log(`cmd status wrote what isn't JSON: ${stdout.slice(0, 200)}`);
      }
      const version = status.version ?? null;
      if (status.authenticated && !status.error) return resolve({ state: "ready", version, hint: null });
      resolve({ state: "signedOut", version, hint: status.error ?? noKey });
    });
  });
}

export type CommandCodeModel = { id: string; description: string; group: string; isDefault: boolean };

/// The models the user's cmd offers, from `cmd --list-models`, which has no JSON form: a heading
/// for each maker, then a line for each model, its id and two or more spaces before what it's
/// for. The decision models listed after them answer only typed questions, and are left out.
export async function listModels(binary: CommandCodeBinary = { command: "cmd" }): Promise<CommandCodeModel[]> {
  const stdout = await new Promise<string>((resolve, reject) => {
    execFile(binary.command, [...(binary.args ?? []), "--list-models"], { env: agentEnvironment({ NO_COLOR: "1", ...binary.env }), timeout: 20_000 }, (error, stdout) =>
      error ? reject(error) : resolve(stdout),
    );
  });
  return parseModels(stdout);
}

export function parseModels(text: string): CommandCodeModel[] {
  const models: CommandCodeModel[] = [];
  let group = "";
  for (const line of text.split("\n")) {
    if (line.startsWith("Pass the full id")) break;
    const row = /^(\S+)\s{2,}(.*)$/.exec(line);
    if (row) {
      const isDefault = /\s*\(default\)$/.test(row[2]);
      models.push({ id: row[1], description: row[2].replace(/\s*\(default\)$/, ""), group, isDefault });
    } else if (line.trim() && !line.startsWith("Available models")) {
      group = line.trim();
    }
  }
  return models;
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
