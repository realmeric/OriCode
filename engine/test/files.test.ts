// The file viewer's reads and saves, in a scratch folder.
import { test } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { viewFile, writeProjectFile } from "../files.ts";

const scratch = (name: string) => mkdtemp(join(tmpdir(), `oricode-files-${name}-`));
const content = async (cwd: string, path: string) => {
  const viewed = await viewFile(cwd, path);
  assert.ok("content" in viewed);
  return viewed;
};

test("a save writes the file it read in place, and refuses one that changed on disk or lies outside the project", async () => {
  const dir = await mkdtemp(join(tmpdir(), "oricode-files-"));
  const file = join(dir, "run.sh");
  await writeFile(file, "echo one\n");
  await chmod(file, 0o755);
  const read = await content(dir, "run.sh");
  assert.equal(read.content, "echo one\n");
  const saved = await writeProjectFile(dir, "run.sh", "echo two\n", read.stamp!);
  assert.equal(await readFile(file, "utf8"), "echo two\n");
  assert.equal((await stat(file)).mode & 0o777, 0o755);
  assert.equal(saved.stamp, (await content(dir, "run.sh")).stamp);

  // Something else wrote it since: the stamp the app holds is old.
  await writeFile(file, "echo three\n");
  await utimes(file, new Date(), new Date(Date.now() + 5000));
  await assert.rejects(writeProjectFile(dir, "run.sh", "echo mine\n", saved.stamp), /run\.sh changed on disk since you opened it\./);
  assert.equal(await readFile(file, "utf8"), "echo three\n");

  const outside = join(await mkdtemp(join(tmpdir(), "oricode-files-out-")), "x");
  await writeFile(outside, "x\n");
  await assert.rejects(writeProjectFile(dir, outside, "y\n", "0 0"), /outside the project/);
});

test("a file an agent read outside the project opens to read, and nothing outside it can be saved", async () => {
  const dir = await scratch("project");
  const outside = join(await scratch("outside"), "notes.md");
  await writeFile(outside, "kept\n");

  const viewed = await content(dir, outside);
  assert.equal(viewed.content, "kept\n");
  // No stamp: what a save has to bring back is never given out.
  assert.equal(viewed.stamp, undefined);

  // The right stamp doesn't get a write through, and nor does a way in through the project.
  const info = await stat(outside);
  await assert.rejects(writeProjectFile(dir, outside, "gone\n", `${info.size} ${info.mtimeMs}`), /outside the project/);
  await symlink(outside, join(dir, "link.md"));
  assert.equal((await content(dir, "link.md")).stamp, undefined);
  await assert.rejects(writeProjectFile(dir, "link.md", "gone\n", `${info.size} ${info.mtimeMs}`), /outside the project/);
  assert.equal(await readFile(outside, "utf8"), "kept\n");
});

test("a thread whose folder has gone still opens what it read elsewhere, and saves nothing", async () => {
  const gone = join(await scratch("gone"), "worktree");
  const outside = join(await scratch("outside"), "notes.md");
  await writeFile(outside, "kept\n");
  assert.equal((await content(gone, outside)).content, "kept\n");
  const info = await stat(outside);
  await assert.rejects(writeProjectFile(gone, outside, "gone\n", `${info.size} ${info.mtimeMs}`), /outside the project/);
});

test("the viewer says plainly what it can't show", async () => {
  const dir = await scratch("project");
  await assert.rejects(viewFile(dir, "gone.txt"), /^Error: That file isn't there\.$/);
  await assert.rejects(viewFile(dir, "/tmp/oricode-no-such-folder/gone.jpg"), /^Error: That file isn't there\.$/);

  await mkdir(join(dir, "src"));
  await assert.rejects(viewFile(dir, "src"), /src is a folder\./);
  const folder = await scratch("outside");
  await assert.rejects(viewFile(dir, folder), /is a folder\./);

  const locked = join(folder, "locked");
  await writeFile(locked, "x");
  await chmod(locked, 0);
  await assert.rejects(viewFile(dir, locked), /isn't allowed to read that file/);
  await chmod(locked, 0o600);
  await rm(locked);

  // A device reads for ever, and a read of one would never come back.
  await assert.rejects(viewFile(dir, "/dev/zero"), /isn't a file\./);
});

test("what isn't text comes back as a path, to be looked at, and is never read as words", async () => {
  const dir = await scratch("project");
  const picture = join(await scratch("outside"), "sheet.jpg");
  await writeFile(picture, Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]));
  const viewed = await viewFile(dir, picture);
  assert.ok("binary" in viewed);
  assert.equal(viewed.full, viewed.path);
  assert.match(viewed.full, /sheet\.jpg$/);

  await writeFile(join(dir, "blob.bin"), Buffer.from([1, 0, 2]));
  assert.deepEqual(await viewFile(dir, "blob.bin"), { path: "blob.bin", binary: true, full: join(await realpath(dir), "blob.bin") });
});

test("a large file is cut at 1 MB and isn't read past it", async () => {
  const dir = await scratch("project");
  const big = join(dir, "big.log");
  await writeFile(big, Buffer.alloc(3 * 1024 * 1024, 0x61));
  const viewed = await content(dir, "big.log");
  assert.equal(viewed.truncated, true);
  assert.equal(viewed.content.length, 1024 * 1024);

  await writeFile(join(dir, "empty"), "");
  assert.equal((await content(dir, "empty")).content, "");
});

test("a login or a key outside the project isn't opened, on anyone's word", async () => {
  const dir = await mkdtemp(join(tmpdir(), "oricode-files-"));
  const home = await mkdtemp(join(tmpdir(), "oricode-logins-"));
  for (const path of [".codex/auth.json", ".claude/.credentials.json", ".gemini/oauth_creds.json", ".ssh/id_ed25519", ".oripass/agent.sock"]) {
    await mkdir(dirname(join(home, path)), { recursive: true });
    await writeFile(join(home, path), "secret");
    await assert.rejects(viewFile(dir, join(home, path)), /^Error: OriCode doesn't open login files\.$/);
  }
  await writeFile(join(home, "notes.json"), "fine");
  assert.equal(((await viewFile(dir, join(home, "notes.json"))) as { content: string }).content, "fine");
  // A project's own file of that name is the project's.
  await writeFile(join(dir, "auth.json"), "{}");
  assert.equal(((await viewFile(dir, "auth.json")) as { content: string }).content, "{}");
});
