/// How far a long job is and how long it has left, from how this run has actually gone. A job
/// is its steps in the order they run, each with a guess at its seconds; the guesses only need to
/// be right relative to each other, so a job that can't guess gives every step the same one.
/// make perf uses it through scripts/progress.mts, and a thread's long work can take it the same way.
export type Step = { kind: string; guess: number };

const recent = 5;

/// Seconds the steps after the ones done should take, or undefined before any has ended, when
/// there is nothing to go on. A kind that has run takes what its own last ones took, the latest
/// counting most; one that hasn't takes its guess, scaled by how the last few steps compared to theirs.
export function secondsLeft(plan: Step[], took: number[], running = 0): number | undefined {
  if (took.length === 0) return undefined;
  const last = new Map<string, number>();
  took.forEach((seconds, i) => {
    const kind = plan[i]?.kind;
    if (kind === undefined) return;
    const before = last.get(kind);
    last.set(kind, before === undefined ? seconds : (before + seconds) / 2);
  });
  const done = Math.min(took.length, plan.length);
  const guessed = plan.slice(Math.max(0, done - recent), done).reduce((sum, step) => sum + step.guess, 0);
  const pace = guessed > 0 ? took.slice(-recent).reduce((sum, s) => sum + s, 0) / guessed : 1;
  const expect = (step: Step) => last.get(step.kind) ?? step.guess * pace;
  const rest = plan.slice(done);
  if (rest.length === 0) return 0;
  // The step under way has run `running` seconds. Past what it was expected to take, nothing this
  // run has seen says when it ends, so there is no honest number to give.
  const current = expect(rest[0]!);
  if (running > current) return undefined;
  return current - running + rest.slice(1).reduce((sum, step) => sum + expect(step), 0);
}

/// Seconds as the app's running line says them: "9 min", "<1 min", "1 h 05".
export function short(seconds: number): string {
  if (seconds < 60) return "<1 min";
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `${minutes} min` : `${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")}`;
}

/// The job's line as the app shows it: "3/21 · 9 min", "3/21" before the first step has ended or
/// once the step under way has run past what it should take, and null once every step is, since the line goes then. Times are in seconds; ended holds when
/// each finished step ended.
export function progressLine(plan: Step[], began: number, ended: number[], now: number): string | null {
  const total = plan.length;
  const done = ended.length;
  if (done >= total) return null;
  const seconds = secondsLeft(plan, took(began, ended), now - (ended.at(-1) ?? began));
  return seconds === undefined ? `${done}/${total}` : `${done}/${total} · ${short(seconds)}`;
}

/// The same in words, for a terminal: "3 of 21 done · about 9 min left", "time left: can't tell
/// " before the first step has ended or once the step under way overruns, and how long it took once it's over.
export function spokenLine(plan: Step[], began: number, ended: number[], now: number): string {
  const total = plan.length;
  const done = ended.length;
  if (done >= total) return `${done} of ${total} done, took ${spoken(now - began).replace(/^about /, "")}`;
  const seconds = secondsLeft(plan, took(began, ended), now - (ended.at(-1) ?? began));
  return `${done} of ${total} done · ${seconds === undefined ? "time left: can't tell yet" : `${spoken(seconds)} left`}`;
}

function took(began: number, ended: number[]): number[] {
  return ended.map((end, i) => end - (i === 0 ? began : ended[i - 1]!));
}

function spoken(seconds: number): string {
  if (seconds < 60) return "under a minute";
  const minutes = Math.round(seconds / 60);
  return minutes < 60 ? `about ${minutes} min` : `about ${Math.floor(minutes / 60)} h ${String(minutes % 60).padStart(2, "0")} min`;
}
