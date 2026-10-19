import { copyFile, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { runSettled } from "./child.ts";
import { baseRef, gitDeadline } from "./git.ts";
import { gitRun, top } from "./review.ts";

// A branch's work brought into a folder: a thread's worktree, or an isolated worker's, into the
// folder of the thread that started it. git merges three ways against the folder as it is, its
// uncommitted edits and new files included, so a second branch meets the first one's edits, and
// only the files the branch changes are written: nothing is committed, the index isn't touched,
// and the folder's own edits stay for the user to review beside what came in. A merge that meets
// a conflict stays open, its files written with git's markers, until it's finished or undone;
// undoing it writes those files back as they were before it.

export type Merge = {
  root: string;
  branch: string;
  /// The branch's commit it brought in.
  tip: string;
  /// The folder before the merge, and what git made of it with the branch, as trees.
  ours: string;
  merged: string;
  /// Every file the merge wrote or may write, and the ones git met a conflict in.
  paths: string[];
  conflicts: string[];
  /// Conflicts git couldn't mark, a file one side deleted or a binary one: the folder has one
  /// side, and nothing in the file says so, so a side is kept only when the agent names it.
  unmarked: Unmarked[];
};

export type Unmarked = { path: string; conflict: string; message: string };

export type Counted = { path: string; added: number; deleted: number };

/// A conflict as the agent is shown it: where its marker starts, and each side's lines; or, for
/// one git couldn't mark, what git said of it.
type Hunk = { line: number; folder: string[]; branch: string[] };
export type Conflict = { path: string; hunks: Hunk[] } | Unmarked;

/// Lines of a side shown in a hunk, and hunks of a file; the file has the rest.
const sideLines = 40;
const fileHunks = 12;

/// The folder as it is, untracked files included and worktrees left out, as a tree: built in an
/// index of its own, a copy of the real one so git reads only the files that changed.
export async function snapshot(root: string): Promise<string> {
  const scratch = await mkdtemp(join(tmpdir(), "oricode-merge-"));
  const index = join(scratch, "index");
  try {
    const real = (await gitRun(root, ["rev-parse", "--path-format=absolute", "--git-path", "index"])).trim();
    await copyFile(real, index).catch(() => {});
    const env = { GIT_INDEX_FILE: index };
    await gitRun(root, ["add", "-A", "--", ".", ":(exclude,glob)**/.worktrees/**"], { env });
    return (await gitRun(root, ["write-tree"], { env })).trim();
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

/// The folder as it is, as a commit on its HEAD that no branch holds, for a thread's worktree of
/// `repository` to start with: a thread opened for a part sees what its opener's folder has,
/// uncommitted edits and the work merged in from threads before it included. None when the folder
/// is as HEAD has it, or is in another repository, whose commits the worktree can't start from.
export async function folderCommit(folder: string, repository: string): Promise<string | undefined> {
  const common = (cwd: string) => gitRun(cwd, ["rev-parse", "--path-format=absolute", "--git-common-dir"]).then((dir) => dir.trim());
  if ((await common(folder)) !== (await common(repository))) return undefined;
  const root = await top(folder);
  const head = (await gitRun(root, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]).catch(() => "")).trim();
  if (!head) return undefined;
  const tree = await snapshot(root);
  if (tree === (await gitRun(root, ["rev-parse", "HEAD^{tree}"])).trim()) return undefined;
  return (await gitRun(root, ["-c", "commit.gpgsign=false", "commit-tree", tree, "-p", head, "-m", "The opener's folder as the thread opened"])).trim();
}

/// Merges `branch` into the folder `folder` is in. Throws, having written nothing, when git
/// can't merge at all.
export async function begin(folder: string, branch: string, label: string): Promise<Merge> {
  const root = await top(folder);
  const head = await gitRun(root, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]).catch(() => "");
  if (!head.trim()) throw new Error("This folder's repository has no commit yet, so nothing can be merged into it.");
  const tip = (await gitRun(root, ["rev-parse", "--verify", `${branch}^{commit}`])).trim();
  // A worktree started with its opener's folder merges against that folder as it was, which
  // HEAD's merge base would take for edits on both sides; while the branch still grows from the
  // HEAD it started on.
  const started = (await gitRun(root, ["rev-parse", "--verify", "-q", `${baseRef(branch)}^{commit}`]).catch(() => "")).trim();
  const from = started && (await gitRun(root, ["merge-base", "--is-ancestor", `${started}^`, tip]).then(() => true, () => false)) ? started : "";
  const base = from || (await gitRun(root, ["merge-base", "HEAD", tip])).trim();
  const ours = await snapshot(root);
  const args = ["merge-tree", "--write-tree", "--name-only", "-z", `--merge-base=${base}`, ours, tip];
  const { stdout, stderr, error } = await runSettled("git", args, { cwd: root, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" }, timeout: gitDeadline(args), maxBuffer: 32 * 1024 * 1024 });
  // 1 is a merge with conflicts; anything else is git failing.
  if (error && error.code !== 1) throw new Error(stderr.trim() || error.message);
  const [merged, ...rest] = stdout.split("\0");
  const end = rest.indexOf("");
  const conflicts = [...new Set(rest.slice(0, Math.max(0, end)))];
  const said = end < 0 ? new Map<string, Omit<Unmarked, "path">>() : saidOf(rest.slice(end + 1));
  const paths = (await gitRun(root, ["diff", "--name-only", "-z", "--no-renames", ours, merged])).split("\0").filter(Boolean);
  await write(root, merged, paths);
  // git names each side by what it was given, a tree's id for the folder: the agent reads the
  // folder's name in its place.
  const names = new Map([[`<<<<<<< ${ours}`, `<<<<<<< ${label}`], [`||||||| ${base}`, "||||||| where both started"], [`>>>>>>> ${tip}`, `>>>>>>> ${branch}`]]);
  const unmarked: Unmarked[] = [];
  for (const path of conflicts) {
    const file = join(root, path);
    const text = await readFile(file, "utf8").catch(() => null);
    if (text !== null && markerAt(text) >= 0) {
      const lines = text.split("\n").map((line) => {
        const cr = line.endsWith("\r") ? "\r" : "";
        const name = names.get(cr ? line.slice(0, -1) : line);
        return name === undefined ? line : name + cr;
      });
      await writeFile(file, lines.join("\n"));
    } else {
      const { conflict, message } = said.get(path) ?? { conflict: "contents", message: "" };
      unmarked.push({ path, conflict, message: message.replaceAll(ours, label).replaceAll(tip, branch).replaceAll(base, "where both started") });
    }
  }
  return { root, branch, tip, ours, merged, paths: [...new Set([...paths, ...unmarked.map((file) => file.path)])], conflicts, unmarked };
}

/// What git said of each conflict but a file's contents, from merge-tree's messages: each is a
/// count of paths, the paths, the conflict's kind and its words.
function saidOf(messages: string[]): Map<string, Omit<Unmarked, "path">> {
  const said = new Map<string, Omit<Unmarked, "path">>();
  for (let at = 0; at < messages.length; ) {
    const count = Number(messages[at]);
    if (!Number.isInteger(count) || count < 1) break;
    const named = messages.slice(at + 1, at + 1 + count);
    const conflict = /^CONFLICT \((.+)\)$/.exec(messages[at + 1 + count] ?? "")?.[1];
    const message = (messages[at + 2 + count] ?? "").trim();
    at += count + 3;
    if (!conflict || conflict === "contents") continue;
    for (const path of named) if (!said.has(path)) said.set(path, { conflict, message });
  }
  return said;
}

/// The first line that is a conflict's marker, CRLF files' included.
function markerAt(text: string): number {
  return text.split("\n").findIndex((line) => line.startsWith("<<<<<<< ") || line.startsWith(">>>>>>> "));
}

/// The files of `tree` written into the folder for `paths`, and those it hasn't removed. Through
/// an index of its own, so the real one stays as it was.
async function write(root: string, tree: string, paths: string[]): Promise<void> {
  if (!paths.length) return;
  const scratch = await mkdtemp(join(tmpdir(), "oricode-merge-"));
  const env = { GIT_INDEX_FILE: join(scratch, "index") };
  try {
    await gitRun(root, ["read-tree", tree], { env });
    const present = new Set((await gitRun(root, ["ls-files", "-z", "--", ...paths.map((path) => `:(literal)${path}`)], { env })).split("\0").filter(Boolean));
    const written = paths.filter((path) => present.has(path));
    if (written.length) await gitRun(root, ["checkout-index", "-f", "-z", "--stdin"], { env, input: written.join("\0") + "\0" });
    for (const path of paths.filter((path) => !present.has(path))) await rm(join(root, path), { force: true });
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

/// What the merge brought in, file by file: against the folder before it, from what git made or,
/// once conflicts are settled, from the folder as it is now.
export async function cameIn(merge: Merge, now = merge.merged): Promise<Counted[]> {
  if (!merge.paths.length) return [];
  const out = await gitRun(merge.root, ["diff", "--numstat", "-z", "--no-renames", merge.ours, now, "--", ...merge.paths.map((path) => `:(literal)${path}`)]);
  return out
    .split("\0")
    .filter(Boolean)
    .map((line) => {
      const [added, deleted, ...path] = line.split("\t");
      return { path: path.join("\t"), added: Number(added) || 0, deleted: Number(deleted) || 0 };
    });
}

export function summary(files: Counted[]): string {
  const added = files.reduce((sum, file) => sum + file.added, 0);
  const deleted = files.reduce((sum, file) => sum + file.deleted, 0);
  return files.length ? `${files.length} ${files.length === 1 ? "file" : "files"}, +${added} −${deleted}` : "No files changed";
}

/// Each conflict git left marked in the folder, as the file now has it, and those it couldn't mark.
export async function conflictsOf(merge: Merge): Promise<Conflict[]> {
  const found: Conflict[] = [];
  for (const path of merge.conflicts) {
    const unmarked = merge.unmarked.find((file) => file.path === path);
    if (unmarked) {
      found.push(unmarked);
      continue;
    }
    const text = await readFile(join(merge.root, path), "utf8").catch(() => "");
    const hunks: Hunk[] = [];
    let open: Hunk | null = null;
    let side: "folder" | "base" | "branch" = "folder";
    text.split("\n").forEach((raw, index) => {
      const line = raw.endsWith("\r") ? raw.slice(0, -1) : raw;
      if (line.startsWith("<<<<<<< ")) {
        open = { line: index + 1, folder: [], branch: [] };
        side = "folder";
      } else if (open && line.startsWith("||||||| ")) {
        side = "base";
      } else if (open && line === "=======") {
        side = "branch";
      } else if (open && line.startsWith(">>>>>>> ")) {
        if (hunks.length < fileHunks) hunks.push(open);
        open = null;
      } else if (open && side !== "base" && open[side].length < sideLines) {
        open[side].push(line);
      }
    });
    found.push({ path, hunks });
  }
  return found;
}

/// The files that still have a conflict's markers, with the first marker's line.
export async function marked(merge: Merge): Promise<{ path: string; line: number }[]> {
  const left: { path: string; line: number }[] = [];
  for (const path of merge.conflicts) {
    const at = markerAt(await readFile(join(merge.root, path), "utf8").catch(() => ""));
    if (at >= 0) left.push({ path, line: at + 1 });
  }
  return left;
}

/// A conflict git couldn't mark settled by keeping one side: the folder's from before the merge,
/// or the branch's, the file removed where that side has none.
export async function keep(merge: Merge, path: string, side: "folder" | "branch"): Promise<void> {
  await write(merge.root, side === "folder" ? merge.ours : merge.tip, [path]);
}

/// The files the merge wrote go back to what they were before it, whatever was done to them
/// since; nothing else in the folder changes.
export async function undo(merge: Merge): Promise<void> {
  await write(merge.root, merge.ours, merge.paths);
}

/// Files git ignores that a worktree has and `folder` hasn't, or has otherwise: no merge brings
/// them, so the worktree stays while there are any. A folder git ignores whole, node_modules or a
/// build's output, is what a build makes again, and isn't read file by file.
export async function ignoredLeft(worktree: string, folder: string): Promise<string[]> {
  const listed = (await gitRun(worktree, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])).split("\0");
  const left: string[] = [];
  for (const path of listed.filter((path) => path && !path.endsWith("/"))) {
    const [there, here] = await Promise.all([readFile(join(worktree, path)), readFile(join(folder, path)).catch(() => null)]);
    if (!here?.equals(there)) left.push(path);
  }
  return left;
}
