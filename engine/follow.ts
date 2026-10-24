import { existsSync, readdirSync, watch, type FSWatcher } from "node:fs";
import { open, type FileHandle } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { messageEvents, type Transcript } from "./sessions.ts";
import { event } from "./wire.ts";

// A workflow agent's or a Task subagent's transcript, which Claude Code writes to disk, read while
// the app shows that agent: its thread, what's there past what the app has stored, then each line
// as the CLI appends it; or its card on the stage, only its last calls. A watcher on the file says
// when; nothing polls, and an agent nobody is looking at is never read.

/// The most events one `agent.lines` carries, so a long transcript comes in pieces.
const batch = 200;

/// A transcript watched, or until the agent's first line is written its folder, and read through
/// one pass at a time: a change that comes during a pass is read in the next.
abstract class Watched {
  readonly threadId: string;
  readonly path: string;
  private watcher: FSWatcher | undefined;
  private reading = false;
  private again = false;
  private ending = false;
  protected stopped = false;

  constructor(threadId: string, path: string) {
    this.threadId = threadId;
    this.path = path;
  }

  start(): void {
    this.watchFile();
    void this.read();
  }

  stop(): void {
    this.stopped = true;
    this.watcher?.close();
    this.watcher = undefined;
  }

  /// The agent is over: what it wrote last is read, then the follow stops.
  end(): void {
    this.ending = true;
    void this.read();
  }

  protected abstract pass(): Promise<void>;
  protected abstract gone(): void;
  protected ended(): void {}

  private watchFile(): void {
    if (this.stopped) return;
    try {
      this.watcher = watch(this.path, () => void this.read());
    } catch {
      try {
        this.watcher = watch(dirname(this.path), (_, name) => {
          if (name !== basename(this.path)) return;
          this.watcher?.close();
          this.watchFile();
          void this.read();
        });
      } catch {
        // The run's folder is gone, with Claude Code's copy of the session.
        this.gone();
        return;
      }
    }
    this.watcher.on("error", () => {
      this.watcher?.close();
      this.watcher = undefined;
    });
  }

  private async read(): Promise<void> {
    if (this.stopped) return;
    if (this.reading) {
      this.again = true;
      return;
    }
    this.reading = true;
    try {
      await this.pass();
    } finally {
      this.reading = false;
      if (this.again) {
        this.again = false;
        void this.read();
      } else if (this.ending && !this.stopped) {
        this.stop();
        this.ended();
      }
    }
  }
}

export class Follow extends Watched {
  private offset: number;

  constructor(threadId: string, path: string, from: number) {
    super(threadId, path);
    this.offset = from;
  }

  protected gone(): void {
    event("agent.lines", { threadId: this.threadId, from: this.offset, offset: this.offset, events: [], gone: true });
  }

  /// Every whole line past the offset; a line the CLI is still writing waits for the next read.
  protected async pass(): Promise<void> {
    const file = await open(this.path).catch(() => undefined);
    if (!file) return;
    let buffer: Buffer;
    const base = this.offset;
    try {
      const { size } = await file.stat();
      if (size <= base) return;
      buffer = Buffer.alloc(size - base);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, base);
      buffer = buffer.subarray(0, bytesRead);
    } finally {
      await file.close();
    }
    if (this.stopped) return;
    let from = base;
    let start = 0;
    let pending: Transcript = [];
    const whole = buffer.lastIndexOf(10) + 1;
    for (let end = buffer.indexOf(10); end !== -1; end = buffer.indexOf(10, start)) {
      pending.push(...lineEvents(buffer.subarray(start, end).toString("utf8")));
      start = end + 1;
      if (pending.length >= batch) {
        this.send(from, base + start, pending, start < whole);
        from = base + start;
        pending = [];
      }
    }
    if (base + start > from) this.send(from, base + start, pending);
    this.offset = base + start;
  }

  /// `from` lets the app take a piece only where its copy ends, so one read twice is dropped;
  /// `more` says another piece of the same read follows, which the app holds until the last.
  private send(from: number, offset: number, events: Transcript, more = false): void {
    event("agent.lines", { threadId: this.threadId, from, offset, events, ...(more ? { more } : {}) });
  }
}

/// The calls a card's trail shows, the latest last.
const trail = 4;
/// How much of a transcript is read at a time, from its end back to its last calls.
const piece = 64 * 1024;

export type AgentStep = { tool: string; input: Record<string, unknown> };

/// A card's trail on the stage: an agent's last four calls, from the end of its transcript and
/// then as the CLI appends, and with the first of them its task, its first user line unframed.
/// It keeps those four and nothing else.
export class Steps extends Watched {
  /// Where the next read starts; -1 until the file's end has been read back from.
  private offset = -1;
  private steps: AgentStep[] = [];
  private task: string | null = null;
  private taskTold = false;

  protected gone(): void {
    this.end();
  }

  protected ended(): void {
    if (trails.get(this.threadId) === this) trails.delete(this.threadId);
    event("agent.steps", { threadId: this.threadId, steps: this.steps, ended: true });
  }

  protected async pass(): Promise<void> {
    const file = await open(this.path).catch(() => undefined);
    if (!file) return;
    let fresh: AgentStep[];
    try {
      const { size } = await file.stat();
      if (this.task === null) this.task = await firstTask(file, size);
      if (this.offset < 0) {
        fresh = await this.back(file, size);
      } else {
        if (size <= this.offset) return;
        const buffer = Buffer.alloc(size - this.offset);
        const { bytesRead } = await file.read(buffer, 0, buffer.length, this.offset);
        const whole = buffer.subarray(0, bytesRead).lastIndexOf(10) + 1;
        fresh = calls(buffer.subarray(0, whole));
        this.offset += whole;
      }
    } finally {
      await file.close();
    }
    const task = this.taskTold ? null : this.task;
    if (this.stopped || (fresh.length === 0 && task === null)) return;
    this.steps = [...this.steps, ...fresh].slice(-trail);
    event("agent.steps", { threadId: this.threadId, steps: this.steps, ...(task === null ? {} : { task }) });
    if (task !== null) this.taskTold = true;
  }

  /// The last four calls, read back from the last whole line a piece at a time.
  private async back(file: FileHandle, size: number): Promise<AgentStep[]> {
    let found: AgentStep[] = [];
    let at = size;
    let rest = Buffer.alloc(0);
    while (at > 0 && found.length < trail) {
      const start = Math.max(0, at - piece);
      const buffer = Buffer.alloc(at - start);
      await file.read(buffer, 0, buffer.length, start);
      let chunk = Buffer.concat([buffer, rest]);
      if (this.offset < 0) {
        const whole = chunk.lastIndexOf(10) + 1;
        if (whole === 0 && start > 0) {
          rest = chunk;
          at = start;
          continue;
        }
        this.offset = start + whole;
        chunk = chunk.subarray(0, whole);
      }
      // The first line of a piece may begin in the piece before.
      const first = start === 0 ? 0 : chunk.indexOf(10) + 1;
      found = [...calls(chunk.subarray(first)), ...found];
      rest = chunk.subarray(0, first);
      at = start;
    }
    if (this.offset < 0) this.offset = 0;
    return found.slice(-trail);
  }
}

/// The calls in whole lines, in order. Only an agent's own lines name a tool_use, so the rest,
/// its tool results above all, are passed over without being parsed.
function calls(lines: Buffer): AgentStep[] {
  const found: AgentStep[] = [];
  for (const line of lines.toString("utf8").split("\n")) {
    if (!line.includes('"type":"tool_use"')) continue;
    let record: { type?: string; message?: { content?: unknown } };
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (record.type !== "assistant" || !Array.isArray(record.message?.content)) continue;
    for (const block of record.message.content as { type?: string; name?: string; input?: unknown }[]) {
      if (block.type === "tool_use" && typeof block.name === "string") found.push({ tool: block.name, input: brief(block.input) });
    }
  }
  return found;
}

/// A call's input as a trail needs it: what it was given in words and numbers, each word cut at 200.
function brief(input: unknown): Record<string, unknown> {
  const kept: Record<string, unknown> = {};
  if (typeof input !== "object" || input === null) return kept;
  for (const [key, value] of Object.entries(input)) {
    if (typeof value === "string") kept[key] = value.slice(0, 200);
    else if (typeof value === "number" || typeof value === "boolean") kept[key] = value;
  }
  return kept;
}

/// The agent's task: its first user line, read from the start until that line is whole, in its
/// first megabyte.
async function firstTask(file: FileHandle, size: number): Promise<string | null> {
  let read = Buffer.alloc(0);
  while (read.length < Math.min(size, 16 * piece)) {
    const buffer = Buffer.alloc(Math.min(piece, size - read.length));
    const { bytesRead } = await file.read(buffer, 0, buffer.length, read.length);
    if (bytesRead === 0) break;
    read = Buffer.concat([read, buffer.subarray(0, bytesRead)]);
    let start = 0;
    for (let end = read.indexOf(10); end !== -1; end = read.indexOf(10, start)) {
      const told = lineEvents(read.subarray(start, end).toString("utf8")).find((told) => told.event === "user");
      if (told) return typeof told.text === "string" ? told.text : null;
      start = end + 1;
    }
  }
  return null;
}

/// The trails followed, one an agent's thread.
const trails = new Map<string, Steps>();

/// A card came on the stage, or left it. A trail already followed for the thread goes on.
export function followSteps(threadId: string, path: string, on: boolean): void {
  const following = trails.get(threadId);
  if (on && following?.path === path) return;
  following?.stop();
  trails.delete(threadId);
  if (!on) return;
  const steps = new Steps(threadId, path);
  trails.set(threadId, steps);
  steps.start();
}

/// An agent is over, or with `folder` every agent of a run: their trails read what's left and end.
export function stepsEnded(path: string, folder = false): void {
  for (const steps of trails.values()) if (folder ? dirname(steps.path) === path : steps.path === path) steps.end();
}

/// How many trails are followed, for the tests.
export function stepsFollowed(): number {
  return trails.size;
}

/// A line of an agent's transcript as the events a thread stores. Of the rest, the context the
/// CLI attached to the session and the requests it sent, nothing is kept: those lines hold the
/// user's email and organisation among much else.
export function lineEvents(line: string): Transcript {
  let record: { type?: string; message?: { content?: unknown }; toolUseResult?: { structuredPatch?: unknown } };
  try {
    record = JSON.parse(line);
  } catch {
    return [];
  }
  if (record.type !== "user" && record.type !== "assistant") return [];
  const patch = patchOf(record.toolUseResult?.structuredPatch);
  return messageEvents(record.type, record.message?.content).map((told) => {
    if (told.event === "tool.result" && patch) return { ...told, patch };
    if (told.event !== "user" || typeof told.text !== "string") return told;
    if (told.text.startsWith("[Request interrupted")) return { event: "note", text: "Stopped" };
    return { ...told, text: unframed(told.text) };
  });
}

/// The task as the workflow's script wrote it, without the line the CLI puts before it saying
/// it's the script's and not the user's, and without the two spaces it indents each line by.
export function unframed(text: string): string {
  const frame = /^\[Workflow harness[^\n]*\n/.exec(text);
  if (!frame) return text;
  return text
    .slice(frame[0].length)
    .split("\n")
    .map((line) => (line.startsWith("  ") ? line.slice(2) : line))
    .join("\n");
}

function patchOf(hunks: unknown): { oldStart: number; newStart: number; lines: string[] }[] | undefined {
  if (!Array.isArray(hunks)) return undefined;
  return hunks.map((hunk) => ({ oldStart: hunk.oldStart, newStart: hunk.newStart, lines: hunk.lines }));
}

/// Where Claude Code writes a Task subagent's transcript: in a folder named for the session, beside
/// the session's own file under `projects`. The CLI names a project's folder for its path with
/// every character but a letter or a digit made a hyphen, and a long path otherwise, so a session
/// not found under that name is looked for in every project's folder. Null when it's nowhere.
export function subagentTranscript(projects: string, cwd: string, sessionId: string, agentId: string): string | null {
  const named = join(projects, cwd.replace(/[^a-zA-Z0-9]/g, "-"));
  let folder: string | undefined = existsSync(join(named, `${sessionId}.jsonl`)) ? named : undefined;
  if (!folder) {
    try {
      folder = readdirSync(projects)
        .map((name) => join(projects, name))
        .find((path) => existsSync(join(path, `${sessionId}.jsonl`)));
    } catch {
      return null;
    }
  }
  return folder ? join(folder, sessionId, "subagents", `agent-${agentId}.jsonl`) : null;
}
