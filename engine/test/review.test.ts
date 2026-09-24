// The review's git, on scratch repositories: nothing here touches Claude or a real repo.
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, rename, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { git } from "../git.ts";
import { applyPatch, commitAll, commitReviewed, parsePatch, restore, unquote, unrestore, workingDiff, type FileDiff, type Hunk } from "../review.ts";

before(() => {
  Object.assign(process.env, {
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "Test",
    GIT_AUTHOR_EMAIL: "test@example.com",
    GIT_COMMITTER_NAME: "Test",
    GIT_COMMITTER_EMAIL: "test@example.com",
  });
});

const numbered = (count: number, from = 1) => Array.from({ length: count }, (_, i) => `line ${i + from}`).join("\n") + "\n";

async function repo(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "oricode-review-"));
  await git(dir, ["init", "-q", "-b", "main"]);
  for (const [path, content] of Object.entries(files)) {
    await mkdir(join(dir, path, ".."), { recursive: true });
    await writeFile(join(dir, path), content);
  }
  if (Object.keys(files).length) {
    await git(dir, ["add", "-A"]);
    await git(dir, ["commit", "-q", "-m", "start"]);
  }
  return dir;
}

/// The patch the app builds for some of a file's hunks: git's own header for the path, then the hunks.
function patchOf(path: string, hunks: Hunk[]): string {
  const body = hunks.map((hunk) => `@@ -${hunk.oldStart},${hunk.oldLines} +${hunk.newStart},${hunk.newLines} @@\n${hunk.lines.join("\n")}\n`).join("");
  return `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n${body}`;
}

function file(diff: { files: FileDiff[] }, path: string): FileDiff {
  const found = diff.files.find((item) => item.path === path);
  assert.ok(found, `${path} isn't in the diff: ${diff.files.map((item) => item.path).join(", ")}`);
  return found;
}

test("modified, new, deleted and renamed files, and awkward names, come back with their hunks", async () => {
  const dir = await repo({
    "a.txt": numbered(10),
    "gone.txt": "bye\n",
    "old name.txt": numbered(20),
    "ünï code.txt": "one\n",
    "bin.dat": "x",
  });
  await writeFile(join(dir, "a.txt"), numbered(10).replace("line 2\n", "line two\n"));
  await git(dir, ["rm", "-q", "gone.txt"]);
  await git(dir, ["mv", "old name.txt", "new name.txt"]);
  await writeFile(join(dir, "new name.txt"), numbered(20).replace("line 19", "line nineteen"));
  await writeFile(join(dir, "ünï code.txt"), "one\ntwo");
  await writeFile(join(dir, "bin.dat"), Buffer.from([0, 1, 2, 3]));
  await writeFile(join(dir, "fresh.sh"), "#!/bin/sh\necho hi\n");
  await chmod(join(dir, "fresh.sh"), 0o755);

  const diff = await workingDiff(dir);
  const a = file(diff, "a.txt");
  assert.equal(a.status, "M");
  assert.deepEqual([a.added, a.deleted], [1, 1]);
  assert.deepEqual(a.hunks[0].lines.filter((line) => line[0] !== " "), ["-line 2", "+line two"]);
  assert.equal(file(diff, "gone.txt").status, "D");
  const renamed = file(diff, "new name.txt");
  assert.equal(renamed.status, "R");
  assert.equal(renamed.oldPath, "old name.txt");
  assert.deepEqual(renamed.hunks[0].lines.filter((line) => line[0] !== " "), ["-line 19", "+line nineteen"]);
  const unicode = file(diff, "ünï code.txt");
  assert.deepEqual(unicode.hunks[0].lines, [" one", "+two", "\\ No newline at end of file"]);
  assert.equal(file(diff, "bin.dat").binary, true);
  const fresh = file(diff, "fresh.sh");
  assert.equal(fresh.status, "?");
  assert.equal(fresh.executable, true);
  assert.deepEqual(fresh.hunks[0], { oldStart: 0, oldLines: 0, newStart: 1, newLines: 2, context: "", lines: ["+#!/bin/sh", "+echo hi"] });
  // What can't be shown line by line carries a stamp that moves when the file does.
  const stamped = file(diff, "bin.dat").stamp;
  assert.match(stamped ?? "", /^4:/);
  assert.equal(a.stamp, null);
});

test("from a folder inside the repository, paths are still from its top", async () => {
  const dir = await repo({ "app/x.txt": "one\n", "server/y.txt": "one\n" });
  await writeFile(join(dir, "app/x.txt"), "two\n");
  await writeFile(join(dir, "server/y.txt"), "two\n");
  const diff = await workingDiff(join(dir, "app"));
  assert.deepEqual(diff.files.map((item) => item.path).sort(), ["app/x.txt", "server/y.txt"]);
  // And committing from there takes those same paths.
  await commitAll(join(dir, "app"), ["app/x.txt"], "just app");
  assert.deepEqual((await workingDiff(dir)).files.map((item) => item.path), ["server/y.txt"]);
});

test("a repository with no commits shows everything as new", async () => {
  const dir = await repo({});
  await writeFile(join(dir, "first.txt"), "hello\n");
  await writeFile(join(dir, "staged.txt"), "staged\n");
  await git(dir, ["add", "staged.txt"]);
  const diff = await workingDiff(dir);
  assert.equal(file(diff, "first.txt").status, "?");
  assert.equal(file(diff, "staged.txt").status, "A");
  assert.deepEqual(file(diff, "staged.txt").hunks[0].lines, ["+staged"]);
});

test("a huge file keeps its counts and leaves its hunks out", async () => {
  const dir = await repo({ "small.txt": "a\n", "big.txt": "x\n" });
  await writeFile(join(dir, "big.txt"), numbered(5000));
  await writeFile(join(dir, "small.txt"), "b\n");
  await writeFile(join(dir, "big-new.txt"), numbered(6000));
  const diff = await workingDiff(dir);
  const big = file(diff, "big.txt");
  assert.equal(big.cut, true);
  assert.equal(big.hunks.length, 0);
  assert.equal(big.added, 5000);
  assert.equal(file(diff, "small.txt").hunks.length, 1);
  assert.equal(file(diff, "big-new.txt").cut, true);
  assert.equal(file(diff, "big-new.txt").added, 6000);
});

test("one hunk goes back and comes again, and a patch the file has moved past is refused", async () => {
  const dir = await repo({ "a.txt": numbered(40) });
  const edited = numbered(40).replace("line 3\n", "line three\n").replace("line 35\n", "line thirty-five\n");
  await writeFile(join(dir, "a.txt"), edited);
  const [, second] = file(await workingDiff(dir), "a.txt").hunks;
  const patch = patchOf("a.txt", [second]);

  await applyPatch(dir, patch, true);
  assert.equal(await readFile(join(dir, "a.txt"), "utf8"), numbered(40).replace("line 3\n", "line three\n"));
  await applyPatch(dir, patch, false);
  assert.equal(await readFile(join(dir, "a.txt"), "utf8"), edited);

  await writeFile(join(dir, "a.txt"), edited.replace("line thirty-five", "line 35 again"));
  await assert.rejects(applyPatch(dir, patch, true), /changed since the review read it/);
  assert.match(await readFile(join(dir, "a.txt"), "utf8"), /line 35 again/);
});

test("restore puts a file back as HEAD has it, and leaves what else is staged alone", async () => {
  const dir = await repo({ "a.txt": "one\n", "b.txt": "two\n" });
  await writeFile(join(dir, "a.txt"), "changed\n");
  await git(dir, ["rm", "-q", "--cached", "b.txt"]);
  await restore(dir, ["a.txt"]);
  assert.equal(await readFile(join(dir, "a.txt"), "utf8"), "one\n");
  assert.match(await git(dir, ["status", "--porcelain=v1"]), /^D  b\.txt$/m);
});

test("committing what was reviewed takes those hunks and files only, and leaves the rest as it was", async () => {
  const dir = await repo({ "a.txt": numbered(40), "b.txt": "b\n", "c.txt": "c\n" });
  await writeFile(join(dir, "a.txt"), numbered(40).replace("line 3\n", "line three\n").replace("line 35\n", "line thirty-five\n"));
  await writeFile(join(dir, "new.txt"), "new\n");
  await writeFile(join(dir, "b.txt"), "b changed\n");
  // Staged by hand, and not reviewed: it stays staged.
  await writeFile(join(dir, "c.txt"), "c staged\n");
  await git(dir, ["add", "c.txt"]);
  const before = await workingDiff(dir);
  const [first] = file(before, "a.txt").hunks;

  const hash = await commitReviewed(dir, { paths: ["new.txt"], patch: patchOf("a.txt", [first]), partial: ["a.txt"], message: "Reviewed part" });
  assert.match(hash, /^[0-9a-f]+$/);
  assert.equal(await git(dir, ["show", "HEAD:a.txt"]), numbered(40).replace("line 3\n", "line three\n"));
  assert.equal(await git(dir, ["show", "HEAD:new.txt"]), "new\n");
  assert.equal((await git(dir, ["show", "--name-only", "--format=", "HEAD"])).trim().split("\n").sort().join(","), "a.txt,new.txt");
  // Nothing on disk moved, and the rest is still there to review or commit.
  assert.match(await readFile(join(dir, "a.txt"), "utf8"), /line thirty-five/);
  const after = await workingDiff(dir);
  assert.deepEqual(after.files.map((item) => item.path).sort(), ["a.txt", "b.txt", "c.txt"]);
  assert.deepEqual(file(after, "a.txt").hunks.map((hunk) => hunk.lines.filter((line) => line[0] !== " ")), [["-line 35", "+line thirty-five"]]);
  const status = await git(dir, ["status", "--porcelain=v1"]);
  assert.match(status, /^ M a\.txt$/m);
  assert.match(status, /^M  c\.txt$/m);
});

test("a hunk's end is found by its counts, not by what its lines look like", () => {
  const patch = [
    "diff --git a/x.md b/x.md",
    "--- a/x.md",
    "+++ b/x.md",
    "@@ -1,2 +1,3 @@",
    " intro",
    "+diff --git a/fake b/fake",
    "-@@ -1 +1 @@",
    "+@@ -9 +9 @@",
    "",
    "diff --git a/y.txt b/y.txt",
    "--- a/y.txt",
    "+++ b/y.txt",
    "@@ -1 +1 @@",
    "-a",
    "+b",
    "",
  ].join("\n");
  const chunks = parsePatch(patch);
  assert.deepEqual(chunks.map((chunk) => chunk.path), ["x.md", "y.txt"]);
  assert.deepEqual(chunks[0].hunks[0].lines, [" intro", "+diff --git a/fake b/fake", "-@@ -1 +1 @@", "+@@ -9 +9 @@"]);
});

test("git's quoted names come back as they were", () => {
  assert.equal(unquote('"tab\\there"'), "tab\there");
  assert.equal(unquote('"\\303\\274ber"'), "über");
  assert.equal(unquote('"say \\"hi\\""'), 'say "hi"');
  assert.equal(unquote("plain name"), "plain name");
});

test("taking a staged add, a git rm and a git mv back puts the index back too, and undoing it restores all three", async () => {
  const dir = await repo({ "gone.txt": "gone\n", "old.txt": "old\n" });
  await writeFile(join(dir, "new.txt"), "new\n");
  await git(dir, ["add", "new.txt"]);
  await git(dir, ["rm", "-q", "gone.txt"]);
  await git(dir, ["mv", "old.txt", "moved.txt"]);
  const before = await git(dir, ["status", "--porcelain=v1"]);
  // The app sends what's on disk at those paths to the Trash first; a folder stands in for it.
  const trash = await mkdtemp(join(tmpdir(), "oricode-trash-"));
  await rename(join(dir, "new.txt"), join(trash, "new.txt"));
  await rename(join(dir, "moved.txt"), join(trash, "moved.txt"));
  const paths = ["new.txt", "gone.txt", "old.txt", "moved.txt"];
  const { index } = await restore(dir, paths);
  assert.equal(await git(dir, ["status", "--porcelain=v1"]), "");
  // Undo: HEAD's versions go, the index entries come back, and the files come out of the Trash.
  await rm(join(dir, "gone.txt"));
  await rm(join(dir, "old.txt"));
  await unrestore(dir, paths, index);
  await rename(join(trash, "new.txt"), join(dir, "new.txt"));
  await rename(join(trash, "moved.txt"), join(dir, "moved.txt"));
  assert.equal(await git(dir, ["status", "--porcelain=v1"]), before);
});

test("a hunk that was staged comes out of the index too, and one that wasn't leaves the index alone", async () => {
  const dir = await repo({ "a.txt": numbered(40) });
  const edited = numbered(40).replace("line 3\n", "line three\n").replace("line 35\n", "line thirty-five\n");
  await writeFile(join(dir, "a.txt"), edited);
  await git(dir, ["add", "a.txt"]);
  const [first] = file(await workingDiff(dir), "a.txt").hunks;
  assert.deepEqual(await applyPatch(dir, patchOf("a.txt", [first]), true, true), { index: true });
  assert.doesNotMatch(await git(dir, ["show", ":a.txt"]), /line three/);
  assert.match(await git(dir, ["show", ":a.txt"]), /line thirty-five/);
  // Put back, to the index as well.
  await applyPatch(dir, patchOf("a.txt", [first]), false, true);
  assert.equal(await git(dir, ["show", ":a.txt"]), edited);

  const other = await repo({ "b.txt": numbered(10) });
  await writeFile(join(other, "b.txt"), numbered(10).replace("line 2\n", "line two\n"));
  const [hunk] = file(await workingDiff(other), "b.txt").hunks;
  assert.deepEqual(await applyPatch(other, patchOf("b.txt", [hunk]), true, true), { index: false });
  assert.equal(await git(other, ["status", "--porcelain=v1"]), "");
});

test("Commit takes a staged git rm and a git mv", async () => {
  const dir = await repo({ "gone.txt": "gone\n", "old.txt": "old\n" });
  await git(dir, ["rm", "-q", "gone.txt"]);
  await git(dir, ["mv", "old.txt", "moved.txt"]);
  await writeFile(join(dir, "new.txt"), "new\n");
  const diff = await workingDiff(dir);
  const paths = diff.files.flatMap((item) => [item.oldPath, item.path]).filter((path): path is string => !!path);
  await commitAll(dir, paths, "Tidy");
  assert.equal(await git(dir, ["status", "--porcelain=v1"]), "");
  assert.equal((await git(dir, ["ls-files"])).trim().split("\n").sort().join(","), "moved.txt,new.txt");
});

test("committing what was reviewed keeps hand-staged hunks of the same file staged, and takes a force-added file", async () => {
  const dir = await repo({ "a.txt": numbered(40), ".gitignore": "*.log\n" });
  const edited = numbered(40).replace("line 3\n", "line three\n").replace("line 35\n", "line thirty-five\n");
  // The second hunk is staged by hand; the first is reviewed and committed.
  await writeFile(join(dir, "a.txt"), numbered(40).replace("line 35\n", "line thirty-five\n"));
  await git(dir, ["add", "a.txt"]);
  await writeFile(join(dir, "a.txt"), edited);
  await writeFile(join(dir, "kept.log"), "forced\n");
  await git(dir, ["add", "-f", "kept.log"]);
  const [first] = file(await workingDiff(dir), "a.txt").hunks;
  await commitReviewed(dir, { paths: ["kept.log"], patch: patchOf("a.txt", [first]), partial: ["a.txt"], message: "Reviewed" });
  assert.equal(await git(dir, ["show", "HEAD:a.txt"]), numbered(40).replace("line 3\n", "line three\n"));
  assert.equal(await git(dir, ["show", "HEAD:kept.log"]), "forced\n");
  assert.equal(await git(dir, ["show", ":a.txt"]), edited);
});

test("a file that isn't UTF-8 is lossy, so nothing writes its lines back", async () => {
  const dir = await repo({ "latin.txt": "cafe\n" });
  await writeFile(join(dir, "latin.txt"), Buffer.from([0x63, 0x61, 0x66, 0xe9, 0x0a]));
  await writeFile(join(dir, "fresh.txt"), Buffer.from([0x4a, 0x6f, 0x73, 0xe9, 0x0a]));
  const diff = await workingDiff(dir);
  assert.equal(file(diff, "latin.txt").lossy, true);
  assert.equal(file(diff, "fresh.txt").lossy, true);
});

test("a hunk whose function line holds a carriage return is still a hunk", () => {
  const patch = ["diff --git a/x.c b/x.c", "--- a/x.c", "+++ b/x.c", "@@ -1 +1 @@ int f()\r", "-a", "+b", ""].join("\n");
  assert.equal(parsePatch(patch)[0].hunks.length, 1);
});

