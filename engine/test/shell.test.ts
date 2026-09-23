// Quiet custom actions, run in scratch folders: nothing here touches Claude or a real repo.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, realpath } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { lastLine, run, stopAll } from "../shell.ts";

async function folder(): Promise<string> {
  return realpath(await mkdtemp(join(tmpdir(), "oricode-shell-")));
}

test("a command runs in the folder and gives its last line", async () => {
  const dir = await folder();
  assert.deepEqual(await run(dir, "printf 'one\\ntwo\\n\\n'; pwd"), { code: 0, line: dir });
});

test("a failure keeps its exit code, and stderr counts as output", async () => {
  assert.deepEqual(await run(await folder(), "echo fine; echo 'nope' >&2; exit 3"), { code: 3, line: "nope" });
});

test("a value quoted the way the app quotes it reaches the command as literal text", async () => {
  // The app wraps each value in single quotes and writes a quote inside as '\''.
  const value = "a'b $(x) `y` ; z";
  const quoted = "'" + value.replaceAll("'", "'\\''") + "'";
  assert.equal((await run(await folder(), `printf '%s\\n' ${quoted}`)).line, value);
});

test("colour codes and carriage returns don't reach the note", () => {
  assert.equal(lastLine("\x1b[32mSaved working directory\x1b[0m\r\n"), "Saved working directory");
  assert.equal(lastLine("progress 10%\rprogress 100%\n"), "progress 100%");
  assert.equal(lastLine(""), "");
});

test("a Claude Code session's variables stay out, and the user's config dir stays in", async () => {
  process.env.CLAUDECODE = "1";
  process.env.CLAUDE_CONFIG_DIR = "/somewhere";
  try {
    assert.equal((await run(await folder(), 'echo "[$CLAUDECODE][$CLAUDE_CONFIG_DIR]"')).line, "[][/somewhere]");
  } finally {
    delete process.env.CLAUDECODE;
    delete process.env.CLAUDE_CONFIG_DIR;
  }
});

test("a folder that's gone is refused, and a command that runs too long is stopped", async () => {
  await assert.rejects(run(join(await folder(), "gone"), "true"), /isn't there any more/);
  await assert.rejects(run(await folder(), "sleep 5", 300), /Stopped after 0s/);
});

test("stopAll ends quiet actions still running, and what they started", async () => {
  const dir = await folder();
  const pending = run(dir, "sleep 30 & echo $! > pid; wait");
  await new Promise((done) => setTimeout(done, 300));
  stopAll();
  const result = await pending;
  assert.notEqual(result.code, 0);
  const pid = Number((await readFile(join(dir, "pid"), "utf8")).trim());
  await new Promise((done) => setTimeout(done, 200));
  assert.throws(() => process.kill(pid, 0));
});

test("a command that ignores SIGTERM still answers at the timeout, and is killed", async () => {
  const dir = await folder();
  const started = Date.now();
  await assert.rejects(run(dir, "trap '' TERM; echo $$ > pid; while true; do sleep 1; done", 300), /Stopped after/);
  assert.ok(Date.now() - started < 1500);
  const pid = Number((await readFile(join(dir, "pid"), "utf8")).trim());
  await new Promise((done) => setTimeout(done, 2500));
  assert.throws(() => process.kill(pid, 0));
});
