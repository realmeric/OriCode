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

export async function commit(cwd: string, paths: string[], message: string): Promise<string> {
  if (!paths.length) throw new Error("Pick at least one file to commit.");
  if (!message.trim()) throw new Error("Write a commit message first.");
  await git(cwd, ["add", "-A", "--", ...paths]);
  await git(cwd, ["commit", "-m", message, "--", ...paths]);
  return (await git(cwd, ["rev-parse", "--short", "HEAD"])).trim();
}

export async function push(cwd: string): Promise<void> {
  const remotes = (await git(cwd, ["remote"])).trim();
  if (!remotes) throw new Error("This repository has no remote to push to.");
  const { upstream } = await branch(cwd);
  await git(cwd, upstream ? ["push"] : ["push", "-u", "origin", "HEAD"]);
}

/// What the commit would contain, for the message writer: the tracked diff and the start of
/// each new file, cut to keep the Haiku call small.
export async function diffFor(cwd: string, paths: string[]): Promise<string> {
  const files = await status(cwd);
  const chosen = new Set(paths);
  const parts: string[] = [];
  const tracked = files.filter((file) => chosen.has(file.path) && file.status !== "?").map((file) => file.path);
  if (tracked.length) parts.push(await git(cwd, ["diff", "HEAD", "--", ...tracked]));
  for (const file of files.filter((file) => chosen.has(file.path) && file.status === "?")) {
    const content = await git(cwd, ["show", `:${file.path}`]).catch(async () => {
      const { readFile } = await import("node:fs/promises");
      return (await readFile(`${cwd}/${file.path}`, "utf8").catch(() => "")).slice(0, 4000);
    });
    parts.push(`new file ${file.path}\n${content}`);
  }
  return parts.join("\n").slice(0, 60_000);
}
