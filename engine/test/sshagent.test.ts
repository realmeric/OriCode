// OpenSSH's own ssh-agent on a socket in a scratch folder, holding a throwaway key whose private
// half is gone from disk once it's added: what a process the engine starts can sign with.
import { spawn, execFileSync, type ChildProcess } from "node:child_process";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { chmod, mkdir, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { join } from "node:path";
import { after, before, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { agentEnvironment } from "../acp.ts";
import { run as child } from "../child.ts";
import { cleanEnvironment } from "../claude.ts";
import { git } from "../git.ts";
import { gitRun } from "../review.ts";
import { run as action } from "../shell.ts";
import { signing, signingNow, sshAgent, useSshAgent } from "../sshagent.ts";
import { engineWith, sandbox } from "./engine.ts";

// /tmp and not the long per-user folder: a socket's path has about a hundred characters.
const folder = mkdtempSync("/tmp/oricode-ssh-");
const socket = join(folder, "agent.sock");
const key = join(folder, "key");
let agent: ChildProcess;
let listed: string;

before(async () => {
  execFileSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "throwaway", "-f", key]);
  agent = spawn("ssh-agent", ["-D", "-a", socket], { stdio: "ignore" });
  while (!existsSync(socket)) await new Promise((done) => setTimeout(done, 10));
  execFileSync("ssh-add", ["-q", key], { env: { ...process.env, SSH_AUTH_SOCK: socket }, stdio: "ignore" });
  rmSync(key);
  listed = execFileSync("ssh-add", ["-l"], { env: { ...process.env, SSH_AUTH_SOCK: socket }, encoding: "utf8" }).trim();
  assert.match(listed, /throwaway/);
});

after(() => {
  useSshAgent();
  agent.kill();
  rmSync(folder, { recursive: true, force: true });
});

beforeEach(() => useSshAgent());

test("off, the engine's SSH_AUTH_SOCK reaches its children as it was given", () => {
  const given = process.env.SSH_AUTH_SOCK;
  assert.deepEqual(sshAgent(), {});
  assert.equal(agentEnvironment().SSH_AUTH_SOCK, given);
  assert.equal(cleanEnvironment().SSH_AUTH_SOCK, given);
});

test("on with no socket there, the environment stays as it was", () => {
  const given = process.env.SSH_AUTH_SOCK;
  useSshAgent(join(folder, "nothing.sock"));
  assert.deepEqual(sshAgent(), {});
  assert.equal(agentEnvironment().SSH_AUTH_SOCK, given);
  assert.equal(cleanEnvironment().SSH_AUTH_SOCK, given);
});

test("something at the path that isn't a socket doesn't count", () => {
  const file = join(folder, "file.sock");
  writeFileSync(file, "");
  useSshAgent(file);
  assert.deepEqual(sshAgent(), {});
});

test("a folder it can't look into counts as no socket, and no spawn fails on it", () => {
  const shut = join(folder, "shut");
  execFileSync("mkdir", [shut]);
  chmodSync(shut, 0);
  useSshAgent(join(shut, "agent.sock"));
  assert.deepEqual(sshAgent(), {});
  chmodSync(shut, 0o700);
});

test("each start asks again, so a socket that comes and goes needs no restart", async () => {
  const late = join(folder, "late.sock");
  useSshAgent(late);
  assert.deepEqual(sshAgent(), {});
  const server = createServer();
  await new Promise<void>((done) => server.listen(late, done));
  assert.deepEqual(sshAgent(), { SSH_AUTH_SOCK: late });
  await new Promise((done) => server.close(done));
  assert.deepEqual(sshAgent(), {});
});

test("a key provider's own environment still comes last", () => {
  useSshAgent(socket);
  assert.equal(agentEnvironment({ SSH_AUTH_SOCK: "its own" }).SSH_AUTH_SOCK, "its own");
});

test("an agent's process, an action and every git of the engine's reach the key", async () => {
  useSshAgent(socket);
  const { stdout: agents } = await child("ssh-add", ["-l"], { env: agentEnvironment(), timeout: 10_000 });
  assert.equal(agents.trim(), listed);
  const { stdout: claudes } = await child("ssh-add", ["-l"], { env: cleanEnvironment() as NodeJS.ProcessEnv, timeout: 10_000 });
  assert.equal(claudes.trim(), listed);
  assert.deepEqual(await action(folder, "ssh-add -l"), { code: 0, line: listed });
  assert.equal((await git(folder, ["-c", "alias.agent=!ssh-add -l", "agent"])).trim(), listed);
  assert.equal((await gitRun(folder, ["-c", "alias.agent=!ssh-add -l", "agent"])).trim(), listed);
});

test("what a child signs with the key on the agent verifies, with the private half on no disk", async () => {
  useSshAgent(socket);
  assert.equal(existsSync(key), false);
  const message = join(folder, "message");
  writeFileSync(message, "signed through the agent\n");
  await child("ssh-keygen", ["-Y", "sign", "-f", `${key}.pub`, "-n", "file", message], { env: agentEnvironment(), timeout: 10_000 });
  const signers = join(folder, "signers");
  writeFileSync(signers, `throwaway ${readFileSync(`${key}.pub`, "utf8")}`);
  const verified = execFileSync("ssh-keygen", ["-Y", "verify", "-f", signers, "-I", "throwaway", "-n", "file", "-s", `${message}.sig`], {
    input: readFileSync(message),
    encoding: "utf8",
  });
  assert.match(verified, /Good "file" signature for throwaway/);
});

test("the switch comes over the wire, and what starts next goes by it", async () => {
  const { env } = await sandbox();
  const engine = engineWith({ ...env, SSH_AUTH_SOCK: undefined });
  const asked = async () => (await engine.request("shell.run", { cwd: folder, command: 'echo "${SSH_AUTH_SOCK-unset}"' })).result.line;
  try {
    await engine.request("hello", { sshAgent: socket });
    assert.equal(await asked(), socket);
    await engine.request("sshAgent.set", { socket: null });
    assert.equal(await asked(), "unset");
    await engine.request("sshAgent.set", { socket });
    assert.equal(await asked(), socket);
  } finally {
    engine.kill();
  }
});

test("signing is said only while a process would have the socket", () => {
  assert.equal(signingNow(), undefined);
  useSshAgent(join(folder, "nothing.sock"));
  assert.equal(signingNow(), undefined);
  useSshAgent(socket);
  assert.equal(signingNow(), signing);
  useSshAgent(null);
  assert.equal(signingNow(), undefined);
});

/// The real engine with stand-ins for Codex, whose system prompt is its developer instructions, and
/// OpenCode, which has none, each logging what it's sent.
async function agents(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const logs = mkdtempSync(join(folder, "logs-"));
  const codex = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  const acp = new URL("./fixtures/acp-agent.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${join(logs, "codex.log")}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${codex}" "$@" ;;\nesac\n`);
  await writeFile(join(bin, "opencode"), `#!/bin/sh\nexport ACP_LOG='${join(logs, "acp.log")}'\ncase "$1" in\n  --version) echo "1.18.32" ;;\n  acp) exec "${process.execPath}" "${acp}" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  await chmod(join(bin, "opencode"), 0o755);
  const cwd = join(logs, "work");
  await mkdir(cwd);
  const engine = engineWith({ ...env, SSH_AUTH_SOCK: undefined });
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") }, opencode: { path: join(bin, "opencode") } }, sshAgent: socket });
  const turn = async (provider: string) => {
    const from = engine.lines.length;
    assert.equal((await engine.request("send", { threadId: provider, cwd, text: "hello", permissionMode: "default", provider })).error, undefined);
    await engine.until((line) => line.event === "turn.done" && line.threadId === provider, from);
  };
  const logged = (name: string, method: string) =>
    readFileSync(join(logs, name), "utf8").trim().split("\n").map((line) => JSON.parse(line)).filter((message) => message.method === method).map((message) => message.params);
  return { engine, turn, logged };
}

test("a system prompt says it while the socket is there, and a later turn hears it's gone", async (t) => {
  const { engine, turn, logged } = await agents(t);
  await turn("codex");
  await engine.request("sshAgent.set", { socket: null });
  await turn("codex");
  const [on] = logged("codex.log", "thread/start");
  const [off] = logged("codex.log", "thread/resume");
  assert.equal(on.developerInstructions.endsWith(signing), true);
  assert.equal(off.developerInstructions.includes(signing), false);
  assert.equal(JSON.stringify(logged("codex.log", "turn/start")).includes(signing), false);
});

test("an agent with no system prompt hears it ahead of each message, and only while it's so", async (t) => {
  const { engine, turn, logged } = await agents(t);
  await turn("opencode");
  await turn("opencode");
  await engine.request("sshAgent.set", { socket: null });
  await turn("opencode");
  const said = logged("acp.log", "session/prompt").map((prompt) => JSON.stringify(prompt.prompt));
  assert.equal(said[0].includes(signing), true);
  assert.equal(said[1].includes(signing), true);
  assert.equal(said[2].includes(signing), false);
});
