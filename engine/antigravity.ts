import { execFile, spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { agentEnvironment } from "./acp.ts";
import { hunks, toolView, type Hunk, type View } from "./acp-map.ts";
import { lastLine } from "./shell.ts";
import { event, log } from "./wire.ts";

// A thread on Antigravity, through the user's own `agy` in print mode with stream-json both ways:
// one agy a thread, started with the thread's mode and model, a turn for each user line written
// to its stdin, and the thread's conversation id to pick it up again. agy writes an init event
// once, step_update events as a turn goes, and a result event to end each turn. Print mode asks
// nothing: a tool the mode doesn't allow is refused and named in the result's denied_actions.
// A failed turn ends with an ERROR result or an `AGY_ERROR: {...}` line on stderr.
//
// agy picks its route at startup from `modelProvider` in its own settings.json, which the user
// sets: "gemini" runs on the Gemini API with GEMINI_API_KEY from agy's environment, anything else
// on the Google account agy signed into, which Google keeps to its own apps.

/// How to run the user's agy, and what goes before its arguments, which is how the tests run a
/// stand-in under node. `launch` gives the environment a new agy starts with, the Gemini key when
/// agy is on its API, and throws the reason when agy may not start at all.
export type AntigravityBinary = { command: string; args?: string[]; env?: Record<string, string>; launch?: () => Promise<Record<string, string>> };

export type AntigravitySendParams = {
  threadId: string;
  sessionId?: string;
  cwd: string;
  text: string;
  model?: string;
  permissionMode?: string;
  id?: string;
};

type Usage = { input_tokens?: number; output_tokens?: number; thinking_tokens?: number; cache_read_tokens?: number };

type ToolInfo = { name?: string; parameters?: Record<string, any>; output?: unknown; error?: { type?: string; message?: string } };

type Step = {
  conversation_id?: string;
  step_index: number;
  state: "ACTIVE" | "DONE" | string;
  step_type: string;
  tool_name?: string;
  text_delta?: string;
  thinking_delta?: string;
  tool_info?: ToolInfo;
  subagent_info?: unknown;
};

type Result = { conversation_id?: string; status: string; response?: string; error?: string; usage?: Usage; denied_actions?: unknown[] };

type Call = { id: string; name: string; input: Record<string, any>; path?: string; before?: Promise<string | null> };

const install = "Antigravity isn't installed. Install it with `curl -fsSL https://antigravity.google/cli/install.sh | bash`.";

/// agy's own settings, where the user chooses the Gemini API over a Google account.
export const settingsFile = join(homedir(), ".gemini/antigravity-cli/settings.json");

/// agy's tools as K-175's kinds, by the names its stream gives them. The rest are other.
const kinds: Record<string, string> = {
  run_command: "run",
  view_file: "read",
  view_file_outline: "read",
  view_code_item: "read",
  list_dir: "list",
  grep_search: "search",
  find_by_name: "search",
  codebase_search: "search",
  write_to_file: "write",
  replace_file_content: "edit",
  multi_replace_file_content: "edit",
  edit_file: "edit",
  code_action: "edit",
  delete_file: "delete",
  read_url_content: "fetch",
  search_web: "web",
  browser_subagent: "agent",
  ask_question: "question",
};

/// Which route the user's agy starts on: the Gemini API when its settings say `modelProvider:
/// "gemini"`, else the Google account. Only that one setting is taken from the file, which holds
/// no credential: agy reads its Gemini key from the environment alone and keeps a Google login in
/// the Keychain.
export async function route(file = settingsFile): Promise<"gemini" | "google"> {
  try {
    return JSON.parse(await readFile(file, "utf8"))?.modelProvider === "gemini" ? "gemini" : "google";
  } catch {
    return "google";
  }
}

/// A thread's mode as agy's flags. Default is agy's own request-review, which print mode can't
/// ask in, so a command is refused unless the user's settings allow it.
export function modeFlags(mode: string | undefined): string[] {
  switch (mode) {
    case "acceptEdits":
      return ["--mode", "accept-edits"];
    case "plan":
      return ["--mode", "plan"];
    default:
      return [];
  }
}

/// The session a thread on Antigravity talks to, one agy process while it's in use. It implements
/// provider.ts's Session.
export class AntigravitySession {
  readonly id: string;
  private binary: AntigravityBinary;
  private child: ChildProcessWithoutNullStreams | undefined;
  private stderr = "";
  /// What the running agy was started with: its mode, model, folder and environment. A turn that
  /// needs another starts a new agy on the same conversation.
  private startedWith = "";
  /// The conversation asked for when the running agy started, which its init may not keep.
  private resuming: string | undefined;
  private sessionId: string | undefined;
  private mode: string | undefined;
  private running = false;
  private interrupted = false;
  private errored = false;
  /// Waiting for agy's init to say the conversation, which the turn's start carries.
  private announce = false;
  /// Counts the agy processes started, since each counts its steps from its own start.
  private starts = 0;
  private turnStart = 0;
  private idleSince: number | undefined;
  private calls = new Map<number, Call>();
  /// agy's usage in a result counts the whole process's turns; the last one's is taken from it.
  private counted: Required<Usage> = { input_tokens: 0, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0 };
  /// agy's lines, handled one after another, since an edit's result waits on reading the file.
  private work: Promise<void> = Promise.resolve();
  /// Sent during a turn: agy takes the next prompt only once a turn's result is out.
  private queued: { params: AntigravitySendParams; env: Record<string, string> }[] = [];
  onIdle: (() => void) | undefined;

  constructor(id: string, binary: AntigravityBinary = { command: "agy" }) {
    this.id = id;
    this.binary = binary;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /// A send during a turn waits for it to end, and the reply says it's waiting. A send agy may not
  /// run, on a Google account while that login is off, is refused before anything starts.
  async send(params: AntigravitySendParams): Promise<boolean> {
    if (!existsSync(params.cwd)) throw new Error(`The folder ${basename(params.cwd)} isn't where it was. Move it back, or add the project again.`);
    const env = (await this.binary.launch?.()) ?? {};
    if (this.running) {
      this.queued.push({ params, env });
      return true;
    }
    this.begin(params, env);
    return false;
  }

  /// Stop: agy is sent SIGINT, then ended if it lingers, and the next turn picks the conversation
  /// up in a new one. Every message still waiting is let go.
  async interrupt(): Promise<void> {
    if (!this.running) return;
    this.interrupted = true;
    for (const { params } of this.queued.splice(0)) {
      if (params.id) event("message.cancelled", { threadId: this.id, messageId: params.id });
    }
    if (!this.child) return;
    // It may outlive the turn by a moment, so the next turn starts another.
    this.startedWith = "";
    end(this.child, ["SIGINT", "SIGTERM", "SIGKILL"]);
  }

  /// A mode is a flag agy starts with, so it takes from the next turn, in a new agy.
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

  releaseIfIdle(idleMs: number, now = Date.now()): boolean {
    if (!this.child || this.running || this.idleSince === undefined) return false;
    if (now - this.idleSince < idleMs) return false;
    this.close();
    return true;
  }

  idleLeft(idleMs: number, now = Date.now()): number | undefined {
    if (!this.child || this.running || this.idleSince === undefined) return undefined;
    return Math.max(0, this.idleSince + idleMs - now);
  }

  /// The thread is gone, the engine is going, or agy sat idle. A turn still running ends with
  /// nothing said, as a Claude thread's does.
  close(): void {
    this.running = false;
    this.queued = [];
    this.stop();
  }

  private stop(): void {
    const child = this.child;
    this.child = undefined;
    this.idleSince = undefined;
    if (child) {
      child.stdin.end();
      end(child, ["SIGTERM", "SIGKILL"]);
    }
  }

  private begin(params: AntigravitySendParams, env: Record<string, string>): void {
    const mode = params.permissionMode ?? this.mode ?? "default";
    this.mode = mode;
    log(`send thread=${this.id} agent=antigravity model=${params.model ?? "default"} mode=${mode}`);
    this.running = true;
    this.interrupted = false;
    this.errored = false;
    this.idleSince = undefined;
    this.turnStart = Date.now();
    if (params.id) event("message.taken", { threadId: this.id, messageId: params.id, newTurn: true });
    const wanted = JSON.stringify([mode, params.model ?? null, params.cwd, env]);
    if (this.child && this.startedWith !== wanted) this.stop();
    if (!this.child) this.start(params, mode, env, wanted);
    else event("turn.started", { threadId: this.id, sessionId: this.sessionId });
    this.child!.stdin.write(JSON.stringify({ event: "user", message: { content: params.text } }) + "\n");
  }

  private start(params: AntigravitySendParams, mode: string, env: Record<string, string>, wanted: string): void {
    const resume = params.sessionId ?? this.sessionId;
    const args = [...(this.binary.args ?? []), "--input-format", "stream-json", "--output-format", "stream-json", ...modeFlags(mode)];
    if (params.model) args.push("--model", params.model);
    if (resume) args.push("--conversation", resume);
    log(`start thread=${this.id} ${this.binary.command} ${args.slice(this.binary.args?.length ?? 0).join(" ")} cwd=${params.cwd}`);
    const child = spawn(this.binary.command, args, { cwd: params.cwd, env: agentEnvironment({ ...this.binary.env, ...env }), stdio: ["pipe", "pipe", "pipe"] });
    this.child = child;
    this.starts += 1;
    this.startedWith = wanted;
    this.resuming = resume;
    this.announce = true;
    this.stderr = "";
    this.calls.clear();
    this.counted = { input_tokens: 0, output_tokens: 0, thinking_tokens: 0, cache_read_tokens: 0 };
    // Written to after it has gone, its stdin fails with EPIPE, which unheard ends the engine.
    child.stdin.on("error", () => {});
    const handle = (step: () => void | Promise<void>) => {
      this.work = this.work.then(step).catch((error) => log(`thread=${this.id} Antigravity line: ${describe(error)}`));
    };
    createInterface({ input: child.stdout }).on("line", (line) => handle(() => this.receive(child, line, params.cwd)));
    createInterface({ input: child.stderr }).on("line", (line) => {
      process.stderr.write(line + "\n");
      this.stderr = (this.stderr + line + "\n").slice(-4096);
      if (line.startsWith("AGY_ERROR:")) handle(() => this.agyError(child, line.slice("AGY_ERROR:".length)));
    });
    child.on("error", (error) => handle(() => this.exited(child, (error as NodeJS.ErrnoException).code === "ENOENT" ? install : `Couldn't start Antigravity: ${error.message}`)));
    // Once its pipes have closed, so the last of its lines and its stderr have been read.
    child.on("close", (code, signal) =>
      handle(() => this.exited(child, `Antigravity stopped${lastLine(this.stderr) ? `: ${lastLine(this.stderr)}` : signal ? ` (${signal}).` : ` (exit code ${code}).`}`)),
    );
  }

  private async receive(child: ChildProcessWithoutNullStreams, line: string, cwd: string): Promise<void> {
    if (child !== this.child) return;
    let message: { event?: string; conversation_id?: string; step_update?: Step; result?: Result };
    try {
      message = JSON.parse(line);
    } catch {
      if (line.trim()) log(`Antigravity wrote a line that isn't JSON: ${line.slice(0, 200)}`);
      return;
    }
    switch (message.event) {
      case "init":
        this.opened(message.conversation_id);
        return;
      case "step_update":
        if (message.step_update && this.running) return this.step(message.step_update, cwd);
        return;
      case "result":
        if (message.result) this.ended(message.result);
        return;
    }
  }

  /// agy's init names the conversation it opened. One asked for and not given back was lost.
  private opened(conversation: string | undefined): void {
    if (this.resuming && conversation && conversation !== this.resuming) {
      log(`conversation ${this.resuming} not resumed for thread=${this.id}`);
      event("session.lost", { threadId: this.id });
    }
    this.sessionId = conversation ?? this.sessionId;
    this.resuming = undefined;
    if (this.announce && this.running) event("turn.started", { threadId: this.id, sessionId: this.sessionId });
    this.announce = false;
  }

  private async step(step: Step, cwd: string): Promise<void> {
    if (step.thinking_delta) event("thinking", { threadId: this.id, delta: step.thinking_delta });
    const name = step.tool_info?.name ?? step.tool_name ?? (kinds[step.step_type] ? step.step_type : undefined);
    if (!name && !step.subagent_info) {
      if (step.text_delta && step.step_type !== "user_input") event("text", { threadId: this.id, delta: step.text_delta });
      return;
    }
    let call = this.calls.get(step.step_index);
    if (!call) {
      call = this.use(step, name ?? "subagent", cwd);
      this.calls.set(step.step_index, call);
    }
    if (step.state === "DONE") {
      this.calls.delete(step.step_index);
      const failed = step.tool_info?.error;
      const content = failed ? (failed.message ?? failed.type ?? "Failed.") : textOf(step.tool_info?.output);
      const patch = failed ? undefined : await patchOf(call);
      event("tool.result", { threadId: this.id, toolUseId: call.id, content, isError: Boolean(failed), patch });
    }
  }

  private use(step: Step, name: string, cwd: string): Call {
    const input = step.tool_info?.parameters ?? {};
    const call: Call = { id: `${this.sessionId ?? this.id}-${this.starts}-${step.step_index}`, name, input };
    const view = viewOf(input);
    if (view.path) view.path = resolve(cwd, view.path);
    const kind = step.subagent_info ? "agent" : (kinds[name] ?? (name.startsWith("mcp_") ? "mcp" : "other"));
    if ((kind === "edit" || kind === "write") && view.path) {
      call.path = view.path;
      // Read now, before agy writes; one read too late is rebuilt from the edit itself.
      call.before = readText(call.path);
    }
    event("tool.use", { threadId: this.id, toolUseId: call.id, name, input, kind, view });
    return call;
  }

  /// A result ends the turn. Its usage counts every turn this agy has run, so the turn's own is
  /// what it adds.
  private ended(result: Result): void {
    if (!this.running) return;
    this.sessionId = result.conversation_id || this.sessionId;
    const usage = { ...this.counted, ...result.usage };
    const spent = {
      input: Math.max(0, usage.input_tokens - usage.cache_read_tokens - (this.counted.input_tokens - this.counted.cache_read_tokens)),
      output: Math.max(0, usage.output_tokens - this.counted.output_tokens),
      cacheRead: Math.max(0, usage.cache_read_tokens - this.counted.cache_read_tokens),
      cacheWrite: 0,
    };
    this.counted = usage;
    const denied = deniedOf(result.denied_actions);
    if (denied) event("note", { threadId: this.id, text: denied });
    if (result.status === "ERROR" || result.status === "INVALID") this.fail(result.error || "Antigravity couldn't finish the turn.");
    this.finish(stopReason(result.status), spent);
  }

  /// agy's structured error, one line of JSON on stderr as it gives up on a turn.
  private agyError(child: ChildProcessWithoutNullStreams, json: string): void {
    if (child !== this.child || !this.running) return;
    let error: Record<string, unknown> = {};
    try {
      error = JSON.parse(json);
    } catch {
      log(`AGY_ERROR that isn't JSON: ${json.slice(0, 200)}`);
    }
    const said = [error.message, error.short_error, error.error, error.full_error, error.status].find((part) => typeof part === "string" && part);
    this.fail((said as string | undefined) ?? "Antigravity couldn't finish the turn.");
  }

  /// agy has gone, whether it quit, crashed, never started or was let go. A turn it was running
  /// ends as interrupted when stopped, else with why.
  private exited(child: ChildProcessWithoutNullStreams, message: string): void {
    if (child !== this.child) return;
    this.child = undefined;
    this.idleSince = undefined;
    log(`thread=${this.id} ${message}`);
    if (!this.running) return;
    if (!this.interrupted) this.fail(message);
    this.finish("error_during_execution");
  }

  private fail(message: string): void {
    if (this.errored) return;
    this.errored = true;
    event("error", { threadId: this.id, message });
  }

  private finish(reason: string, usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }): void {
    if (!this.running) return;
    this.running = false;
    const [next, ...rest] = this.queued.splice(0);
    event("turn.done", {
      threadId: this.id,
      sessionId: this.sessionId,
      stopReason: this.interrupted ? "interrupted" : reason,
      durationMs: Date.now() - this.turnStart,
      costUSD: undefined,
      usage,
      context: undefined,
      waiting: next ? rest.length + 1 : 0,
    });
    this.queued = rest;
    if (next) return this.begin(next.params, next.env);
    if (this.child) this.idleSince = Date.now();
    this.onIdle?.();
  }
}

/// A result's status as a Claude turn ends.
export function stopReason(status: string): string {
  switch (status) {
    case "SUCCESS":
      return "end_turn";
    case "CANCELED":
    case "INTERRUPTED":
      return "interrupted";
    default:
      return "error_during_execution";
  }
}

/// The arguments the app shows. agy's tools name theirs in PascalCase: TargetFile, CommandLine,
/// SearchPath, Query, Url.
export function viewOf(input: Record<string, any>): View {
  const path = [input.TargetFile, input.AbsolutePath, input.FilePath, input.File, input.DirectoryPath, input.SearchPath, input.SearchDirectory].find(
    (value) => typeof value === "string" && value,
  );
  const view: View = {
    ...toolView(input, null, null),
    ...(path ? { path } : {}),
    ...(typeof input.CommandLine === "string" ? { command: input.CommandLine } : {}),
    ...(typeof input.Query === "string" ? { pattern: input.Query } : typeof input.Pattern === "string" ? { pattern: input.Pattern } : {}),
    ...(typeof input.Url === "string" ? { url: input.Url } : {}),
  };
  return view;
}

/// What print mode refused, as a note: each action as agy names it, and where to allow it.
export function deniedOf(actions: unknown[] | undefined): string | undefined {
  const named = (actions ?? []).flatMap((action) => {
    if (typeof action === "string") return [action];
    const { name, tool, action: kind, target } = (action ?? {}) as Record<string, unknown>;
    const what = [name, tool, kind].find((part) => typeof part === "string");
    if (typeof what !== "string") return [];
    return [typeof target === "string" && target ? `${what}(${target})` : what];
  });
  if (!named.length) return undefined;
  return `Antigravity turned down ${named.join(", ")}, since it can't ask in print mode. An allow rule under permissions.allow in ~/.gemini/antigravity-cli/settings.json lets ${named.length === 1 ? "it" : "them"} through.`;
}

/// An edit's or a write's hunks, from the file before it and after. A before read after agy had
/// written reads the same as after, and a replacement is then put back to see what it changed.
async function patchOf(call: Call): Promise<Hunk[] | undefined> {
  if (!call.path || !call.before) return undefined;
  const before = await call.before;
  const after = call.name === "write_to_file" && typeof call.input.CodeContent === "string" ? call.input.CodeContent : await readText(call.path);
  if (after === null) return undefined;
  if (before !== after) return hunks(before, after);
  const undone = undo(after, call.input);
  return undone === undefined || undone === after ? undefined : hunks(undone, after);
}

/// The file before a replacement agy has already made: each chunk's new text put back to its old.
export function undo(after: string, input: Record<string, any>): string | undefined {
  const chunks: unknown[] = Array.isArray(input.ReplacementChunks) ? input.ReplacementChunks : [input];
  let text = after;
  let changed = false;
  for (const chunk of chunks) {
    const { TargetContent: old, ReplacementContent: now, AllowMultiple: every } = (chunk ?? {}) as Record<string, unknown>;
    if (typeof old !== "string" || typeof now !== "string" || now === "") continue;
    text = every === true ? text.replaceAll(now, () => old) : text.replace(now, () => old);
    changed = true;
  }
  return changed ? text : undefined;
}

function readText(path: string): Promise<string | null> {
  return readFile(path, "utf8").catch(() => null);
}

function textOf(output: unknown): string {
  if (typeof output === "string") return output;
  if (output === undefined || output === null) return "";
  return JSON.stringify(output);
}

/// Sends each signal in turn, two seconds apart, until the process has gone.
function end(child: ChildProcess, signals: NodeJS.Signals[]): void {
  const [signal, ...rest] = signals;
  if (!signal || child.exitCode !== null || child.signalCode !== null) return;
  child.kill(signal);
  if (rest.length) setTimeout(() => end(child, rest), 2000).unref();
}

export type AntigravityModel = { id: string; name: string };

/// What `agy models` says, which is as far as agy can be asked without a prompt: the models its
/// route offers, or the error it met, which it prints with exit 0. It asks Google with whichever
/// route agy is on, so it runs only where that route may.
export function parseModels(output: string): { models: AntigravityModel[]; error: string | null } {
  const models: AntigravityModel[] = [];
  for (const raw of output.split("\n")) {
    const line = raw.trim();
    const failed = /^Error:\s*(.+)$/.exec(line);
    if (failed) return { models, error: failed[1] };
    // Slugs are lower case, which keeps out agy's "Fetching available models..." line.
    const row = /^([a-z0-9][a-z0-9._:/-]*)\s+(\S.*)$/.exec(line);
    if (row) models.push({ id: row[1], name: row[2] });
  }
  return { models, error: null };
}

export type AntigravityCheck = { state: "ready" | "signedOut" | "missing" | "unknown"; version: string | null; hint: string | null; models: AntigravityModel[] };

/// Whether the user's agy can run a thread: its version, and `agy models` on the route it's on.
/// Models listed is ready; an error is its words; nothing either way is unknown.
export async function check(binary: AntigravityBinary, env: Record<string, string>): Promise<AntigravityCheck> {
  const ask = (args: string[], timeout: number) =>
    new Promise<{ stdout: string; missing: boolean; failed: boolean }>((done) =>
      execFile(binary.command, [...(binary.args ?? []), ...args], { env: agentEnvironment({ ...binary.env, ...env }), timeout }, (error, stdout) =>
        done({ stdout: stdout ?? "", missing: (error as NodeJS.ErrnoException | null)?.code === "ENOENT", failed: error !== null }),
      ),
    );
  const [version, listed] = await Promise.all([ask(["--version"], 5000), ask(["models"], 20_000)]);
  if (version.missing) return { state: "missing", version: null, hint: install, models: [] };
  const said = version.failed ? null : version.stdout.trim().split("\n")[0] || null;
  const { models, error } = parseModels(listed.stdout);
  if (error) return { state: "signedOut", version: said, hint: error, models: [] };
  if (models.length) return { state: "ready", version: said, hint: null, models };
  return { state: "unknown", version: said, hint: null, models: [] };
}

function describe(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
