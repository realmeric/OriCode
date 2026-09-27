// The registry of agents, the one login shell that finds the ones turned on, and a key read from
// the Keychain for one process: against stand-in binaries, a stand-in shell and a stand-in
// `security`, so nothing reaches a real agent or the real Keychain.
import { execFile } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { test } from "node:test";
import assert from "node:assert/strict";
import { agentEnvironment } from "../acp.ts";
import { agents, binary, change, keyFor, lookUp, registry, turnOn } from "../agents.ts";

const run = promisify(execFile);

async function script(path: string, body: string): Promise<string> {
  await writeFile(path, `#!/bin/sh\n${body}\n`);
  await chmod(path, 0o755);
  return path;
}

test("every agent is in the registry once, the model APIs by a key, and the logins their makers forbid with the maker's own words", () => {
  assert.deepEqual(
    agents.map((entry) => entry.id),
    ["claude", "codex", "cursor", "copilot", "opencode", "grok", "devin", "pi", "antigravity", "commandcode", "zai", "deepseek", "openrouter", "meta"],
  );
  const keyed = agents.filter((entry) => entry.key).map((entry) => [entry.id, entry.key, entry.binaries]);
  assert.deepEqual(keyed, [
    ["commandcode", "COMMAND_CODE_API_KEY", ["cmd"]],
    ["zai", "ANTHROPIC_AUTH_TOKEN", []],
    ["deepseek", "ANTHROPIC_AUTH_TOKEN", []],
    ["openrouter", "OPENROUTER_API_KEY", []],
    ["meta", "META_API_KEY", []],
  ]);
  assert.deepEqual(agents.find((entry) => entry.id === "cursor")!.binaries, ["cursor-agent", "agent"]);
  assert.deepEqual(
    agents.filter((entry) => entry.binaries.length > 0 && !entry.key).map((entry) => entry.login),
    [
      "Run `claude` in Terminal and log in.",
      "Run `codex login` in Terminal and log in.",
      "Run `cursor-agent login` in Terminal.",
      "Run `copilot login` in Terminal.",
      "Run `opencode auth login` in Terminal.",
      "Run `grok login` in Terminal.",
      "Run `devin auth login` in Terminal.",
      "Run `pi` in Terminal, then /login.",
      "Run `agy` in Terminal and sign in.",
    ],
  );
  const forbidden = agents.flatMap((entry) => entry.forbidden.map((login) => [entry.id, login.id, login.maker, login.url]));
  assert.deepEqual(forbidden, [
    ["pi", "anthropic", "Anthropic", "https://code.claude.com/docs/en/legal-and-compliance"],
    ["pi", "xai", "xAI", "https://x.ai/legal/terms-of-service"],
    ["pi", "meta", "Meta", "https://dev.meta.ai/docs/muse-code/subscriptions"],
    ["antigravity", "google", "Google", "https://antigravity.google/terms"],
  ]);
  assert.match(agents.find((entry) => entry.id === "antigravity")!.forbidden[0].sentence!, /^Using third party software, tools, or services to access the Service/);
  // What the app lists: no functions, no binaries' names, whether it has a CLI and a key.
  assert.deepEqual(registry().find((entry) => entry.id === "commandcode"), {
    id: "commandcode",
    name: "Command Code",
    agent: "Command Code",
    route: "its headless JSON",
    binary: true,
    key: true,
    forbidden: [],
  });
});

test("the agents turned on are found in one login shell, a chosen CLI is taken as it is, and one turned off is never looked for", async () => {
  const folder = await mkdtemp(join(tmpdir(), "oricode-agents-"));
  const bin = join(folder, "bin");
  await mkdir(bin);
  for (const name of ["codex", "cursor-agent", "agent", "pi", "devin"]) await script(join(bin, name), "exit 0");
  const chosen = await script(join(folder, "my-copilot"), "exit 0");
  const shells = join(folder, "shells");
  const shell = await script(join(folder, "zsh"), `echo "$*" >> "${shells}"\nexec /bin/zsh "$@"`);
  const saved = { HOME: process.env.HOME, PATH: process.env.PATH, ZDOTDIR: process.env.ZDOTDIR };
  // A home with no profile, so the login shell's PATH is the system's and this one.
  Object.assign(process.env, { HOME: folder, PATH: `${bin}:/usr/bin:/bin` });
  delete process.env.ZDOTDIR;
  try {
    turnOn({ codex: {}, cursor: {}, pi: {}, grok: {}, copilot: { path: chosen }, zai: { key: true } });
    lookUp(["codex", "cursor", "pi", "grok", "copilot", "zai", "devin"], shell);
    assert.deepEqual(
      await Promise.all(["codex", "cursor", "pi", "grok", "copilot", "zai", "devin"].map(binary)),
      [join(bin, "codex"), join(bin, "cursor-agent"), join(bin, "pi"), null, chosen, null, null],
    );
    const ran = (await readFile(shells, "utf8")).trim().split("\n");
    assert.equal(ran.length, 1);
    // Devin is on the PATH but off, and Copilot's CLI was chosen: neither is asked of the shell.
    assert.doesNotMatch(ran[0], /devin|copilot/);
    assert.match(ran[0], /^-lc .*codex.*cursor-agent.*agent.*pi.*grok/);

    // Choosing another CLI looks again for that one agent alone.
    const other = await script(join(folder, "other-codex"), "exit 0");
    change("codex", true, { path: other });
    assert.equal(await binary("codex"), other);
    change("codex", false, {});
    assert.equal(await binary("codex"), null);
    assert.equal((await readFile(shells, "utf8")).trim().split("\n").length, 1);
  } finally {
    Object.assign(process.env, saved);
    for (const [key, value] of Object.entries(saved)) if (value === undefined) delete process.env[key];
  }
});

test("a key is read for the one process that takes it, which gets it and nothing of Anthropic's, and it's never logged", async () => {
  const folder = await mkdtemp(join(tmpdir(), "oricode-key-"));
  const asked = join(folder, "asked");
  const security = await script(
    join(folder, "security"),
    `echo "$*" >> "${asked}"\ncase "$*" in\n  "find-generic-password -s OriCode.commandcode -a commandcode -w") echo "cc-secret-123" ;;\n  *) echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2; exit 44 ;;\nesac`,
  );
  process.env.ANTHROPIC_OAUTH_TOKEN = "a claude.ai token";
  const logged: string[] = [];
  const write = process.stderr.write.bind(process.stderr);
  process.stderr.write = ((chunk: string | Uint8Array) => {
    logged.push(String(chunk));
    return true;
  }) as typeof process.stderr.write;
  try {
    turnOn({ commandcode: { key: true }, deepseek: { key: true }, meta: {} });
    const key = await keyFor("commandcode", security);
    assert.deepEqual(key, { COMMAND_CODE_API_KEY: "cc-secret-123" });
    // One the app says has none kept isn't asked for; one kept but gone reads as none.
    assert.deepEqual(await keyFor("meta", security), {});
    assert.deepEqual(await keyFor("deepseek", security), {});
    assert.deepEqual((await readFile(asked, "utf8")).trim().split("\n"), [
      "find-generic-password -s OriCode.commandcode -a commandcode -w",
      "find-generic-password -s OriCode.deepseek -a deepseek -w",
    ]);

    const { stdout } = await run(process.execPath, ["-e", "process.stdout.write(JSON.stringify(process.env))"], { env: agentEnvironment(key) });
    const child = JSON.parse(stdout);
    assert.equal(child.COMMAND_CODE_API_KEY, "cc-secret-123");
    assert.equal(child.ANTHROPIC_OAUTH_TOKEN, undefined);
    assert.equal(process.env.COMMAND_CODE_API_KEY, undefined);
    // A key provider's own Anthropic variable still reaches its process.
    assert.equal(agentEnvironment({ ANTHROPIC_AUTH_TOKEN: "zai" }).ANTHROPIC_AUTH_TOKEN, "zai");
  } finally {
    process.stderr.write = write;
    delete process.env.ANTHROPIC_OAUTH_TOKEN;
  }
  assert.ok(logged.some((line) => line.startsWith("no key read for deepseek")));
  assert.ok(!logged.join("").includes("cc-secret-123"));
});
