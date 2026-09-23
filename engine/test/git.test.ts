// Branches as ⌘K works them, on scratch repositories: nothing here touches Claude or a real repo.
import { test, before } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, realpath, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { branches, create, friendly, git, previous, pull, remote, switchTo, webURL } from "../git.ts";

before(() => {
  // The user's own git settings (signing, hooks, a default branch name) stay out of it.
  Object.assign(process.env, {
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1",
    GIT_AUTHOR_NAME: "Test",
    GIT_AUTHOR_EMAIL: "test@example.com",
    GIT_COMMITTER_NAME: "Test",
    GIT_COMMITTER_EMAIL: "test@example.com",
  });
});

async function repo(): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "oricode-git-"));
  await git(dir, ["init", "-q", "-b", "main"]);
  await writeFile(join(dir, "f"), "one\n");
  await git(dir, ["add", "f"]);
  await git(dir, ["commit", "-q", "-m", "one"]);
  return dir;
}

test("create makes the branch and switches to it, and switch goes back", async () => {
  const dir = await repo();
  assert.equal((await create(dir, "try-me")).branch, "try-me");
  assert.equal((await switchTo(dir, "main")).branch, "main");
  const listed = await branches(dir);
  assert.equal(listed.current, "main");
  assert.deepEqual(listed.branches.map((item) => item.name).sort(), ["main", "try-me"]);
});

test("names git wouldn't take are refused in plain words, and so is one that exists", async () => {
  const dir = await repo();
  for (const name of ["bad name", "-foo", "@{-1}", "a..b"]) {
    await assert.rejects(create(dir, name), /isn't a name git takes for a branch/);
  }
  await assert.rejects(create(dir, "main"), /A branch named main already exists/);
});

test("a switch that would overwrite changes says which files, in one line", async () => {
  const dir = await repo();
  await create(dir, "other");
  await writeFile(join(dir, "f"), "two\n");
  await git(dir, ["commit", "-q", "-am", "two"]);
  await switchTo(dir, "main");
  await writeFile(join(dir, "f"), "dirty\n");
  await assert.rejects(switchTo(dir, "other"), (error: Error) => {
    assert.equal(error.message, "Uncommitted changes to f would be overwritten. Commit or stash them first.");
    return true;
  });
});

test("a branch open in another worktree is listed with it, and switching to it says so", async () => {
  const dir = await repo();
  const elsewhere = join(dir, ".worktrees", "t");
  await git(dir, ["worktree", "add", "-q", "-b", "oricode/t", elsewhere]);
  const listed = await branches(dir);
  // git reports the real path, which for the temporary folder starts with /private.
  assert.equal(listed.branches.find((item) => item.name === "oricode/t")?.elsewhere, await realpath(elsewhere));
  assert.equal(listed.branches.find((item) => item.name === "main")?.elsewhere, null);
  await assert.rejects(switchTo(dir, "oricode/t"), /oricode\/t is checked out in another worktree/);
});

test("previous goes back, and says so when there's nothing to go back to", async () => {
  const dir = await repo();
  await assert.rejects(previous(dir), /There's no previous branch here|previous/);
  await create(dir, "next");
  assert.equal((await previous(dir)).branch, "main");
});

test("pull fast-forwards and counts, and a branch without an upstream says so", async () => {
  const origin = await repo();
  const clone = await mkdtemp(join(tmpdir(), "oricode-clone-"));
  await git(clone, ["clone", "-q", origin, "."]);
  await writeFile(join(origin, "f"), "two\n");
  await git(origin, ["commit", "-q", "-am", "two"]);
  assert.equal((await pull(clone)).summary, "Pulled 1 commit.");
  assert.equal((await pull(clone)).summary, "Already up to date.");
  await create(clone, "local");
  await assert.rejects(pull(clone), /no upstream|no tracking/i);
});

test("remote gives the web page for the usual remote spellings", async () => {
  assert.equal(webURL("git@github.com:realmeric/oricode.git"), "https://github.com/realmeric/oricode");
  assert.equal(webURL("ssh://git@github.com/realmeric/oricode"), "https://github.com/realmeric/oricode");
  assert.equal(webURL("https://github.com/realmeric/oricode.git"), "https://github.com/realmeric/oricode");
  assert.equal(webURL("/some/local/path"), null);
  const dir = await repo();
  assert.deepEqual(await remote(dir), { web: null });
  await git(dir, ["remote", "add", "origin", "git@github.com:realmeric/oricode.git"]);
  assert.deepEqual(await remote(dir), { web: "https://github.com/realmeric/oricode" });
});

test("anything else keeps git's first line without its prefix", () => {
  assert.equal(friendly("fatal: something odd\nmore detail"), "something odd");
  assert.equal(friendly("fatal: invalid reference: nope"), "There's no branch called nope.");
});
