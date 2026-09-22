// The app's protocol: requests in on stdin, replies and events out on stdout,
// one JSON object per line. stderr is free for logs.

export type Request = { id: number; method: string; params?: Record<string, unknown> };

const trace = process.env.ORICODE_TRACE === "1";

export function emit(message: Record<string, unknown>): void {
  const line = JSON.stringify(message);
  if (trace) process.stderr.write(`> ${line.slice(0, 300)}\n`);
  process.stdout.write(line + "\n");
}

export function event(name: string, fields: Record<string, unknown> = {}): void {
  emit({ event: name, ...fields });
}

export function log(...parts: unknown[]): void {
  process.stderr.write(parts.map(String).join(" ") + "\n");
}
