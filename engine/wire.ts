// The app's protocol: requests in on stdin, replies and events out on stdout,
// one JSON object per line. stderr is free for logs.

export type Request = { id: number; method: string; params?: Record<string, unknown> };

const trace = process.env.ORICODE_TRACE === "1";

export function emit(message: Record<string, unknown>): void {
  const line = JSON.stringify(message);
  if (trace) process.stderr.write(`> ${line.slice(0, 300)}\n`);
  process.stdout.write(line + "\n");
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

export function event(name: string, fields: Record<string, unknown> = {}): void {
  const listener = typeof fields.threadId === "string" ? taps.get(fields.threadId) : undefined;
  if (listener?.(name, fields)) return;
  emit({ event: name, ...fields });
}

export function log(...parts: unknown[]): void {
  process.stderr.write(parts.map(String).join(" ") + "\n");
}
