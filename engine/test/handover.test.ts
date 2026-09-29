// A thread that changes agent, through the real engine: a Codex and an OpenCode as stand-ins, the
// thread moved from one to the other with the app's handover, which the new agent's session opens
// with in the engine's own words. Nothing reaches a model.
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { handed, handoverMax } from "../handover.ts";
import { engineWith, sandbox } from "./engine.ts";

async function logged(file: string): Promise<any[]> {
  return (await readFile(file, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
}

test("a thread moved to another agent opens its new session with the handover, and back again the same way", async (t) => {
  const { bin, env } = await sandbox();
  const logs = await mkdtemp(join(tmpdir(), "oricode-handover-"));
  const codex = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  const acp = new URL("./fixtures/acp-agent.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${join(logs, "codex.log")}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${codex}" "$@" ;;\nesac\n`);
  await writeFile(join(bin, "opencode"), `#!/bin/sh\nexport ACP_LOG='${join(logs, "acp.log")}'\ncase "$1" in\n  --version) echo "1.18.32" ;;\n  acp) exec "${process.execPath}" "${acp}" ;;\n  models) printf 'small\\n{\\n  "id": "small",\\n  "name": "Small",\\n  "variants": {}\\n}\\n' ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  await chmod(join(bin, "opencode"), 0o755);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-handover-cwd-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") }, opencode: { path: join(bin, "opencode") } } });
  /// A send and the end of the turn it starts, not one from before.
  const turn = async (params: object) => {
    const from = engine.lines.length;
    await engine.request("send", params);
    await engine.until((line) => line.event === "turn.done" && line.threadId === "k214", from);
  };
  const base = { threadId: "k214", cwd, permissionMode: "bypassPermissions" };

  await turn({ ...base, text: "my number is 47", provider: "codex" });

  // The app moves it: the old session goes, and the send names the new agent with the handover.
  assert.deepEqual((await engine.request("leave", { threadId: "k214" })).result, { ok: true });
  const thread = "User: my number is 47\nAssistant: Noted.";
  await turn({ ...base, text: "what's my number?", provider: "opencode", handover: thread });
  const prompt = (await logged(join(logs, "acp.log"))).find((message) => message.method === "session/prompt");
  const said: string = JSON.stringify(prompt.params.prompt);
  assert.ok(said.indexOf("[Handover]") >= 0 && said.indexOf("my number is 47") > said.indexOf("[Handover]"), "the handover is ahead of the message");
  assert.ok(said.indexOf("what's my number?") > said.indexOf("my number is 47"), "and the message follows it");
  assert.ok(!(await readFile(join(logs, "codex.log"), "utf8")).includes("[Handover]"), "Codex was told nothing of it");

  // Back on Codex with no leave first: the send lets the old session go itself, and Codex starts
  // one of its own that opens with the handover. A send into it adds none.
  await turn({ ...base, text: "and now?", provider: "codex", rays: ["opencode/small"], handover: `${thread}\nUser: what's my number?\nAssistant: 47` });
  const starts = (await logged(join(logs, "codex.log"))).filter((message) => message.method === "thread/start");
  assert.equal(starts.length, 2, "Codex started a session of its own again");
  assert.match(starts[1].params.config["mcp_servers.oricode"].url, /^http:\/\/127\.0\.0\.1:/, "as a head, with its rays' tools");
  const turns = (await logged(join(logs, "codex.log"))).filter((message) => message.method === "turn/start");
  assert.match(JSON.stringify(turns[1].params.input), /\[Handover\][^]*User: what's my number\?[^]*and now\?/);
  await turn({ ...base, text: "once more", provider: "codex", handover: "ignored" });
  const again = (await logged(join(logs, "codex.log"))).filter((message) => message.method === "turn/start");
  assert.doesNotMatch(JSON.stringify(again[2].params.input), /Handover|ignored/);
});

test("the handover's words come around the thread, and a huge one loses its start", () => {
  const words = handed("User: hi");
  assert.match(words, /^\[Handover\]/);
  assert.match(words, /<thread>\nUser: hi\n<\/thread>\n\nThe user's message follows\.$/);
  const huge = handed("x".repeat(handoverMax + 10));
  assert.match(huge, /\[The start of the thread is left out\.\]/);
  assert.ok(huge.length < handoverMax + 1000);
});
