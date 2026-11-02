import { isAbsolute, relative, resolve } from "node:path";
import { stepOf, type Step } from "./heads.ts";
import { overhear } from "./wire.ts";

// What threads at work in one project know of each other with nobody asking (K-358): a short note
// of who else works there, and a hold on an edit to a file one of them edited in its turn. It's
// here and not in the app because every thread's calls pass through the engine first, and a hold
// that asked the app would wait on its main thread. It reads the tool.use and tool.result events
// the app stores, by the app's rule for an edit (OtherThreads.Use), and keeps only the turns
// running: what a thread edited before them is the app's, read with list_threads. What a shell
// command changed isn't known here, so a file only a command wrote is neither named nor held.

/// What the app sends of a thread of a project. A session without one, a head's worker or a thread
/// of No folder, takes no part: it hears nothing and nobody hears of it.
export type Place = { project: string; title: string; branch?: string };

type Known = Place & {
  id: string;
  cwd: string;
  /// It has message_thread.
  reaches: boolean;
  working: boolean;
  on: Step | null;
  /// Calls that edit a file, by call, until their results say they did.
  calls: Map<string, string[]>;
  /// The files its running turn edited, in full, oldest first.
  edited: Set<string>;
  /// The files it has been held on this turn, which it has heard about and may now write.
  held: Set<string>;
  /// Who was at work and on what when it last had a note, and when.
  told: string;
  toldAt: number;
};

/// A note runs to this many characters, which goes on every turn while another thread works.
const longestNote = 500;
/// Files a note names for a thread, beside those both threads edited.
const mostFiles = 3;
/// Mid-turn, a new note waits this long after the last: on a long turn in a busy project each file
/// another thread touches would otherwise add one, and each stays in the context.
export const noteGap = 120_000;

const threads = new Map<string, Known>();

/// The thread is sent a message. Its turn counts from here, so that of two sent at once the second
/// hears of the first, and the first hears of the second at its next step.
export function working(id: string, place: Place, cwd: string, reaches: boolean): void {
  const known = threads.get(id);
  if (known) Object.assign(known, place, { cwd, reaches, working: true });
  else threads.set(id, { ...place, id, cwd, reaches, working: true, on: null, calls: new Map(), edited: new Set(), held: new Set(), told: "", toldAt: 0 });
}

/// The turn is over, or never started.
export function rested(id: string): void {
  const known = threads.get(id);
  if (!known) return;
  known.working = false;
  known.on = null;
  known.calls.clear();
  known.edited.clear();
  known.held.clear();
  known.told = "";
  known.toldAt = 0;
}

export function gone(id: string): void {
  threads.delete(id);
}

/// The events that say anything here, so a delta costs a lookup and nothing else.
const said = new Set(["turn.started", "turn.done", "tool.use", "tool.result", "title"]);

export function heard(name: string, fields: Record<string, unknown>): void {
  if (!said.has(name)) return;
  const known = threads.get(fields.threadId as string);
  if (!known) return;
  switch (name) {
    case "turn.started":
      // A turn nobody sent, a background agent reporting back.
      known.working = true;
      return;
    case "turn.done":
      return rested(known.id);
    case "title":
      known.title = String(fields.title);
      return;
    case "tool.use": {
      // A subagent's calls count as the thread's edits, and what the thread is on is its own.
      if (!fields.parent) known.on = stepOf(String(fields.name), (fields.input ?? {}) as Record<string, unknown>, known.cwd);
      const files = editedBy(fields);
      if (files.length) known.calls.set(String(fields.toolUseId), files);
      return;
    }
    case "tool.result": {
      const id = String(fields.toolUseId);
      const files = known.calls.get(id);
      if (!files) return;
      known.calls.delete(id);
      if (fields.isError) return;
      for (const file of files) known.edited.add(resolve(known.cwd, file));
    }
  }
}

overhear(heard);

type Arguments = { path?: string; file_path?: string; notebook_path?: string; movePath?: string };

const editing = new Set(["edit", "write", "delete", "move"]);
/// Claude Code's tools, whose calls name no kind.
const kinds: Record<string, string> = { Edit: "edit", MultiEdit: "edit", Write: "write", NotebookEdit: "notebook" };
/// The same names as the hook before a tool matches them.
export const editTools = Object.keys(kinds).join("|");

/// The files a call edits, as OtherThreads.Use reads them; a move is on both its names.
function editedBy(call: Record<string, unknown>): string[] {
  const kind = (call.kind as string | undefined) ?? kinds[String(call.name)];
  const input = (call.input ?? {}) as Arguments;
  const view = (call.view ?? {}) as Arguments;
  const file = editing.has(kind) ? (view.path ?? input.file_path ?? input.path) : kind === "notebook" ? (view.path ?? input.notebook_path) : undefined;
  return [input.movePath, file].filter((path) => typeof path === "string");
}

function company(of: Known): Known[] {
  return [...threads.values()].filter((other) => other.working && other !== of && other.project === of.project);
}

function inFolder(file: string, cwd: string): string {
  return isAbsolute(file) && !relative(cwd, file).startsWith("..") ? relative(cwd, file) : file;
}

function cut(text: string, most: number): string {
  return text.length > most ? `${text.slice(0, most - 1)}…` : text;
}

/// The line of a note for `other`: who it is, where, what it's on and what it edited, what both
/// threads edited coming first since a shared folder or a merge will meet it.
function line(other: Known, mine: Known): string {
  const ours = new Set([...mine.edited].map((file) => inFolder(file, mine.cwd)));
  const files = [...other.edited].map((file) => inFolder(file, other.cwd));
  const both = files.filter((file) => ours.has(file));
  const rest = files.filter((file) => !ours.has(file));
  const shown = rest.slice(-mostFiles);
  const parts = [`"${cut(other.title, 40)}" (id ${other.id})`];
  if (other.cwd === mine.cwd) parts.push("shares your folder");
  else parts.push(other.branch ? `on branch ${other.branch}` : `in ${other.cwd}`);
  if (other.on) parts.push(`at ${cut(other.on.detail ? `${other.on.tool} ${other.on.detail}` : other.on.tool, 40)}`);
  if (shown.length) parts.push(`edited ${shown.join(", ")}${rest.length > shown.length ? ` and ${rest.length - shown.length} more` : ""}`);
  if (both.length) parts.push(`you both edited ${both.join(", ")}${other.cwd === mine.cwd ? "" : ", which merging will meet"}`);
  return parts.join(", ");
}

/// Those whose work can meet this thread's come first, should the note run out.
function closeness(other: Known, mine: Known): number {
  return (other.cwd === mine.cwd ? 2 : 0) + ([...other.edited].some((file) => mine.edited.has(file)) ? 1 : 0);
}

/// The note itself, within `longestNote`.
function note(mine: Known, others: Known[]): string {
  const close = [...others].sort((a, b) => closeness(b, mine) - closeness(a, mine));
  const count = close.length === 1 ? "Another thread is" : `${close.length} other threads are`;
  let text = `[OriCode] ${count} working in this project.${mine.reaches ? " message_thread reaches one." : ""}`;
  const more = (left: number) => `\nAnd ${left} more${mine.reaches ? ": list_threads names them." : "."}`;
  for (const [index, other] of close.entries()) {
    const next = `\n${line(other, mine)}`;
    const left = close.length - index - 1;
    if (text.length + next.length + (left ? more(left).length : 0) > longestNote) return text + more(close.length - index);
    text += next;
  }
  return text;
}

function telling(mine: Known, others: Known[], state: string, now: number): string {
  mine.told = state;
  mine.toldAt = now;
  return note(mine, others);
}

/// What other threads are doing, as a thread would need told of it again.
function stateOf(others: Known[]): string {
  return others.map((other) => `${other.id} ${[...other.edited].join(" ")}`).sort().join("\n");
}

/// The note ahead of a message that starts a turn, or nothing with no other thread at work.
export function atStart(id: string, now = Date.now()): string | undefined {
  const mine = threads.get(id);
  const others = mine ? company(mine) : [];
  if (!mine || !others.length) return undefined;
  return telling(mine, others, stateOf(others), now);
}

/// The note for a thread's next step, when who's at work has changed or another has edited a file
/// since its last, no sooner than `noteGap` after it.
export function atStep(id: string, now = Date.now()): string | undefined {
  const mine = threads.get(id);
  if (!mine?.working) return undefined;
  const others = company(mine);
  if (!others.length) return undefined;
  const state = stateOf(others);
  if (state === mine.told || now - mine.toldAt < noteGap) return undefined;
  return telling(mine, others, state, now);
}

/// What holds a thread's edit of `path`: another thread at work in the same folder edited that
/// file in its turn and this one hasn't been told. Told, it goes through on its next attempt. A
/// thread in another folder, a worktree, is never held: its note names the overlap.
export function hold(id: string, path: string): string | undefined {
  const mine = threads.get(id);
  if (!mine?.working) return undefined;
  const file = resolve(mine.cwd, path);
  if (mine.held.has(file)) return undefined;
  const other = company(mine).find((other) => other.cwd === mine.cwd && other.edited.has(file));
  if (!other) return undefined;
  mine.held.add(file);
  return `Held, this edit wasn't made: the thread "${cut(other.title, 40)}" (id ${other.id}), at work in this folder, edited ${inFolder(file, mine.cwd)} in its turn. Read the file again${mine.reaches ? " or message_thread it" : ""}, then edit again.`;
}
