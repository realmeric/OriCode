import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { lstat, open, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Review: what the working tree changes against HEAD, as hunks, and the git the Review surface
// does with them. Every path is from the repository's top, whichever folder the thread is in.

export type Hunk = { oldStart: number; oldLines: number; newStart: number; newLines: number; context: string; lines: string[] };

export type FileDiff = {
  path: string;
  /// A rename's path before it.
  oldPath: string | null;
  /// "M" modified, "A" added, "D" deleted, "R" renamed, "T" changed type, "?" untracked.
  status: string;
  binary: boolean;
  /// Whether git would run it: a new file's mode, when that's 100755.
  executable: boolean;
  hunks: Hunk[];
  added: number;
  deleted: number;
  /// Too large to show: the counts are right and the hunks are left out.
  cut: boolean;
  /// The working tree's size and date for a file the review can't show line by line, so the
  /// app can tell when it changes again.
  stamp: string | null;
  /// Some of its text isn't UTF-8, so its lines as shown can't be written back byte for byte:
  /// it's taken back and committed whole.
  lossy: boolean;
};

export type Diff = { root: string; head: string | null; mark: string; files: FileDiff[] };

export type IndexEntry = { path: string; mode: string; sha: string };

/// Past this many changed lines a file's hunks stay out of the reply, so a generated file or a
/// lockfile can't make the review slow.
const lineLimit = 4000;
/// Untracked files are read by the engine, not by git; past these it stops reading.
const untrackedFiles = 400;
const untrackedBytes = 1024 * 1024;

type Options = { input?: string; env?: Record<string, string> };

/// git with what git.ts's helper can't do: standard input, and an index of its own.
export function gitRun(cwd: string, args: string[], options: Options = {}): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn("git", args, { cwd, env: { ...process.env, GIT_TERMINAL_PROMPT: "0", ...options.env } });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let size = 0;
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > 96 * 1024 * 1024) {
        child.kill();
        reject(new Error("This diff is too large to show."));
      } else {
        out.push(chunk);
      }
    });
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(Buffer.concat(out).toString("utf8"));
      else reject(new Error(Buffer.concat(err).toString("utf8").trim() || `git ${args.find((arg) => !arg.startsWith("-")) ?? ""} failed`));
    });
    // git can exit before it has read everything it was given.
    child.stdin.on("error", () => {});
    child.stdin.end(options.input ?? "");
  });
}

export async function top(cwd: string): Promise<string> {
  try {
    return (await gitRun(cwd, ["rev-parse", "--show-toplevel"])).trim();
  } catch {
    throw new Error("This folder isn't in a git repository.");
  }
}

async function head(root: string): Promise<string | null> {
  return gitRun(root, ["rev-parse", "--verify", "-q", "HEAD^{commit}"]).then(
    (out) => out.trim(),
    () => null,
  );
}

/// The user's settings mustn't change what the review reads: no colours, no external diff
/// tool, no text conversion, git's own prefixes, and paths spelled out rather than escaped.
const diffArgs = ["-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "-M", "--histogram", "-U3"];

/// A path as git's pathspec takes it, with nothing in it read as a pattern.
function literal(path: string): string {
  return `:(literal)${path}`;
}

/// Each folder's repository top, asked of git once.
const tops = new Map<string, string>();

/// What the working tree changes against HEAD: tracked files as git diffs them, and untracked
/// ones as new, all of their lines added. `mark` changes whenever the diff can have: git status
/// names HEAD and every changed and untracked path, and each path's size and date say whether
/// it moved again. Asked with the mark it last gave, when nothing has moved, it answers `same`
/// after that one git process.
export function workingDiff(cwd: string): Promise<Diff>;
export function workingDiff(cwd: string, since?: string): Promise<Diff | { root: string; same: true }>;
export async function workingDiff(cwd: string, since?: string): Promise<Diff | { root: string; same: true }> {
  const root = tops.get(cwd) ?? (await top(cwd));
  tops.set(cwd, root);
  const status = await gitRun(root, ["--no-optional-locks", "-c", "core.quotePath=false", "status", "--porcelain=v2", "-z", "--branch", "--no-ahead-behind", "--untracked-files=all"]).catch((error) => {
    tops.delete(cwd);
    throw error;
  });
  const { commit, changed, untracked } = parseStatus(status);
  const stamps = await Promise.all([...changed, ...untracked].map((path) => stamp(join(root, path))));
  const mark = createHash("sha256").update(status).update(stamps.join("\0")).digest("hex");
  if (mark === since) return { root, same: true };
  // With no commit yet, everything is measured against the empty tree.
  const base = commit ?? (await gitRun(root, ["hash-object", "-t", "tree", "/dev/null"])).trim();
  const { named, counts } = parseSummary(await gitRun(root, [...diffArgs, "--raw", "--numstat", "-z", base]));
  const huge = named.filter((file) => {
    const count = counts.get(file.path);
    return count && count.added + count.deleted > lineLimit;
  });
  const exclusions = huge.flatMap((file) => [file.path, file.oldPath]).filter((path): path is string => !!path).map((path) => `:(exclude,literal)${path}`);
  const chunks = named.length > huge.length ? parsePatch(await gitRun(root, [...diffArgs, base, "--", ".", ...exclusions])) : [];
  const byPath = new Map(chunks.map((chunk) => [chunk.path, chunk]));
  const files: FileDiff[] = named.map((file) => {
    const count = counts.get(file.path) ?? { added: 0, deleted: 0, binary: false };
    const chunk = byPath.get(file.path);
    // Lines git counted that no hunk carries are shown as counts only, never as a file with
    // nothing in it, which taking back would treat as a mode change.
    const unread = !count.binary && count.added + count.deleted > 0 && !(chunk?.hunks.length ?? 0);
    const cut = huge.includes(file) || unread;
    return {
      path: file.path,
      oldPath: file.oldPath,
      status: file.status,
      binary: count.binary || (chunk?.binary ?? false),
      executable: chunk?.executable ?? false,
      hunks: cut ? [] : (chunk?.hunks ?? []),
      added: count.added,
      deleted: count.deleted,
      cut,
      stamp: null,
      lossy: chunk?.lossy ?? false,
    };
  });
  const paths = untracked.filter((path) => !path.endsWith("/"));
  for (const [index, path] of paths.entries()) {
    files.push(index < untrackedFiles ? await newFile(root, path) : { ...blank(path), cut: true });
  }
  for (const file of files) {
    if (file.binary || file.cut || file.hunks.length === 0) file.stamp = await stamp(join(root, file.path));
  }
  return { root, head: commit, mark, files };
}

async function stamp(path: string): Promise<string> {
  return stat(path).then(
    (info) => `${info.size}:${info.mtimeMs}`,
    () => "gone",
  );
}

function blank(path: string): FileDiff {
  return { path, oldPath: null, status: "?", binary: false, executable: false, hunks: [], added: 0, deleted: 0, cut: false, stamp: null, lossy: false };
}

/// An untracked file as git would diff it once added: one hunk of added lines.
async function newFile(root: string, path: string): Promise<FileDiff> {
  const file = blank(path);
  let handle;
  try {
    handle = await open(join(root, path), "r");
    const info = await handle.stat();
    if (!info.isFile()) return file;
    file.executable = (info.mode & 0o111) !== 0;
    const buffer = Buffer.alloc(Math.min(info.size, untrackedBytes));
    await handle.read(buffer, 0, buffer.length, 0);
    if (buffer.subarray(0, 8000).includes(0)) return { ...file, binary: true };
    const text = buffer.toString("utf8");
    file.lossy = text.includes("\uFFFD");
    const lines = text === "" ? [] : text.split("\n");
    const ends = text.endsWith("\n");
    if (ends) lines.pop();
    file.added = lines.length;
    if (info.size > untrackedBytes || lines.length > lineLimit) return { ...file, cut: true };
    if (lines.length === 0) return file;
    file.hunks = [
      {
        oldStart: 0,
        oldLines: 0,
        newStart: 1,
        newLines: lines.length,
        context: "",
        lines: [...lines.map((line) => "+" + line), ...(ends ? [] : ["\\ No newline at end of file"])],
      },
    ];
    return file;
  } catch {
    // Gone between the listing and the read, or unreadable: listed, with nothing to show.
    return file;
  } finally {
    await handle?.close();
  }
}

type Named = { status: string; path: string; oldPath: string | null };
type Counts = Map<string, { added: number; deleted: number; binary: boolean }>;

/// `--raw --numstat -z`, which git writes one after the other. Raw is ":modes shas M\0path\0",
/// and ":modes shas R086\0old\0new\0" for a rename or a copy. Numstat is
/// "added\tdeleted\tpath\0", and "added\tdeleted\t\0old\0new\0" for a rename; a binary file
/// counts "-", and counts are keyed by the path after the change.
export function parseSummary(out: string): { named: Named[]; counts: Counts } {
  const tokens = out.split("\0");
  const named: Named[] = [];
  const counts: Counts = new Map();
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (!token) continue;
    if (token.startsWith(":")) {
      const status = token.slice(token.lastIndexOf(" ") + 1);
      if (status[0] === "R" || status[0] === "C") {
        named.push({ status: status[0] === "R" ? "R" : "A", oldPath: status[0] === "R" ? tokens[i + 1] : null, path: tokens[i + 2] });
        i += 2;
      } else {
        named.push({ status: status[0], path: tokens[i + 1], oldPath: null });
        i += 1;
      }
      continue;
    }
    const first = token.indexOf("\t");
    const second = token.indexOf("\t", first + 1);
    if (first < 0 || second < 0) continue;
    const added = token.slice(0, first);
    const deleted = token.slice(first + 1, second);
    let path = token.slice(second + 1);
    if (path === "") {
      path = tokens[i + 2];
      i += 2;
    }
    counts.set(path, { added: Number(added) || 0, deleted: Number(deleted) || 0, binary: added === "-" });
  }
  return { named, counts };
}

/// HEAD's commit, null before the first, and the paths `status --porcelain=v2 -z --branch` names,
/// from the repository's top: a changed entry's path follows 8 fields, a rename's 9, with the old
/// path as the next token, an unmerged one's 10.
export function parseStatus(out: string): { commit: string | null; changed: string[]; untracked: string[] } {
  const tokens = out.split("\0");
  let commit: string | null = null;
  const changed: string[] = [];
  const untracked: string[] = [];
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    if (token.startsWith("# branch.oid ")) {
      const oid = token.slice("# branch.oid ".length);
      commit = oid === "(initial)" ? null : oid;
      continue;
    }
    if (token.startsWith("? ")) {
      untracked.push(token.slice(2));
      continue;
    }
    const fields = token[0] === "1" ? 8 : token[0] === "2" ? 9 : token[0] === "u" ? 10 : 0;
    if (!fields || token[1] !== " ") continue;
    changed.push(token.split(" ").slice(fields).join(" "));
    if (token[0] === "2") i += 1;
  }
  return { commit, changed, untracked };
}

type Chunk = { path: string; binary: boolean; executable: boolean; lossy: boolean; hunks: Hunk[] };

/// A patch, one chunk per file. A hunk ends when its header's counts are used up, so a line of
/// code that looks like a header can't end it early.
export function parsePatch(out: string): Chunk[] {
  const lines = out.split("\n");
  if (lines.at(-1) === "") lines.pop();
  const chunks: Chunk[] = [];
  let chunk: (Chunk & { from?: string; to?: string; git: string }) | undefined;
  const finish = () => {
    if (!chunk) return;
    chunk.path = chunk.to ?? chunk.from ?? sameName(chunk.git) ?? "";
    // git's output is read as UTF-8; a byte that isn't comes back as U+FFFD, and a patch built
    // from that line would write U+FFFD over the byte.
    const lossy = chunk.hunks.some((hunk) => hunk.lines.some((line) => line.includes("\uFFFD")));
    chunks.push({ path: chunk.path, binary: chunk.binary, executable: chunk.executable, lossy, hunks: chunk.hunks });
  };
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (line.startsWith("diff --git ")) {
      finish();
      chunk = { path: "", binary: false, executable: false, lossy: false, hunks: [], git: line.slice("diff --git ".length) };
      i++;
      continue;
    }
    if (!chunk) {
      i++;
      continue;
    }
    const at = line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?([\s\S]*)$/);
    if (at) {
      const hunk: Hunk = {
        oldStart: Number(at[1]),
        oldLines: at[2] === undefined ? 1 : Number(at[2]),
        newStart: Number(at[3]),
        newLines: at[4] === undefined ? 1 : Number(at[4]),
        context: at[5] ?? "",
        lines: [],
      };
      let old = hunk.oldLines;
      let now = hunk.newLines;
      i++;
      while (i < lines.length && (old > 0 || now > 0 || lines[i].startsWith("\\"))) {
        const body = lines[i];
        if (body.startsWith("\\")) {
          hunk.lines.push(body);
        } else if (body.startsWith("-") && old > 0) {
          old--;
          hunk.lines.push(body);
        } else if (body.startsWith("+") && now > 0) {
          now--;
          hunk.lines.push(body);
        } else if ((body.startsWith(" ") || body === "") && old > 0 && now > 0) {
          old--;
          now--;
          hunk.lines.push(body === "" ? " " : body);
        } else {
          break;
        }
        i++;
      }
      chunk.hunks.push(hunk);
      continue;
    }
    if (chunk.hunks.length === 0) {
      if (line.startsWith("rename to ")) chunk.to = unquote(line.slice("rename to ".length));
      else if (line.startsWith("+++ ") && line !== "+++ /dev/null") chunk.to ??= stripPrefix(line.slice(4));
      else if (line.startsWith("--- ") && line !== "--- /dev/null") chunk.from ??= stripPrefix(line.slice(4));
      else if (line.startsWith("Binary files ") || line === "GIT binary patch") chunk.binary = true;
      else if (line === "new file mode 100755" || line === "new mode 100755") chunk.executable = true;
    }
    i++;
  }
  finish();
  return chunks;
}

/// "a/path" from a ---/+++ line: git adds a tab after a name with a space in it.
function stripPrefix(name: string): string {
  const path = unquote(name.endsWith("\t") ? name.slice(0, -1) : name);
  return path.startsWith("a/") || path.startsWith("b/") ? path.slice(2) : path;
}

/// The path of "a/x b/x", which is all a mode change or a binary file gives.
function sameName(rest: string): string | null {
  if (rest.startsWith('"')) {
    const end = rest.indexOf('" ', 1);
    return end > 0 ? stripPrefix(rest.slice(0, end + 1)) : null;
  }
  const length = (rest.length - 5) / 2;
  if (!Number.isInteger(length) || length < 1) return null;
  const path = rest.slice(2, 2 + length);
  return rest === `a/${path} b/${path}` ? path : null;
}

/// git's C-style quoting, undone: \" \\ \t \n and octal escapes for each byte.
export function unquote(name: string): string {
  if (!name.startsWith('"') || !name.endsWith('"')) return name;
  const bytes: number[] = [];
  const escapes: Record<string, number> = { n: 10, t: 9, r: 13, a: 7, b: 8, f: 12, v: 11, '"': 34, "\\": 92 };
  for (let i = 1; i < name.length - 1; i++) {
    const c = name[i];
    if (c !== "\\") {
      bytes.push(...Buffer.from(c, "utf8"));
      continue;
    }
    const next = name[i + 1];
    if (/[0-7]/.test(next)) {
      bytes.push(parseInt(name.slice(i + 1, i + 4), 8));
      i += 3;
    } else {
      bytes.push(escapes[next] ?? next.charCodeAt(0));
      i += 1;
    }
  }
  return Buffer.from(bytes).toString("utf8");
}

/// Takes hunks back out of the working tree, or puts them back in; the index and HEAD stay as
/// they are. git applies all of a patch or none of it, so a file that has moved on since the
/// review read it fails whole and nothing changes.
export async function applyPatch(cwd: string, patch: string, reverse: boolean, index = false): Promise<{ index: boolean }> {
  const root = await top(cwd);
  const direction = reverse ? ["-R"] : [];
  try {
    await gitRun(root, ["apply", ...direction, "--whitespace=nowarn", "--recount", "-"], { input: patch });
  } catch (error) {
    const message = (error as Error).message;
    if (/patch does not apply|does not match index|No such file|already exists/.test(message)) {
      throw new Error("The file has changed since the review read it. Look again and retry.");
    }
    throw error;
  }
  if (!index) return { index: false };
  // Hunks that were staged come out of the index too, or the next commit would bring them
  // back; where they weren't, git refuses and the index stays as it was.
  const staged = await gitRun(root, ["apply", "--cached", ...direction, "--whitespace=nowarn", "--recount", "-"], { input: patch }).then(
    () => true,
    () => false,
  );
  return { index: staged };
}

/// Puts files back as HEAD has them, in the working tree only. The app has already sent
/// whatever was there to the Trash.
export async function restore(cwd: string, paths: string[]): Promise<{ index: IndexEntry[] }> {
  if (!paths.length) return { index: [] };
  const root = await top(cwd);
  const index = await indexEntries(root, paths);
  // The index too: a file taken back from the working tree alone would stay staged, and the
  // next commit would bring it back.
  await gitRun(root, ["restore", "--source=HEAD", "--staged", "--worktree", "--", ...paths.map(literal)]);
  return { index };
}

/// Undoes restore's index side: each path gets back the entry it had, or none.
export async function unrestore(cwd: string, paths: string[], entries: IndexEntry[]): Promise<void> {
  const root = await top(cwd);
  const kept = new Set(entries.map((entry) => entry.path));
  const gone = paths.filter((path) => !kept.has(path));
  if (gone.length) await gitRun(root, ["update-index", "--force-remove", "--", ...gone]);
  if (entries.length) {
    await gitRun(root, ["update-index", "-z", "--index-info"], { input: entries.map((entry) => `${entry.mode} ${entry.sha}\t${entry.path}\0`).join("") });
  }
}

async function indexEntries(root: string, paths: string[]): Promise<IndexEntry[]> {
  const out = await gitRun(root, ["ls-files", "-s", "-z", "--", ...paths.map(literal)]);
  return out
    .split("\0")
    .filter(Boolean)
    .flatMap((line) => {
      const tab = line.indexOf("\t");
      const [mode, sha, stage] = line.slice(0, tab).split(" ");
      return stage === "0" ? [{ path: line.slice(tab + 1), mode, sha }] : [];
    });
}

/// Commits what was reviewed and nothing more: whole files as the working tree has them, and
/// hunks of the rest. It goes through an index of its own, so what's staged by hand stays
/// staged; afterwards the real index takes the new commit's version of the files it touched.
/// The working tree doesn't change.
export async function commitReviewed(
  cwd: string,
  { paths, patch, partial, message }: { paths: string[]; patch: string; partial: string[]; message: string },
): Promise<string> {
  if (!message.trim()) throw new Error("Write a commit message first.");
  if (!paths.length && !patch.trim()) throw new Error("Nothing is marked reviewed yet.");
  const root = await top(cwd);
  const index = join(tmpdir(), `oricode-index-${process.pid}-${Math.random().toString(36).slice(2)}`);
  const env = { GIT_INDEX_FILE: index };
  const before = await head(root);
  try {
    await gitRun(root, before ? ["read-tree", before] : ["read-tree", "--empty"], { env });
    // -f: a file force-added past .gitignore is still one to commit.
    if (paths.length) await gitRun(root, ["add", "-A", "-f", "--", ...paths.map(literal)], { env });
    if (patch.trim()) await gitRun(root, ["apply", "--cached", "--whitespace=nowarn", "--recount", "-"], { input: patch, env });
    // The tree is HEAD's plus what was reviewed; a commit landing on top of HEAD meanwhile would
    // be undone by it.
    if ((await head(root)) !== before) throw new Error(moved);
    await gitRun(root, ["commit", "-q", "-m", message], { env });
    const made = await head(root);
    const parent = await gitRun(root, ["rev-parse", "--verify", "-q", `${made}^`]).then(
      (out) => out.trim(),
      () => null,
    );
    if (made && parent !== before) {
      // One landed while the hooks ran: this commit goes, theirs stays.
      if (parent) await gitRun(root, ["update-ref", "HEAD", parent, made]);
      throw new Error(moved);
    }
    // The real index takes the new commit's version of whole files, and the committed hunks
    // on top of whatever was staged by hand in the rest.
    if (paths.length) await gitRun(root, ["reset", "-q", "--", ...paths.map(literal)]);
    if (patch.trim()) await gitRun(root, ["apply", "--cached", "--whitespace=nowarn", "--recount", "-"], { input: patch }).catch(() => {});
    return (await gitRun(root, ["rev-parse", "--short", "HEAD"])).trim();
  } finally {
    await rm(index, { force: true });
  }
}

const moved = "Another commit landed while this one was being made, so nothing was committed. Look again and retry.";

/// Every file the review shows, committed as the working tree has it.
export async function commitAll(cwd: string, paths: string[], message: string): Promise<string> {
  if (!paths.length) throw new Error("There's nothing to commit.");
  if (!message.trim()) throw new Error("Write a commit message first.");
  const root = await top(cwd);
  // A path gone from both the disk and the index, like a staged git rm or git mv's old name,
  // is one git add refuses; the commit's own pathspec takes its deletion.
  const present: string[] = [];
  for (const path of paths) {
    if (await lstat(join(root, path)).then(() => true, () => false)) present.push(path);
  }
  if (present.length) await gitRun(root, ["add", "-A", "--", ...present.map(literal)]);
  await gitRun(root, ["commit", "-q", "-m", message, "--", ...paths.map(literal)]);
  return (await gitRun(root, ["rev-parse", "--short", "HEAD"])).trim();
}
