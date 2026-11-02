import { rename, writeFile } from "node:fs/promises";

/// In place or not at all, so a quit halfway leaves the file it had.
export async function write(path: string, content: string): Promise<void> {
  const partial = `${path}.${process.pid}`;
  await writeFile(partial, content);
  await rename(partial, path);
}
