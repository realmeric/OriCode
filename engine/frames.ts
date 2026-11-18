// The engine paces the wire (K-391). A fast model's CLI emits a text delta every few
// milliseconds, and each one sent as its own line wakes the app's reader, decodes JSON and
// touches the main actor, hundreds of times a second for a display that draws a frame every 16 ms.
// Here a thread's consecutive deltas are gathered into one message a frame: the first of a run
// goes at once, so the first word isn't delayed, and what arrives inside the frame after it goes
// out together when the frame ends. Anything else for the thread sends what's held ahead of it,
// so the order on the wire is the order the CLI gave. While the app's window can't be seen a
// frame is a quarter second, the pace its hidden clock shows held text at (K-383).

/// One display frame, in milliseconds, and the frame of a window nobody can see.
export const frame = 16;
export const hiddenFrame = 250;

/// A message built from the deltas gathered: their text as one, and when there was more than one,
/// `parts` as `[offsetMs, utf16Length]` for each, offsets from the first, so the app's pacing
/// (K-364) still reads each delta's arrival.
export type Make = (delta: string, parts?: [number, number][]) => Record<string, unknown>;

type Held = { name: string; delta: string; parts: [number, number][]; since: number; make: Make };

type Timer = ReturnType<typeof setTimeout>;

/// What a Frames runs on: where messages go, a frame's length, the clock and the timer, the last
/// three a test's own.
export type Runs = {
  send: (message: Record<string, unknown>) => void;
  length?: () => number;
  now?: () => number;
  later?: (run: () => void, ms: number) => Timer;
};

export class Frames {
  private held = new Map<string, Held>();
  private open = new Map<string, Timer>();
  private readonly send: (message: Record<string, unknown>) => void;
  private readonly length: () => number;
  private readonly now: () => number;
  private readonly later: (run: () => void, ms: number) => Timer;

  constructor(runs: Runs) {
    this.send = runs.send;
    this.length = runs.length ?? (() => frame);
    this.now = runs.now ?? (() => performance.now());
    this.later = runs.later ?? setTimeout;
  }

  /// A delta of `name` (text or thinking) for `key`, a thread or a thread's worker: sent now
  /// when no frame of the key's is open, held to the frame's end otherwise.
  delta(key: string, name: string, delta: string, make: Make): void {
    if (!this.open.has(key)) {
      this.send(make(delta));
      this.begin(key);
      return;
    }
    const held = this.held.get(key);
    if (held && held.name !== name) this.flush(key);
    const now = this.now();
    const kept = this.held.get(key);
    if (kept) {
      kept.delta += delta;
      kept.parts.push([Math.round(now - kept.since), delta.length]);
    } else {
      this.held.set(key, { name, delta, parts: [[0, delta.length]], since: now, make });
    }
  }

  /// What `key` holds goes out now, ahead of whatever follows it.
  flush(key: string): void {
    const held = this.held.get(key);
    if (!held) return;
    this.held.delete(key);
    this.send(held.parts.length > 1 ? held.make(held.delta, held.parts) : held.make(held.delta));
  }

  /// Everything a thread holds, its own and its workers', keyed `threadId` and `threadId/…`.
  flushThread(threadId: string): void {
    for (const key of [...this.held.keys()]) {
      if (key === threadId || key.startsWith(threadId + "/")) this.flush(key);
    }
  }

  flushAll(): void {
    for (const key of [...this.held.keys()]) this.flush(key);
  }

  private begin(key: string): void {
    this.open.set(
      key,
      this.later(() => {
        // Held text goes with the frame's end and the next frame opens; nothing held closes
        // the frame, so the next delta goes at once.
        if (this.held.has(key)) {
          this.flush(key);
          this.begin(key);
        } else {
          this.open.delete(key);
        }
      }, this.length()),
    );
  }
}
