import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/// Git for the app, which has no shell of its own. Every call runs in the thread's cwd.
export async function git(cwd: string, args: string[]): Promise<string> {
  try {
    const { stdout } = await run("git", args, { cwd, maxBuffer: 32 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } });
    return stdout;
  } catch (error) {
    const stderr = (error as { stderr?: string }).stderr?.trim();
    throw new Error(stderr || (error as Error).message);
  }
}

/// The branch and how many commits it has that its upstream doesn't.
export async function branch(cwd: string): Promise<{ branch: string; ahead: number; upstream: boolean }> {
  const name = (await git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
  try {
    const ahead = Number((await git(cwd, ["rev-list", "--count", "@{upstream}..HEAD"])).trim());
    return { branch: name, ahead, upstream: true };
  } catch {
    return { branch: name, ahead: 0, upstream: false };
  }
}

export type BranchInfo = {
  name: string;
  current: boolean;
  upstream: string | null;
  /// How far it is from its upstream, as git words it: "[ahead 2]", "[behind 1]", "[gone]".
  track: string;
  date: number;
  /// The worktree it's checked out in, when that isn't this one.
  elsewhere: string | null;
};

/// The local branches, latest commit first.
export async function branches(cwd: string): Promise<{ current: string | null; branches: BranchInfo[] }> {
  const top = (await git(cwd, ["rev-parse", "--show-toplevel"])).trim();
  const format = "%(refname:short)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(committerdate:unix)%00%(worktreepath)";
  const out = await git(cwd, ["for-each-ref", "--sort=-committerdate", `--format=${format}`, "refs/heads"]);
  const list = out
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const [name, head, upstream, track, date, worktree] = line.split("\0");
      return {
        name,
        current: head === "*",
        upstream: upstream || null,
        track: track ?? "",
        date: Number(date) || 0,
        elsewhere: worktree && worktree !== top ? worktree : null,
      };
    });
  return { current: list.find((item) => item.current)?.name ?? null, branches: list };
}

/// A name git takes for a branch, or a plain-words error. `@{-1}` and the like are refused: git
/// would read them as another branch's name.
async function checkName(cwd: string, name: string): Promise<void> {
  const refused = new Error(`“${name}” isn't a name git takes for a branch.`);
  const out = await git(cwd, ["check-ref-format", "--branch", name]).catch(() => {
    throw refused;
  });
  if (out.trim() !== name) throw refused;
}

/// Git's messages for a failed switch or pull, cut to one line that says what to do.
export function friendly(message: string): string {
  const overwritten = message.match(/would be overwritten by (?:checkout|merge):\n((?:\t.*\n?)+)/);
  if (overwritten) {
    const files = overwritten[1].split("\n").map((line) => line.trim()).filter(Boolean);
    const named = files.length > 3 ? `${files.slice(0, 3).join(", ")} and ${files.length - 3} more` : files.join(", ");
    return `Uncommitted changes to ${named} would be overwritten. Commit or stash them first.`;
  }
  const elsewhere = message.match(/'([^']+)' is already (?:used|checked out) by worktree at/);
  if (elsewhere) return `${elsewhere[1]} is checked out in another worktree.`;
  const missing = message.match(/invalid reference: (.+)/);
  if (missing) return missing[1].trim() === "@{-1}" || missing[1].trim() === "-" ? "There's no previous branch here." : `There's no branch called ${missing[1].trim()}.`;
  if (/Not possible to fast-forward|Diverging branches/i.test(message)) {
    return "The branch and its upstream have split; pull in the terminal to merge or rebase.";
  }
  if (/no tracking information/i.test(message)) return "This branch has no upstream to pull from.";
  const first = message.split("\n").map((line) => line.trim()).find(Boolean) ?? message;
  return first.replace(/^(fatal|error):\s*/i, "");
}

async function plainly(cwd: string, args: string[]): Promise<string> {
  try {
    return await git(cwd, args);
  } catch (error) {
    throw new Error(friendly((error as Error).message));
  }
}

export async function switchTo(cwd: string, name: string): Promise<{ branch: string; ahead: number; upstream: boolean }> {
  await checkName(cwd, name);
  await plainly(cwd, ["switch", name]);
  return branch(cwd);
}

export async function create(cwd: string, name: string, from?: string): Promise<{ branch: string; ahead: number; upstream: boolean }> {
  await checkName(cwd, name);
  const exists = await git(cwd, ["show-ref", "--verify", "--quiet", `refs/heads/${name}`]).then(
    () => true,
    () => false,
  );
  if (exists) throw new Error(`A branch named ${name} already exists.`);
  await plainly(cwd, ["switch", "-c", name, ...(from ? [from] : [])]);
  return branch(cwd);
}

export async function previous(cwd: string): Promise<{ branch: string; ahead: number; upstream: boolean }> {
  await plainly(cwd, ["switch", "-"]);
  return branch(cwd);
}

/// A fast-forward pull only: anything that would merge is the terminal's business.
export async function pull(cwd: string): Promise<{ summary: string; branch: string; ahead: number; upstream: boolean }> {
  const before = (await git(cwd, ["rev-parse", "HEAD"])).trim();
  await plainly(cwd, ["pull", "--ff-only"]);
  const count = Number((await git(cwd, ["rev-list", "--count", `${before}..HEAD`])).trim()) || 0;
  const summary = count === 0 ? "Already up to date." : `Pulled ${count} commit${count === 1 ? "" : "s"}.`;
  return { summary, ...(await branch(cwd)) };
}

/// The web page of the repository's origin, or of its first remote, when git can say.
export async function remote(cwd: string): Promise<{ web: string | null }> {
  const names = (await git(cwd, ["remote"])).split("\n").filter(Boolean);
  const name = names.includes("origin") ? "origin" : names[0];
  if (!name) return { web: null };
  const url = (await git(cwd, ["remote", "get-url", name])).trim();
  return { web: webURL(url) };
}

/// git@host:owner/repo.git, ssh://git@host/owner/repo and https://host/owner/repo.git all become
/// https://host/owner/repo.
export function webURL(remote: string): string | null {
  const scp = remote.match(/^[\w.-]+@([^:/]+):(.+?)(?:\.git)?\/?$/);
  if (scp) return `https://${scp[1]}/${scp[2]}`;
  const url = remote.match(/^(?:ssh|https?|git):\/\/(?:[^@/]+@)?([^/:]+)(?::\d+)?\/(.+?)(?:\.git)?\/?$/);
  if (url) return `https://${url[1]}/${url[2]}`;
  return null;
}

export type ChangedFile = { path: string; status: string };

/// Changed files from porcelain v1: "M" modified, "A" added, "D" deleted, "R" renamed, "?" untracked.
export async function status(cwd: string): Promise<ChangedFile[]> {
  const out = await git(cwd, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  const entries = out.split("\0").filter(Boolean);
  const files: ChangedFile[] = [];
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i];
    const code = entry.slice(0, 2);
    const path = entry.slice(3);
    // A rename carries its old path as the next entry.
    if (code.includes("R")) i++;
    const status = code === "??" ? "?" : (code.trim()[0] ?? "M");
    files.push({ path, status });
  }
  return files;
}

export async function push(cwd: string): Promise<void> {
  const remotes = (await git(cwd, ["remote"])).trim();
  if (!remotes) throw new Error("This repository has no remote to push to.");
  const { upstream } = await branch(cwd);
  await git(cwd, upstream ? ["push"] : ["push", "-u", "origin", "HEAD"]);
}

/// A new branch checked out in `.worktrees/<slug>` inside the project, kept out of the
/// project's status through .git/info/exclude rather than its .gitignore.
export async function addWorktree(root: string, slug: string): Promise<{ path: string; branch: string }> {
  const { appendFile, readFile } = await import("node:fs/promises");
  const gitDir = (await git(root, ["rev-parse", "--git-common-dir"])).trim();
  const exclude = `${gitDir.startsWith("/") ? gitDir : `${root}/${gitDir}`}/info/exclude`;
  const current = await readFile(exclude, "utf8").catch(() => "");
  if (!current.split("\n").includes("/.worktrees/")) {
    await appendFile(exclude, `${current.endsWith("\n") || !current ? "" : "\n"}/.worktrees/\n`);
  }
  const path = `${root}/.worktrees/${slug}`;
  const branchName = `oricode/${slug}`;
  await git(root, ["worktree", "add", "-b", branchName, path]);
  return { path, branch: branchName };
}

/// What removing a worktree would throw away: uncommitted files, and commits that no other
/// branch or remote has.
export async function worktreeLoss(path: string, branchName: string): Promise<{ dirty: number; unpushed: number }> {
  const dirty = (await status(path)).length;
  const unpushed = Number(
    (await git(path, ["rev-list", "--count", "HEAD", "--not", `--exclude=${branchName}`, "--branches", "--remotes"])).trim(),
  );
  return { dirty, unpushed };
}

export async function removeWorktree(root: string, path: string, branchName: string): Promise<void> {
  await git(root, ["worktree", "remove", "--force", path]);
  await git(root, ["branch", "-D", branchName]);
}
