import { watch, type FSWatcher } from "node:fs";
import { open } from "node:fs/promises";
import { basename, dirname } from "node:path";
import { messageEvents, type Transcript } from "./sessions.ts";
import { event } from "./wire.ts";

// A workflow agent's transcript, which Claude Code writes to disk and never sends through the
// SDK, read while the app shows that agent's thread: what's there past what the app has stored,
// then each line as the CLI appends it. A watcher on the file says when; nothing polls, and an
// agent nobody is looking at is never read.

/// The most events one `agent.lines` carries, so a long transcript comes in pieces.
const batch = 200;

export class Follow {
  readonly threadId: string;
  readonly path: string;
  private offset: number;
  private watcher: FSWatcher | undefined;
  private reading = false;
  private again = false;
  private stopped = false;

  constructor(threadId: string, path: string, from: number) {
    this.threadId = threadId;
    this.path = path;
    this.offset = from;
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

  /// The file, or until the agent's first line is written, its folder.
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
        event("agent.lines", { threadId: this.threadId, from: this.offset, offset: this.offset, events: [], gone: true });
        return;
      }
    }
    this.watcher.on("error", () => {
      this.watcher?.close();
      this.watcher = undefined;
    });
  }

  /// Every whole line past the offset; a line the CLI is still writing waits for the next read.
  private async read(): Promise<void> {
    if (this.stopped) return;
    if (this.reading) {
      this.again = true;
      return;
    }
    this.reading = true;
    try {
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
    } finally {
      this.reading = false;
      if (this.again) {
        this.again = false;
        void this.read();
      }
    }
  }

  /// `from` lets the app take a piece only where its copy ends, so one read twice is dropped;
  /// `more` says another piece of the same read follows, which the app holds until the last.
  private send(from: number, offset: number, events: Transcript, more = false): void {
    event("agent.lines", { threadId: this.threadId, from, offset, events, ...(more ? { more } : {}) });
  }
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
    if (told.text.startsWith("[Request interrupted")) return { event: "note", text: "Stopped with its workflow." };
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
