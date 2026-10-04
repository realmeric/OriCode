import { readFile, realpath, stat, writeFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { git } from "./git.ts";

/// Tracked and untracked-but-not-ignored files, the same set a person would search.
export async function listFiles(cwd: string): Promise<string[]> {
  const out = await git(cwd, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]);
  return [...new Set(out.split("\0").filter(Boolean))];
}

const limit = 1024 * 1024;

/// The file's real path and its path from the project's top, which it has to be under.
async function inProject(cwd: string, path: string): Promise<{ full: string; inside: string }> {
  // Real paths on both sides: /tmp and /private/tmp are one folder, and so is a symlinked checkout.
  const root = await realpath(cwd);
  const full = await realpath(isAbsolute(path) ? path : resolve(cwd, path));
  const inside = relative(root, full);
  if (inside.startsWith("..") || isAbsolute(inside)) throw new Error("That file is outside the project.");
  return { full, inside };
}

/// A file's size and date, which say whether it's still the file that was read.
const stampOf = (info: { size: number; mtimeMs: number }) => `${info.size} ${info.mtimeMs}`;

/// A file inside the project, cut at 1 MB, with the stamp a save has to bring back.
export async function readProjectFile(cwd: string, path: string): Promise<{ path: string; content: string; truncated: boolean; stamp: string }> {
  const { full, inside } = await inProject(cwd, path);
  const info = await stat(full);
  if (info.isDirectory()) throw new Error(`${inside} is a folder.`);
  const buffer = await readFile(full);
  const slice = buffer.subarray(0, limit);
  if (slice.includes(0)) throw new Error(`${inside} isn't text.`);
  return { path: inside, content: slice.toString("utf8"), truncated: buffer.length > limit, stamp: stampOf(info) };
}

/// Saves a file the app read and the user edited, in place, so its mode and its links hold. One
/// that changed on disk since, an agent's edit say, is left as it is and said to have changed.
export async function writeProjectFile(cwd: string, path: string, content: string, stamp: string): Promise<{ stamp: string }> {
  const { full, inside } = await inProject(cwd, path);
  if (stampOf(await stat(full)) !== stamp) throw new Error(`${inside} changed on disk since you opened it. Open it again to edit what's there now.`);
  await writeFile(full, content);
  return { stamp: stampOf(await stat(full)) };
}
