// The real engine for a test, with a stand-in `claude` that's signed out and a folder of stand-in
// CLIs on its PATH, so a thread on any agent runs through main.ts's registration and nothing
// reaches a model.
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

/// A home with a bin folder for stand-ins, and the environment an engine started in it gets:
/// only that bin and the system's on its PATH, and a `claude` that says it isn't logged in.
export async function sandbox(): Promise<{ bin: string; env: Record<string, string | undefined> }> {
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const bin = join(home, "bin");
  await mkdir(bin);
  const claude = join(home, "claude");
  await writeFile(claude, `#!/bin/sh\ncase "$1" in\n  --version) echo "9.9.9 (Claude Code)" ;;\n  auth) echo '{"loggedIn": false}'; exit 1 ;;\nesac\n`);
  await chmod(claude, 0o755);
  return { bin, env: { ORICODE_CLAUDE: claude, ORICODE_CACHE: undefined, HOME: home, ZDOTDIR: undefined, PATH: `${bin}:/usr/bin:/bin` } };
}

/// A CLI called `name` in `bin` that runs a stand-in from fixtures/ with `env` exported.
export async function standInCli(bin: string, name: string, fixture: string, env: Record<string, string>): Promise<string> {
  const path = join(bin, name);
  const exports = Object.entries(env).map(([key, value]) => `export ${key}='${value}'\n`).join("");
  await writeFile(path, `#!/bin/sh\n${exports}exec "${process.execPath}" "${new URL(`./fixtures/${fixture}`, import.meta.url).pathname}" "$@"\n`);
  await chmod(path, 0o755);
  return path;
}

/// The engine, requests sent to it one at a time, and every line it writes.
export function engineWith(env: Record<string, string | undefined>) {
  const merged: Record<string, string | undefined> = { ...process.env, ...env };
  const engine = spawn(process.execPath, [new URL("../main.ts", import.meta.url).pathname], {
    stdio: ["pipe", "pipe", "inherit"],
    env: Object.fromEntries(Object.entries(merged).filter(([, value]) => value !== undefined)),
  });
  const lines: any[] = [];
  let arrived = () => {};
  let partial = "";
  engine.stdout.setEncoding("utf8");
  engine.stdout.on("data", (chunk: string) => {
    const complete = (partial + chunk).split("\n");
    partial = complete.pop() ?? "";
    lines.push(...complete.map((line) => JSON.parse(line)));
    arrived();
  });
  const until = async (matches: (line: any) => boolean, from = 0) => {
    while (!lines.slice(from).some(matches)) await new Promise<void>((done) => (arrived = done));
    return lines.slice(from).find(matches);
  };
  let next = 0;
  const request = (method: string, params: object = {}) => {
    const id = ++next;
    engine.stdin.write(JSON.stringify({ id, method, params }) + "\n");
    return until((line) => line.id === id);
  };
  const end = async () => {
    engine.stdin.end();
    await new Promise((done) => engine.on("close", done));
  };
  /// For a test that failed before it ended the engine, which would otherwise hold the run open.
  const kill = () => engine.exitCode === null && engine.kill();
  return { lines, until, request, end, kill };
}
