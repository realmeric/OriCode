// merge_thread and finish_merge through the real engine: a stand-in Codex in the opener's place,
// the test calling the tools over MCP as its agent would and answering the app's events as the app
// would, and the threads it opened as worktrees of a real repository.
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { engineWith, sandbox } from "./engine.ts";

const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, encoding: "utf8" });

async function mcp(url: string, method: string, params: object = {}): Promise<any> {
  const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  assert.equal(response.status, 200);
  return (await response.json()).result;
}

async function call(url: string, name: string, args: object = {}): Promise<any> {
  const result = await mcp(url, "tools/call", { name, arguments: args });
  const text = result.content[0].text;
  return result.isError ? { error: text } : JSON.parse(text);
}

/// A repository with one commit and an opener thread on a stand-in Codex working in it, with a
/// way to open a thread in a worktree of its own and to answer the app's events as the app would.
async function opener(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const log = join(await mkdtemp(join(tmpdir(), "oricode-merge-logs-")), "codex.log");
  const standIn = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${log}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${standIn}" "$@" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-merge-"));
  git(cwd, "init", "-q", "-b", "main");
  git(cwd, "config", "user.name", "Stand-in");
  git(cwd, "config", "user.email", "stand-in@example.com");
  await writeFile(join(cwd, "sum.py"), "def sum(a, b):\n    return a + b\n\nprint(sum(2, 3))\n");
  await writeFile(join(cwd, "README.md"), "# Sums\n");
  git(cwd, "add", "-A");
  git(cwd, "commit", "-q", "-m", "First");
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const turn = async (permissionMode = "default") => {
    const from = engine.lines.length;
    assert.deepEqual((await engine.request("send", { threadId: "lead", cwd, text: "hello", permissionMode, provider: "codex" })).result, { ok: true });
    await engine.until((line) => line.event === "turn.done" && line.threadId === "lead", from);
  };
  await turn();
  const started = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line)).find((message) => message.method === "thread/start");
  const url: string = started.params.config["mcp_servers.oricode"].url;
  const threads = new Map<string, { id: string; title: string; worktree: string; branch: string }>();
  const open = async (id: string, title: string, from?: string) => {
    const made = (await engine.request("worktree.add", { cwd, slug: id, prefix: "oricode/", ...(from ? { from } : {}) })).result;
    threads.set(id, { id, title, worktree: made.path, branch: made.branch });
    return made.path as string;
  };
  /// A tool call answered as the app answers it: thread.merge with where the thread is, and
  /// thread.merged with whether its worktree went, which it removes as the app does.
  const merging = async (name: string, args: object) => {
    const from = engine.lines.length;
    const calling = call(url, name, args);
    const told: any[] = [];
    let settled = false;
    calling.finally(() => (settled = true));
    while (!settled) {
      const asked = await Promise.race([engine.until((line) => (line.event === "thread.merge" || line.event === "thread.merged") && !told.includes(line), from), calling.then(() => null)]);
      if (!asked) break;
      told.push(asked);
      if (asked.event === "thread.merge") {
        const found = threads.get(asked.thread);
        await engine.request("app.reply", found ? { requestId: asked.requestId, result: { ...found, folder: cwd } } : { requestId: asked.requestId, error: `No thread of this project has the id ${asked.thread}.` });
      } else {
        const found = threads.get(asked.thread)!;
        if (!asked.unmerged) await engine.request("worktree.remove", { cwd, path: found.worktree, branch: found.branch });
        await engine.request("app.reply", { requestId: asked.requestId, result: { worktreeRemoved: !asked.unmerged } });
      }
    }
    return { answer: await calling, told };
  };
  return { engine, cwd, url, open, merging, turn };
}

/// Every file in the folder, worktrees left out, with what's in it, and git's own view of it.
async function folderState(cwd: string): Promise<Record<string, string>> {
  const state: Record<string, string> = {};
  const walk = async (dir: string) => {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      if (entry.name === ".git" || entry.name === ".worktrees") continue;
      const path = join(dir, entry.name);
      if (entry.isDirectory()) await walk(path);
      else state[relative(cwd, path)] = await readFile(path, "utf8");
    }
  };
  await walk(cwd);
  state["(status)"] = git(cwd, "status", "--porcelain", "--untracked-files=all");
  state["(index)"] = git(cwd, "ls-files", "-s");
  state["(head)"] = git(cwd, "rev-parse", "HEAD");
  return state;
}

test("an opener merges two threads that edited different files, both arrive uncommitted beside its own, and their worktrees go", async (t) => {
  const { cwd, url, open, merging } = await opener(t);
  const tools = (await mcp(url, "tools/list")).tools.map((tool: { name: string }) => tool.name);
  assert.equal(tools.includes("merge_thread") && tools.includes("finish_merge"), true);
  // The opener's own edit, uncommitted, and a file of its own.
  await writeFile(join(cwd, "README.md"), "# Sums\n\nAdds two numbers.\n");
  const primes = await open("t-primes", "Write primes.py");
  await writeFile(join(primes, "primes.py"), "print([2, 3, 5, 7])\n");
  // Committed by the thread itself, then a second edit it left uncommitted.
  git(primes, "add", "-A");
  git(primes, "commit", "-q", "-m", "primes");
  await writeFile(join(primes, "primes.py"), "print([2, 3, 5, 7, 11])\n");
  const words = await open("t-words", "Write words.sh");
  await writeFile(join(words, "words.sh"), "wc -w README.md\n");

  const first = await merging("merge_thread", { thread: "t-primes" });
  assert.deepEqual(first.answer, { thread: "Write primes.py", id: "t-primes", branch: "oricode/t-primes", merged: true, files: [{ path: "primes.py", added: 1, deleted: 0 }], summary: "1 file, +1 −0", worktreeRemoved: true });
  assert.deepEqual(first.told.map((line) => [line.event, line.thread, line.unmerged ?? null]), [["thread.merge", "t-primes", null], ["thread.merged", "t-primes", false]]);
  assert.deepEqual(first.told[1].files, [{ path: "primes.py", added: 1, deleted: 0 }]);
  // What was uncommitted in its worktree was committed to its branch before the merge.
  const second = await merging("merge_thread", { thread: "t-words" });
  assert.equal(second.answer.merged, true);
  assert.equal(second.answer.summary, "1 file, +1 −0");

  assert.equal(await readFile(join(cwd, "primes.py"), "utf8"), "print([2, 3, 5, 7, 11])\n");
  assert.equal(await readFile(join(cwd, "words.sh"), "utf8"), "wc -w README.md\n");
  assert.equal(await readFile(join(cwd, "README.md"), "utf8"), "# Sums\n\nAdds two numbers.\n");
  // Nothing committed in the opener's folder and nothing staged: all of it for the review.
  assert.equal(git(cwd, "log", "--oneline").trim().split("\n").length, 1);
  assert.equal(git(cwd, "diff", "--cached", "--name-only"), "");
  assert.equal(existsSync(primes) || existsSync(words), false);
  assert.equal(git(cwd, "branch", "--list", "oricode/*"), "");

  // What the app refuses, the agent reads.
  assert.match((await merging("merge_thread", { thread: "t-none" })).answer.error, /No thread of this project/);
  assert.deepEqual(await call(url, "finish_merge", {}), { error: "This thread has no merge open." });
});

test("a worktree opened from a folder starts with the folder as it is, and merges back against it, not HEAD", async (t) => {
  const { cwd, open, merging } = await opener(t);
  // What came in from a thread before, uncommitted: primes.py, untracked, and an edit to README.md.
  await writeFile(join(cwd, "primes.py"), "print([2, 3, 5])\n");
  await writeFile(join(cwd, "README.md"), "# Sums\n\nAnd primes.\n");
  const tests = await open("t-tests", "Test primes.py", cwd);
  assert.equal(await readFile(join(tests, "primes.py"), "utf8"), "print([2, 3, 5])\n");
  assert.equal(await readFile(join(tests, "README.md"), "utf8"), "# Sums\n\nAnd primes.\n");
  // Nothing in the folder was committed, staged or moved to make it.
  assert.equal(git(cwd, "log", "--oneline").trim().split("\n").length, 1);
  assert.equal(git(cwd, "diff", "--cached", "--name-only"), "");
  // The branch starts at HEAD and the folder's files are uncommitted there, so a push of it
  // takes none of them.
  assert.equal(git(tests, "rev-parse", "HEAD"), git(cwd, "rev-parse", "HEAD"));
  assert.equal(git(tests, "status", "--porcelain"), " M README.md\n?? primes.py\n");
  await writeFile(join(tests, "test_primes.py"), "def test_primes():\n    assert True\n");
  // The folder moves on meanwhile: against HEAD, primes.py would be added on both sides, differently.
  await writeFile(join(cwd, "primes.py"), "print([2, 3, 5, 7])\n");
  const merged = await merging("merge_thread", { thread: "t-tests" });
  assert.equal(merged.answer.merged, true);
  assert.deepEqual(merged.answer.files, [{ path: "test_primes.py", added: 2, deleted: 0 }]);
  assert.equal(await readFile(join(cwd, "primes.py"), "utf8"), "print([2, 3, 5, 7])\n");
  assert.equal(await readFile(join(cwd, "test_primes.py"), "utf8"), "def test_primes():\n    assert True\n");
  // Its branch and the base it kept went with the worktree.
  assert.equal(git(cwd, "branch", "--list", "oricode/*"), "");
  assert.equal(git(cwd, "for-each-ref", "refs/oricode"), "");
  // A folder in another repository gives it nothing: its commits aren't this one's.
  const other = await mkdtemp(join(tmpdir(), "oricode-merge-other-"));
  git(other, "init", "-q", "-b", "main");
  git(other, "-c", "user.name=Stand-in", "-c", "user.email=stand-in@example.com", "commit", "-q", "--allow-empty", "-m", "Other");
  await writeFile(join(other, "other.txt"), "elsewhere\n");
  const apart = await open("t-apart", "Apart", other);
  assert.equal(git(apart, "rev-parse", "HEAD"), git(cwd, "rev-parse", "HEAD"));
  assert.equal(git(apart, "status", "--porcelain"), "");
  assert.equal(git(cwd, "for-each-ref", "refs/oricode"), "");
  // A folder as HEAD has it starts its worktree at HEAD.
  await rm(join(cwd, "primes.py"));
  await rm(join(cwd, "test_primes.py"));
  git(cwd, "checkout", "--", "README.md");
  const plain = await open("t-plain", "Plain", cwd);
  assert.equal(git(plain, "rev-parse", "HEAD"), git(cwd, "rev-parse", "HEAD"));
  assert.equal(git(plain, "status", "--porcelain"), "");
});

test("a merge that meets a conflict stays open with its hunks, is finished once they're settled, and nothing else merges meanwhile", async (t) => {
  const { cwd, url, open, merging } = await opener(t);
  const plus = await open("t-plus", "Name it plus");
  await writeFile(join(plus, "sum.py"), "def plus(a, b):\n    return a + b\n\nprint(plus(2, 3))\n");
  const add = await open("t-add", "Name it add");
  await writeFile(join(add, "sum.py"), "def add(a, b):\n    return a + b\n\nprint(add(2, 3))\n");
  await writeFile(join(add, "NOTES.md"), "add, not sum\n");

  assert.equal((await merging("merge_thread", { thread: "t-plus" })).answer.merged, true);
  const met = await merging("merge_thread", { thread: "t-add" });
  assert.equal(met.answer.merged, false);
  assert.equal(met.answer.open, true);
  // The file that merged clean is in; the conflict is given hunk by hunk, each side's lines.
  assert.deepEqual(met.answer.files, [{ path: "NOTES.md", added: 1, deleted: 0 }]);
  assert.deepEqual(met.answer.conflicts, [
    // git takes conflicts this close together as one.
    { path: "sum.py", hunks: [{ line: 1, folder: ["def plus(a, b):", "    return a + b", "", "print(plus(2, 3))"], branch: ["def add(a, b):", "    return a + b", "", "print(add(2, 3))"] }] },
  ]);
  // Not yet told the app: the worktree stays until it's finished.
  assert.equal(met.told.some((line) => line.event === "thread.merged"), false);
  const marked = await readFile(join(cwd, "sum.py"), "utf8");
  assert.match(marked, /^<<<<<<< this thread's folder\ndef plus\(a, b\):\n[^]*=======\ndef add\(a, b\):\n[^]*>>>>>>> oricode\/t-add\n/);

  // Another merge waits for this one, and markers left are refused.
  assert.match((await call(url, "merge_thread", { thread: "t-plus" })).error, /^The merge of Name it add is open on its conflicts/);
  assert.match((await call(url, "finish_merge", {})).error, /^Conflict markers are left in sum\.py at line 1\./);

  await writeFile(join(cwd, "sum.py"), "def add(a, b):\n    return a + b\n\nprint(add(2, 3))\n");
  const finished = await merging("finish_merge", {});
  assert.equal(finished.answer.merged, true);
  assert.equal(finished.answer.thread, "Name it add");
  assert.deepEqual(finished.answer.files, [{ path: "NOTES.md", added: 1, deleted: 0 }, { path: "sum.py", added: 2, deleted: 2 }]);
  assert.equal(finished.answer.worktreeRemoved, true);
  assert.deepEqual(finished.told.map((line) => [line.event, line.thread, line.unmerged]), [["thread.merged", "t-add", false]]);
  assert.equal(existsSync(add), false);
  assert.equal(git(cwd, "diff", "--cached", "--name-only"), "");
});

test("an undone merge leaves the folder as it was, its own edits, new files and index included", async (t) => {
  const { cwd, url, open, merging } = await opener(t);
  const child = await open("t-child", "Rewrite sum.py");
  await writeFile(join(child, "sum.py"), "def sum(a, b):\n    return b + a\n\nprint(sum(3, 2))\n");
  await writeFile(join(child, "new.txt"), "from the thread\n");
  await writeFile(join(child, "README.md"), "# Sums, rewritten\n");
  // The opener's own work: an edit that conflicts, one staged, and a file git doesn't track.
  await writeFile(join(cwd, "sum.py"), "def sum(a, b):\n    return a+b\n\nprint(sum(2, 3))\n");
  await writeFile(join(cwd, "README.md"), "# Sums\n\nStaged.\n");
  git(cwd, "add", "README.md");
  await writeFile(join(cwd, "scratch.txt"), "the opener's\n");
  const before = await folderState(cwd);

  const met = await merging("merge_thread", { thread: "t-child" });
  assert.equal(met.answer.open, true);
  assert.deepEqual(met.answer.conflicts.map((conflict: { path: string }) => conflict.path).sort(), ["README.md", "sum.py"]);
  assert.equal(await readFile(join(cwd, "new.txt"), "utf8"), "from the thread\n");
  // Half settled, then taken back.
  await writeFile(join(cwd, "sum.py"), "def sum(a, b):\n    return b + a\n");
  const undone = await call(url, "finish_merge", { undo: true });
  assert.deepEqual(undone, { thread: "Rewrite sum.py", id: "t-child", branch: "oricode/t-child", merged: false, undone: true, note: "Every file the merge wrote is as it was before it." });
  assert.deepEqual(await folderState(cwd), before);
  // The thread keeps its worktree and its work, now committed to its branch.
  assert.equal(await readFile(join(child, "new.txt"), "utf8"), "from the thread\n");
  assert.equal(git(child, "status", "--porcelain"), "");
  assert.deepEqual(await call(url, "finish_merge", {}), { error: "This thread has no merge open." });
});

test("a merge still open when the opener's turn ends is undone, and the thread says so", async (t) => {
  const { engine, cwd, open, merging, turn } = await opener(t);
  const child = await open("t-child", "Rewrite sum.py");
  await writeFile(join(child, "sum.py"), "print('rewritten')\n");
  await writeFile(join(cwd, "sum.py"), "print('the opener')\n");
  const before = await folderState(cwd);
  assert.equal((await merging("merge_thread", { thread: "t-child" })).answer.open, true);
  const from = engine.lines.length;
  await turn();
  const note = await engine.until((line) => line.event === "note" && line.threadId === "lead", from);
  assert.equal(note.text, "The merge of Rewrite sum.py was undone: the turn ended with its conflicts unsettled, and the files it wrote are as they were.");
  assert.deepEqual(await folderState(cwd), before);
});

test("a conflict git can't mark, a deleted file or a binary one, waits for a side to be named, and keep writes it", async (t) => {
  const { cwd, url, open, merging } = await opener(t);
  await writeFile(join(cwd, "logo.bin"), Buffer.from([0, 1, 2]));
  git(cwd, "add", "-A");
  git(cwd, "commit", "-q", "-m", "Logo");
  const child = await open("t-child", "Tidy up");
  await rm(join(child, "README.md"));
  await writeFile(join(child, "logo.bin"), Buffer.from([0, 9, 9]));
  await writeFile(join(cwd, "README.md"), "# Sums\n\nThe opener's.\n");
  await writeFile(join(cwd, "logo.bin"), Buffer.from([0, 7, 7]));
  const before = await folderState(cwd);

  const met = await merging("merge_thread", { thread: "t-child" });
  assert.equal(met.answer.open, true);
  assert.deepEqual(
    met.answer.conflicts.map((conflict: any) => [conflict.path, conflict.conflict, conflict.hunks]),
    [["README.md", "modify/delete", undefined], ["logo.bin", "binary", undefined]],
  );
  assert.match(met.answer.conflicts[0].message, /README\.md deleted in oricode\/t-child/);
  // Nothing in the files says so, and git kept the folder's side of both.
  assert.match((await call(url, "finish_merge", {})).error, /^No side is kept yet for README\.md \(modify\/delete\), logo\.bin \(binary\)/);
  assert.match((await call(url, "finish_merge", { keep: { "sum.py": "branch" } })).error, /^sum\.py isn't a conflict git left unmarked/);
  // Kept one at a time; an undo after a side is kept still puts both back.
  assert.match((await call(url, "finish_merge", { keep: { "README.md": "branch" } })).error, /^No side is kept yet for logo\.bin \(binary\)/);
  assert.equal(existsSync(join(cwd, "README.md")), false);
  assert.equal((await call(url, "finish_merge", { undo: true })).undone, true);
  assert.deepEqual(await folderState(cwd), before);

  await merging("merge_thread", { thread: "t-child" });
  const finished = await merging("finish_merge", { keep: { "README.md": "branch", "logo.bin": "folder" } });
  assert.equal(finished.answer.merged, true);
  assert.deepEqual(finished.answer.files, [{ path: "README.md", added: 0, deleted: 3 }]);
  assert.equal(existsSync(join(cwd, "README.md")), false);
  assert.deepEqual([...(await readFile(join(cwd, "logo.bin")))], [0, 7, 7]);
});

test("a CRLF file's conflict is read side by side, its markers named", async (t) => {
  const { cwd, open, merging } = await opener(t);
  await writeFile(join(cwd, "dos.txt"), "one\r\ntwo\r\nthree\r\n");
  git(cwd, "add", "-A");
  git(cwd, "commit", "-q", "-m", "DOS");
  const child = await open("t-child", "Edit dos.txt");
  await writeFile(join(child, "dos.txt"), "one\r\nkid\r\nthree\r\n");
  await writeFile(join(cwd, "dos.txt"), "one\r\nfolder\r\nthree\r\n");
  const met = await merging("merge_thread", { thread: "t-child" });
  assert.deepEqual(met.answer.conflicts, [{ path: "dos.txt", hunks: [{ line: 2, folder: ["folder"], branch: ["kid"] }] }]);
  assert.equal(await readFile(join(cwd, "dos.txt"), "utf8"), "one\r\n<<<<<<< this thread's folder\r\nfolder\r\n=======\r\nkid\r\n>>>>>>> oricode/t-child\r\nthree\r\n");
});

test("the worktree's leftovers are committed past the repository's hooks and signing", async (t) => {
  const { cwd, open, merging } = await opener(t);
  await writeFile(join(cwd, ".git", "hooks", "pre-commit"), "#!/bin/sh\necho 'lint-staged: not found' >&2\nexit 1\n");
  await chmod(join(cwd, ".git", "hooks", "pre-commit"), 0o755);
  git(cwd, "config", "commit.gpgsign", "true");
  git(cwd, "config", "gpg.program", "false");
  const child = await open("t-child", "Write primes.py");
  await writeFile(join(child, "primes.py"), "print([2, 3, 5])\n");
  const merged = await merging("merge_thread", { thread: "t-child" });
  assert.equal(merged.answer.merged, true);
  assert.equal(merged.answer.worktreeRemoved, true);
});

test("a worktree with a file git ignores that its opener lacks, or has otherwise, stays", async (t) => {
  const { cwd, open, merging } = await opener(t);
  await writeFile(join(cwd, ".gitignore"), ".env\nnode_modules/\n");
  git(cwd, "add", "-A");
  git(cwd, "commit", "-q", "-m", "Ignore");
  await writeFile(join(cwd, ".env"), "A=1\n");
  const child = await open("t-child", "Add a key");
  await writeFile(join(child, ".env"), "A=1\n");
  await mkdir(join(child, "node_modules", "left-pad"), { recursive: true });
  await writeFile(join(child, "node_modules", "left-pad", "index.js"), "module.exports = 1;\n");
  await writeFile(join(child, "primes.py"), "print([2, 3, 5])\n");
  // The same .env as the folder's, and a folder git ignores whole: nothing is left out.
  const merged = await merging("merge_thread", { thread: "t-child" });
  assert.deepEqual([merged.told[1].unmerged, merged.told[1].ignored], [false, []]);

  const other = await open("t-other", "Add another key");
  await writeFile(join(other, ".env"), "A=1\nB=2\n");
  await writeFile(join(other, "words.sh"), "wc -w\n");
  const kept = await merging("merge_thread", { thread: "t-other" });
  assert.equal(kept.answer.merged, true);
  assert.deepEqual([kept.told[1].unmerged, kept.told[1].ignored], [true, [".env"]]);
  assert.equal(kept.answer.worktreeRemoved, false);
  assert.equal(existsSync(other), true);
});

test("a thread on Plan merges nothing", async (t) => {
  const { cwd, url, open, turn } = await opener(t);
  const child = await open("t-child", "Write primes.py");
  await writeFile(join(child, "primes.py"), "print([2, 3, 5])\n");
  await turn("plan");
  assert.match((await call(url, "merge_thread", { thread: "t-child" })).error, /^This thread is on Plan, which edits no files/);
  assert.equal(existsSync(join(cwd, "primes.py")), false);
});

test("a merge that meets its conflict after the turn has ended is undone at once", async (t) => {
  const { engine, cwd, url, open, turn } = await opener(t);
  const child = await open("t-child", "Rewrite sum.py");
  await writeFile(join(child, "sum.py"), "print('rewritten')\n");
  await writeFile(join(cwd, "sum.py"), "print('the opener')\n");
  const before = await folderState(cwd);
  const from = engine.lines.length;
  const calling = call(url, "merge_thread", { thread: "t-child" });
  const asked = await engine.until((line) => line.event === "thread.merge", from);
  // A second merge while this one is under way is refused, and the user stops the turn meanwhile.
  assert.match((await call(url, "merge_thread", { thread: "t-child" })).error, /^Another merge is under way/);
  await turn();
  await engine.request("app.reply", { requestId: asked.requestId, result: { id: "t-child", title: "Rewrite sum.py", worktree: child, branch: "oricode/t-child", folder: cwd } });
  const answer = await calling;
  assert.equal(answer.undone, true);
  const note = await engine.until((line) => line.event === "note" && line.threadId === "lead" && /undone/.test(line.text), from);
  assert.equal(note.text, "The merge of Rewrite sum.py was undone: the turn ended before it met its conflicts, and the files it wrote are as they were.");
  assert.deepEqual(await folderState(cwd), before);
  assert.deepEqual(await call(url, "finish_merge", {}), { error: "This thread has no merge open." });
});

test("a merge still open when the app quits is undone before the engine goes", async (t) => {
  const { engine, cwd, open, merging } = await opener(t);
  const child = await open("t-child", "Rewrite sum.py");
  await writeFile(join(child, "sum.py"), "print('rewritten')\n");
  await writeFile(join(cwd, "sum.py"), "print('the opener')\n");
  const before = await folderState(cwd);
  assert.equal((await merging("merge_thread", { thread: "t-child" })).answer.open, true);
  assert.match(await readFile(join(cwd, "sum.py"), "utf8"), /^<<<<<<< /);
  await engine.quit();
  assert.deepEqual(await folderState(cwd), before);
});
