import type { Session } from "./provider.ts";

/// A thread's CLI stays up between turns so a quick reply starts at once, but idle it still
/// holds about 136MB and wakes the Mac a few times a second, so it goes after this long. The
/// next send resumes the session in a new one, about a fifth of a second more.
export const idleRelease = 90_000;

/// With this many CLIs up, each with its MCP servers at 300-430MB, an idle one goes after
/// `crowdedRelease` instead: memory is simply the CLIs alive, and a resume costs a fifth of a second.
export const crowd = 3;
export const crowdedRelease = 25_000;

/// What the app last said about its window: the thread open in it, and whether it can be seen;
/// and whether macOS says memory is short, when every idle CLI goes at once.
export type Shown = { threadId: string | null; visible: boolean; pressed?: boolean };

/// Ends each CLI idle past its limit: 90 seconds, 25 with three or more CLIs up, or its agent's
/// own when that's shorter, or none at all for a thread that isn't open while the window can't be
/// seen, since nobody is about to write to it, or for any thread while memory is short. Returns
/// the threads let go, and how long until the next one could be.
export function releaseIdle(threads: Map<string, Session>, shown: Shown, now = Date.now()): { released: string[]; next: number | undefined } {
  const released: string[] = [];
  let next: number | undefined;
  const alive = [...threads.values()].filter((thread) => thread.isRunning || thread.idleLeft(0, now) !== undefined).length;
  const usual = alive >= crowd ? crowdedRelease : idleRelease;
  for (const [threadId, thread] of threads) {
    const kept = !shown.pressed && (shown.visible || threadId === shown.threadId);
    const limit = kept ? Math.min(thread.idleRelease ?? usual, usual) : 0;
    if (thread.releaseIfIdle(limit, now)) {
      released.push(threadId);
      continue;
    }
    const left = thread.idleLeft(limit, now);
    if (left === undefined) continue;
    // Past its limit and still up means its agents are out or it asked something: look again later.
    next = Math.min(next ?? Infinity, left > 0 ? left : usual);
  }
  return { released, next };
}
