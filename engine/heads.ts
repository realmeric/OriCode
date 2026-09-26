import { watch, type FSWatcher } from "node:fs";
import { open } from "node:fs/promises";
import { isAbsolute, relative } from "node:path";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { lastLine } from "./shell.ts";
import { event } from "./wire.ts";

// A thread's heads besides its main loop: the subagents, commands, workflows and other tasks the
// CLI runs for it. The app lights a ray for each agent at work, and while its Heads surface is
// open it's told what each is on. Membership goes out at once. What each is doing goes out only
// while the surface watches, at most once in 250ms and never twice the same, so an engine nobody
// is watching sets no timers and reads no files.

export type Step = { tool: string; detail: string | null };

export type Head = {
  id: string;
  kind: "agent" | "command" | "workflow" | "other";
  /// The call that started it, which a subagent's own frames name as their parent.
  toolUseId: string | null;
  label: string;
  /// The subagent's type, for an agent.
  type: string | null;
  background: boolean;
  depth: number;
  startedAt: number;
  tokens: number | null;
  tools: number | null;
  step: Step | null;
  /// A command's last line of output.
  line: string | null;
};

type Live = Head & {
  /// Where a command's output goes, and the watcher on it while the surface is open.
  output: string | null;
  tail: FSWatcher | null;
  stale: boolean;
};

type Task = { task_id: string; task_type?: string; description: string; ambient?: boolean };

type Block = { type: string; id?: string; name?: string; input?: unknown; tool_use_id?: string; content?: unknown };

export class Heads {
  private live = new Map<string, Live>();
  private threadId: string;
  private watched = false;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private told = "";
  /// The thread's folder, which a step's path is given from.
  cwd = "";

  constructor(threadId: string) {
    this.threadId = threadId;
  }

  get size(): number {
    return this.live.size;
  }

  has(taskId: string): boolean {
    return this.live.has(taskId);
  }

  /// Keeps the heads in step with the CLI's task messages; false for any other message.
  track(message: SDKMessage & { type: "system" }): boolean {
    switch (message.subtype) {
      case "task_started":
        if (message.ambient) return true;
        this.add(message, message.tool_use_id ?? null, message.subagent_type ?? null, message.is_backgrounded ?? false, message.spawn_depth ?? 1);
        this.send();
        return true;
      case "task_progress": {
        const head = this.live.get(message.task_id);
        if (!head) return true;
        head.tokens = message.usage.total_tokens;
        head.tools = message.usage.tool_uses;
        // The subagent's own frames name the call and what it's on; the CLI's progress names
        // only the tool, which does when no frame has.
        if (!head.step && message.last_tool_name && head.kind === "agent") head.step = { tool: message.last_tool_name, detail: null };
        this.soon();
        return true;
      }
      case "task_notification":
        this.end(message.task_id);
        return true;
      case "task_updated": {
        const status = message.patch.status;
        if (status && !["pending", "running", "paused"].includes(status)) {
          this.end(message.task_id);
          return true;
        }
        const head = this.live.get(message.task_id);
        if (!head) return true;
        if (message.patch.description) head.label = message.patch.description;
        if (message.patch.is_backgrounded !== undefined) head.background = message.patch.is_backgrounded;
        this.send();
        return true;
      }
      case "background_tasks_changed": {
        // The CLI's own list of what's still running in the background: a backgrounded head it
        // no longer lists is over, and one it lists that never started here is new.
        const listed = message.tasks.filter((task) => !task.ambient);
        const ids = new Set(listed.map((task) => task.task_id));
        for (const [id, head] of this.live) if (head.background && !ids.has(id)) this.drop(id);
        for (const task of listed) {
          const head = this.live.get(task.task_id);
          if (head) head.background = true;
          else this.add(task, null, null, true, 1);
        }
        this.send();
        return true;
      }
      default:
        return false;
    }
  }

  /// A subagent's own assistant message: the call it has just made is its step.
  frame(parent: string, content: readonly Block[]): void {
    const head = this.started(parent);
    if (!head) return;
    for (const block of content) {
      if (block.type !== "tool_use" || !block.name) continue;
      head.step = stepOf(block.name, (block.input ?? {}) as Record<string, unknown>, this.cwd);
    }
    this.soon();
  }

  /// A call's result, the main loop's or a subagent's. A command sent to the background answers
  /// with where its output goes, which is all a command's head needs to show its last line.
  result(toolUseId: string, text: string): void {
    const head = this.started(toolUseId);
    if (head?.kind !== "command" || head.output) return;
    const output = outputFile(text);
    if (!output) return;
    head.output = output;
    if (this.watched) this.tail(head);
  }

  /// While the surface is open, each head's detail goes out, and each command's output is
  /// followed. Closed, neither.
  watch(on: boolean): void {
    if (on === this.watched) return;
    this.watched = on;
    for (const head of this.live.values()) {
      if (on) this.tail(head);
      else this.untail(head);
    }
    if (!on && this.timer) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    this.send();
  }

  /// The CLI that ran them has gone.
  clear(): void {
    clearTimeout(this.timer);
    this.timer = undefined;
    if (this.live.size === 0) return;
    for (const id of [...this.live.keys()]) this.drop(id);
    this.send();
  }

  private add(task: Task, toolUseId: string | null, type: string | null, background: boolean, depth: number): void {
    const head: Live = {
      id: task.task_id,
      kind: kindOf(task.task_type),
      toolUseId,
      label: task.description,
      type,
      background,
      depth,
      startedAt: Date.now(),
      tokens: null,
      tools: null,
      step: null,
      line: null,
      output: null,
      tail: null,
      stale: false,
    };
    this.live.set(head.id, head);
  }

  private end(taskId: string): void {
    if (!this.live.has(taskId)) return;
    this.drop(taskId);
    this.send();
  }

  private drop(taskId: string): void {
    const head = this.live.get(taskId);
    if (head) this.untail(head);
    this.live.delete(taskId);
  }

  /// The head a call started.
  private started(toolUseId: string): Live | undefined {
    for (const head of this.live.values()) if (head.toolUseId === toolUseId) return head;
    return undefined;
  }

  private tail(head: Live): void {
    if (!head.output || head.tail) return;
    try {
      head.tail = watch(head.output, () => {
        head.stale = true;
        this.soon();
      });
      head.tail.on("error", () => this.untail(head));
    } catch {
      return;
    }
    head.stale = true;
    this.soon();
  }

  private untail(head: Live): void {
    head.tail?.close();
    head.tail = null;
  }

  /// Detail changed: one send in 250ms, and only while the surface watches.
  private soon(): void {
    if (!this.watched || this.timer) return;
    this.timer = setTimeout(() => void this.tick(), 250);
  }

  private async tick(): Promise<void> {
    await Promise.all([...this.live.values()].filter((head) => head.stale).map((head) => readLine(head)));
    this.timer = undefined;
    this.send();
    // Written to again while it was being read.
    if ([...this.live.values()].some((head) => head.stale)) this.soon();
  }

  private send(): void {
    const heads = [...this.live.values()].map((head) => {
      const shown: Partial<Head> = {
        id: head.id,
        kind: head.kind,
        toolUseId: head.toolUseId,
        label: head.label,
        type: head.type,
        background: head.background,
        depth: head.depth,
        startedAt: head.startedAt,
      };
      if (this.watched) Object.assign(shown, { tokens: head.tokens, tools: head.tools, step: head.step, line: head.line });
      return shown;
    });
    const told = JSON.stringify(heads);
    if (told === this.told) return;
    this.told = told;
    event("heads", { threadId: this.threadId, heads });
  }
}

function kindOf(taskType: string | undefined): Head["kind"] {
  switch (taskType) {
    case "local_agent":
    case "remote_agent":
    case "in_process_teammate":
      return "agent";
    case "local_bash":
      return "command";
    case "local_workflow":
      return "workflow";
    default:
      return taskType?.startsWith("monitor") ? "command" : "other";
  }
}

/// What a call is on, in the shape a workflow's agents report theirs: the tool, and the file,
/// the command's first line, the pattern or the page it was given.
export function stepOf(tool: string, input: Record<string, unknown>, cwd: string): Step {
  const text = (key: string) => (typeof input[key] === "string" && input[key] !== "" ? (input[key] as string) : null);
  const path = text("file_path") ?? text("notebook_path");
  const detail =
    (path && cwd && isAbsolute(path) && !relative(cwd, path).startsWith("..") ? relative(cwd, path) : path) ??
    text("command")?.split("\n").find((line) => line.trim()) ??
    text("pattern") ??
    text("url") ??
    text("query") ??
    text("description") ??
    text("skill") ??
    text("path");
  return { tool, detail: detail?.slice(0, 160) ?? null };
}

/// The file a command sent to the background writes to, from its call's result.
export function outputFile(text: string): string | null {
  const match = /Output is being written to: (.+)/.exec(text);
  if (!match) return null;
  const path = match[1].trim();
  return path.endsWith(".") ? path.slice(0, -1) : path;
}

/// The last line a command printed, from the end of its output file.
async function readLine(head: Live): Promise<void> {
  head.stale = false;
  if (!head.output) return;
  try {
    const file = await open(head.output);
    try {
      const { size } = await file.stat();
      const length = Math.min(size, 4096);
      const { buffer } = await file.read(Buffer.alloc(length), 0, length, size - length);
      head.line = lastLine(buffer.toString("utf8")).slice(0, 200) || null;
    } finally {
      await file.close();
    }
  } catch {
    // Gone with the command, or not written yet.
  }
}
