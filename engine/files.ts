import { open, realpath, stat, writeFile } from "node:fs/promises";
import { isAbsolute, relative, resolve } from "node:path";
import { git } from "./git.ts";

/// Tracked and untracked-but-not-ignored files, the same set a person would search.
export async function listFiles(cwd: string): Promise<string[]> {
  const out = await git(cwd, ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]);
  return [...new Set(out.split("\0").filter(Boolean))];
}

const limit = 1024 * 1024;

/// A failed look at a file, in the viewer's words where they're plainer than the system's.
function plainly(error: NodeJS.ErrnoException): never {
  if (error.code === "ENOENT") throw new Error("That file isn't there.");
  if (error.code === "EACCES" || error.code === "EPERM") throw new Error("OriCode isn't allowed to read that file.");
  throw error;
}

/// The file's real path and its path from the project's top, null when it lies outside it.
async function locate(cwd: string, path: string): Promise<{ full: string; inside: string | null }> {
  const full = await realpath(isAbsolute(path) ? path : resolve(cwd, path)).catch(plainly);
  // Real paths on both sides: /tmp and /private/tmp are one folder, and so is a symlinked checkout.
  // A thread whose worktree has gone still has the files it read elsewhere.
  const root = await realpath(cwd).catch(() => null);
  if (root === null) return { full, inside: null };
  const inside = relative(root, full);
  return { full, inside: inside.startsWith("..") || isAbsolute(inside) ? null : inside };
}

/// A file's size and date, which say whether it's still the file that was read.
const stampOf = (info: { size: number; mtimeMs: number }) => `${info.size} ${info.mtimeMs}`;

/// Where a login or a key lives outside a project: rule 3 holds for a path an agent read or asked
/// to show, so the engine doesn't open these on anyone's word.
const logins = /\/(\.ssh|\.oripass|\.aws|\.gnupg)\/|\/(\.?credentials\.json|auth\.json|oauth_creds\.json)$/;

type Viewed = { path: string; content: string; truncated: boolean; stamp?: string } | { path: string; binary: true; full: string };

/// A file for the viewer to show, cut at 1 MB. A file in the project comes with the stamp a save
/// has to bring back; an agent can read anywhere, so one outside opens too, without a stamp, to
/// read and never to save. What isn't text comes back as its real path for the app to look at.
export async function viewFile(cwd: string, path: string): Promise<Viewed> {
  const { full, inside } = await locate(cwd, path);
  const name = inside ?? full;
  if (inside === null && logins.test(full)) throw new Error("OriCode doesn't open login files.");
  const info = await stat(full).catch(plainly);
  if (info.isDirectory()) throw new Error(`${name} is a folder.`);
  // A device or a pipe, which would never finish reading.
  if (!info.isFile()) throw new Error(`${name} isn't a file.`);
  const file = await open(full).catch(plainly);
  try {
    // No more than is shown, however large what an agent read in /tmp may be.
    const { buffer, bytesRead } = await file.read(Buffer.alloc(Math.min(info.size, limit)), 0, Math.min(info.size, limit), 0);
    const slice = buffer.subarray(0, bytesRead);
    if (slice.includes(0)) return { path: name, binary: true, full };
    const stamp = inside === null ? {} : { stamp: stampOf(info) };
    return { path: name, content: slice.toString("utf8"), truncated: info.size > limit, ...stamp };
  } finally {
    await file.close();
  }
}

/// Saves a file the app read and the user edited, in place, so its mode and its links hold. One
/// that changed on disk since, an agent's edit say, is left as it is and said to have changed.
/// Nothing outside the project is written, whatever opens in the viewer.
export async function writeProjectFile(cwd: string, path: string, content: string, stamp: string): Promise<{ stamp: string }> {
  const { full, inside } = await locate(cwd, path);
  if (inside === null) throw new Error("That file is outside the project.");
  if (stampOf(await stat(full)) !== stamp) throw new Error(`${inside} changed on disk since you opened it. Open it again to edit what's there now.`);
  await writeFile(full, content);
  return { stamp: stampOf(await stat(full)) };
}
