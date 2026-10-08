// Children with a deadline: a stand-in git that never answers, and what it started, gone at the
// deadline and when the engine quits.
import { execFileSync } from "node:child_process";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { run, runSettled, within, type RunError } from "../child.ts";
import { engineWith, sandbox } from "./engine.ts";

/// A `git` that never returns, and leaves a child of its own, as one blocked in getcwd behind a
/// privacy prompt would; each writes its pid where the test can find it.
async function hanging(bin: string): Promise<{ path: string; pids: () => number[] }> {
  const folder = await mkdtemp(join(tmpdir(), "oricode-hang-"));
  const path = join(bin, "git");
  await writeFile(path, `#!/bin/sh\necho $$ >> "${folder}/pids"\nsleep 600 &\necho $! >> "${folder}/pids"\nwait\n`);
  await chmod(path, 0o755);
  const pids = () => {
    try {
      return execFileSync("/bin/cat", [join(folder, "pids")], { encoding: "utf8" }).trim().split("\n").map(Number);
    } catch {
      return [];
    }
  };
  return { path, pids };
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function gone(pids: number[], within = 4000): Promise<number[]> {
  const until = Date.now() + within;
  while (pids.some(alive) && Date.now() < until) await new Promise((resolve) => setTimeout(resolve, 50));
  return pids.filter(alive);
}

test("a child answers with what it printed, or fails as execFile does", async () => {
  assert.deepEqual(await run("/bin/sh", ["-c", "echo out; echo err >&2"], { timeout: 5000 }), { stdout: "out\n", stderr: "err\n" });
  assert.equal((await run("/bin/cat", [], { input: "given", timeout: 5000 })).stdout, "given");
  const failed = (await run("/bin/sh", ["-c", "echo said; echo why >&2; exit 3"], { timeout: 5000 }).catch((error) => error)) as RunError;
  assert.equal(failed.code, 3);
  assert.equal(failed.stdout, "said\n");
  assert.equal(failed.stderr, "why\n");
  assert.equal((await runSettled("/nowhere/at/all", [], { timeout: 5000 })).error?.code, "ENOENT");
  const flood = (await run("/bin/sh", ["-c", "yes"], { timeout: 5000, maxBuffer: 1024 }).catch((error) => error)) as RunError;
  assert.equal(flood.code, "ERR_CHILD_PROCESS_STDIO_MAXBUFFER");
});

test("a child that never answers fails at its deadline, and its group goes with it", async () => {
  const bin = await mkdtemp(join(tmpdir(), "oricode-bin-"));
  const git = await hanging(bin);
  const started = Date.now();
  // Long enough for the stand-in to have started both: with every test file running at once, a
  // shell can take over 300 ms to reach its first line.
  const failed = (await run(git.path, ["rev-parse", "HEAD"], { timeout: 1500 }).catch((error) => error)) as RunError;
  assert.ok(Date.now() - started < 4000);
  assert.equal(failed.killed, true);
  assert.match(failed.message, /didn't finish in 1\.5s\.$/);
  assert.equal(git.pids().length, 2);
  assert.deepEqual(await gone(git.pids()), []);
});

test("a wait that's too long gives up with its timer gone", async () => {
  await assert.rejects(within(new Promise(() => {}), 50, "The stand-in"), /^Error: The stand-in didn't answer in 0\.05s\.$/);
  assert.equal(await within(Promise.resolve(7), 50, "The stand-in"), 7);
});

test("a git that never returns doesn't outlive the engine: quitting it ends the git and what it started", async (t) => {
  const { bin, env } = await sandbox();
  const git = await hanging(bin);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-hang-cwd-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello");
  const asked = engine.request("git.branch", { cwd });
  while (git.pids().length < 2) await new Promise((resolve) => setTimeout(resolve, 20));
  const pids = git.pids();
  assert.deepEqual(pids.filter(alive), pids);
  // As the app quits it.
  engine.kill();
  void asked;
  assert.deepEqual(await gone(pids), []);
});
