// The file viewer's reads and saves, in a scratch folder.
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readProjectFile, writeProjectFile } from "../files.ts";

test("a save writes the file it read in place, and refuses one that changed on disk or lies outside the project", async () => {
  const dir = await mkdtemp(join(tmpdir(), "oricode-files-"));
  const file = join(dir, "run.sh");
  await writeFile(file, "echo one\n");
  await chmod(file, 0o755);
  const read = await readProjectFile(dir, "run.sh");
  assert.equal(read.content, "echo one\n");
  const saved = await writeProjectFile(dir, "run.sh", "echo two\n", read.stamp);
  assert.equal(await readFile(file, "utf8"), "echo two\n");
  assert.equal((await stat(file)).mode & 0o777, 0o755);
  assert.equal(saved.stamp, (await readProjectFile(dir, "run.sh")).stamp);

  // Something else wrote it since: the stamp the app holds is old.
  await writeFile(file, "echo three\n");
  await utimes(file, new Date(), new Date(Date.now() + 5000));
  await assert.rejects(writeProjectFile(dir, "run.sh", "echo mine\n", saved.stamp), /run\.sh changed on disk since you opened it\./);
  assert.equal(await readFile(file, "utf8"), "echo three\n");

  const outside = join(await mkdtemp(join(tmpdir(), "oricode-files-out-")), "x");
  await writeFile(outside, "x\n");
  await assert.rejects(writeProjectFile(dir, outside, "y\n", "0 0"), /outside the project/);
});
