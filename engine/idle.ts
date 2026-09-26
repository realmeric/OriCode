import type { Thread } from "./thread.ts";

/// A thread's CLI stays up between turns so a quick reply starts at once, but idle it still
/// holds about 136MB and wakes the Mac a few times a second, so it goes after this long. The
/// next send resumes the session in a new one, about a fifth of a second more.
export const idleRelease = 90_000;

/// What the app last said about its window: the thread open in it, and whether it can be seen.
export type Shown = { threadId: string | null; visible: boolean };

/// Ends each CLI idle past its limit: 90 seconds, or none at all for a thread that isn't open
/// while the window can't be seen, since nobody is about to write to it. Returns the threads let
/// go, and how long until the next one could be.
export function releaseIdle(threads: Map<string, Thread>, shown: Shown, now = Date.now()): { released: string[]; next: number | undefined } {
  const released: string[] = [];
  let next: number | undefined;
  for (const [threadId, thread] of threads) {
    const limit = shown.visible || threadId === shown.threadId ? idleRelease : 0;
    if (thread.releaseIfIdle(limit, now)) {
      released.push(threadId);
      continue;
    }
    const left = thread.idleLeft(limit, now);
    if (left === undefined) continue;
    // Past its limit and still up means its agents are out or it asked something: look again later.
    next = Math.min(next ?? Infinity, left > 0 ? left : idleRelease);
  }
  return { released, next };
}
