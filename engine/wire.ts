// The app's protocol: requests in on stdin, replies and events out on stdout,
// one JSON object per line. stderr is free for logs.

import { Frames, frame, hiddenFrame } from "./frames.ts";

export type Request = { id: number; method: string; params?: Record<string, unknown> };

const trace = process.env.ORICODE_TRACE === "1";

function write(message: Record<string, unknown>): void {
  const line = JSON.stringify(message);
  if (trace) process.stderr.write(`> ${line.slice(0, 300)}\n`);
  process.stdout.write(line + "\n");
}

let hidden = false;
/// A thread's deltas gathered into one message a frame (K-391), a quarter second while the window
/// can't be seen.
const frames = new Frames({ send: write, length: () => (hidden ? hiddenFrame : frame) });

/// The app said whether its window can be seen.
export function windowShown(visible: boolean): void {
  hidden = !visible;
}

const paced = new Set(["text", "thinking"]);

/// A text or thinking delta of a thread's, or of a worker's inside `worker.said`, waits for the
/// frame; any other message of the thread's sends what the thread holds first.
export function emit(message: Record<string, unknown>): void {
  const threadId = typeof message.threadId === "string" ? message.threadId : undefined;
  if (threadId && typeof message.event === "string") {
    const name = message.event;
    if (paced.has(name) && typeof message.delta === "string") {
      frames.delta(threadId, name, message.delta, (delta, parts) => ({ ...message, delta, ...(parts ? { parts } : {}) }));
      return;
    }
    const said = message.said as Record<string, unknown> | undefined;
    if (name === "worker.said" && typeof message.agentId === "string" && said && typeof said.event === "string" && paced.has(said.event) && typeof said.delta === "string") {
      frames.delta(`${threadId}/${message.agentId}`, said.event, said.delta, (delta, parts) => ({ ...message, said: { ...said, delta, ...(parts ? { parts } : {}) } }));
      return;
    }
    frames.flushThread(threadId);
  }
  write(message);
}

/// Everything held goes out, before the engine ends.
export function flushFrames(): void {
  frames.flushAll();
}

/// Sessions the app has no thread for, a head's workers, and a head whose `heads` go out with its
/// workers', hear their own events here first; a tap that returns true has taken the event.
const taps = new Map<string, (name: string, fields: Record<string, unknown>) => boolean>();

export function tap(threadId: string, listener: (name: string, fields: Record<string, unknown>) => boolean): void {
  taps.set(threadId, listener);
}

export function untap(threadId: string): void {
  taps.delete(threadId);
}

/// Hears every event before the app does: others.ts, for what threads at work are doing.
let overhearing: ((name: string, fields: Record<string, unknown>) => void) | undefined;

export function overhear(listener: (name: string, fields: Record<string, unknown>) => void): void {
  overhearing = listener;
}

export function event(name: string, fields: Record<string, unknown> = {}): void {
  overhearing?.(name, fields);
  const listener = typeof fields.threadId === "string" ? taps.get(fields.threadId) : undefined;
  if (listener?.(name, fields)) return;
  emit({ event: name, ...fields });
}

export function log(...parts: unknown[]): void {
  process.stderr.write(parts.map(String).join(" ") + "\n");
}
