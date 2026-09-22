import { readFile, realpath, stat } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { git } from "./git.ts";

/// Tracked and untracked-but-not-ignored files, the same set a person would search.
export async function listFiles(cwd: string): Promise<string[]> {
  const out = await git(cwd, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]);
  return [...new Set(out.split("\0").filter(Boolean))];
}

const limit = 1024 * 1024;

/// A file inside the project, read-only, cut at 1 MB.
export async function readProjectFile(cwd: string, path: string): Promise<{ path: string; content: string; truncated: boolean }> {
  // Real paths on both sides: /tmp and /private/tmp are one folder, and so is a symlinked checkout.
  const root = await realpath(cwd);
  const full = await realpath(isAbsolute(path) ? path : resolve(cwd, path));
  const inside = relative(root, full);
  if (inside.startsWith("..") || isAbsolute(inside)) throw new Error("That file is outside the project.");
  const info = await stat(full);
  if (info.isDirectory()) throw new Error(`${inside} is a folder.`);
  const buffer = await readFile(full);
  const slice = buffer.subarray(0, limit);
  if (slice.includes(0)) throw new Error(`${inside} isn't text.`);
  return { path: inside, content: slice.toString("utf8"), truncated: buffer.length > limit };
}
