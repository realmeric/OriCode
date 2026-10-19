// Seeing and using the Mac (K-290) through the real engine: a stand-in Codex in the thread's
// place, the test calling the tools over MCP as its agent would and answering the app's events and
// the user's ask as the app would.
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { told } from "../provider.ts";
import { seeing } from "../mac.ts";
import { opening, suggesting } from "../threads.ts";
import { engineWith, sandbox } from "./engine.ts";

async function mcp(url: string, method: string, params: object = {}): Promise<any> {
  const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  assert.equal(response.status, 200);
  return (await response.json()).result;
}

async function call(url: string, name: string, args: object = {}): Promise<any> {
  const result = await mcp(url, "tools/call", { name, arguments: args });
  const text = result.content.at(-1).text;
  return result.isError ? { error: text } : JSON.parse(text);
}

async function codex(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const log = join(await mkdtemp(join(tmpdir(), "oricode-mac-logs-")), "codex.log");
  const standIn = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${log}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${standIn}" "$@" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-mac-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const turn = async (threadId: string, more: object = {}) => {
    const from = engine.lines.length;
    assert.deepEqual((await engine.request("send", { threadId, cwd, text: "hello", permissionMode: "default", provider: "codex", ...more })).result, { ok: true });
    await engine.until((line) => line.event === "turn.done" && line.threadId === threadId, from);
  };
  const starts = async () =>
    (await readFile(log, "utf8"))
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line))
      .filter((message) => message.method === "thread/start")
      .map((message) => message.params);
  return { engine, turn, starts };
}

const names = (tools: { name: string }[]) => tools.map((tool) => tool.name);
const mac = ["list_apps", "screenshot", "click", "type_text", "press_key", "scroll"];

test("with it off no agent is offered the tools or told of them, and a call is refused", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("off");
  const [started] = await starts();
  const url: string = started.config["mcp_servers.oricode"].url;
  assert.equal(started.developerInstructions, told(`${opening}\n\n${suggesting}`));
  assert.equal(names((await mcp(url, "tools/list")).tools).some((name) => mac.includes(name)), false);
  const from = engine.lines.length;
  assert.match((await call(url, "screenshot", { app: "Safari" })).error, /hasn't let agents see and use the Mac/);
  // Nothing went to the app, so nothing on the Mac was read.
  assert.equal(engine.lines.slice(from).some((line) => line.requestId), false);
  await engine.end();
});

test("with it on the tools are offered, the first call on an app asks the user, and a picture comes back as an image", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("on", { mac: true });
  const [started] = await starts();
  const url: string = started.config["mcp_servers.oricode"].url;
  assert.equal(started.developerInstructions, told(`${opening}\n\n${suggesting}\n\n${seeing}`));
  assert.deepEqual(names((await mcp(url, "tools/list")).tools).slice(-6), mac);

  // list_apps reads nothing from inside an app, so it asks no one.
  let from = engine.lines.length;
  const listing = call(url, "list_apps");
  const apps = await engine.until((line) => line.event === "mac.apps", from);
  await engine.request("app.reply", { requestId: apps.requestId, result: { apps: [{ name: "OriCode Molten", bundleId: "com.realmeric.oricode.molten", front: false }] } });
  assert.deepEqual(await listing, { apps: [{ name: "OriCode Molten", bundleId: "com.realmeric.oricode.molten", front: false, allowed: false }] });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "ask"), false);

  // The app says which app it is, the user is asked in the thread, and only then is it seen.
  from = engine.lines.length;
  const picture = mcp(url, "tools/call", { name: "screenshot", arguments: { app: "molten" } });
  const found = await engine.until((line) => line.event === "mac.find", from);
  assert.equal(found.app, "molten");
  await engine.request("app.reply", { requestId: found.requestId, result: { name: "OriCode Molten", bundleId: "com.realmeric.oricode.molten" } });
  const asked = await engine.until((line) => line.event === "ask", from);
  assert.deepEqual({ ...asked, requestId: undefined }, {
    event: "ask",
    threadId: "on",
    requestId: undefined,
    kind: "permission",
    tool: "Mac",
    input: { app: "OriCode Molten", bundleId: "com.realmeric.oricode.molten" },
    choices: [
      { id: "deny", name: "Deny", kind: "reject_once" },
      { id: "allow", name: "Allow", kind: "allow_always" },
    ],
  });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "mac.screenshot"), false);
  await engine.request("answer", { requestId: asked.requestId, allow: true, optionId: "allow" });
  const shot = await engine.until((line) => line.event === "mac.screenshot", from);
  assert.equal(shot.bundleId, "com.realmeric.oricode.molten");
  await engine.request("app.reply", { requestId: shot.requestId, result: { image: "aGk=", mimeType: "image/jpeg", window: "Molten", width: 1180, height: 760 } });
  assert.deepEqual((await picture).content, [
    { type: "image", data: "aGk=", mimeType: "image/jpeg" },
    { type: "text", text: JSON.stringify({ window: "Molten", width: 1180, height: 760 }, null, 2) },
  ]);

  // Allowed once, the app isn't asked about again in the thread.
  from = engine.lines.length;
  const clicking = call(url, "click", { app: "OriCode Molten", x: 20, y: 30 });
  const again = await engine.until((line) => line.event === "mac.find", from);
  await engine.request("app.reply", { requestId: again.requestId, result: { name: "OriCode Molten", bundleId: "com.realmeric.oricode.molten" } });
  const clicked = await engine.until((line) => line.event === "mac.click", from);
  assert.deepEqual({ ...clicked, requestId: undefined }, { event: "mac.click", threadId: "on", requestId: undefined, bundleId: "com.realmeric.oricode.molten", x: 20, y: 30, button: "left", clicks: 1 });
  await engine.request("app.reply", { requestId: clicked.requestId, result: { clicked: true } });
  assert.deepEqual(await clicking, { clicked: true });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "ask"), false);
  assert.match((await call(url, "click", { app: "OriCode Molten", x: -1, y: 3 })).error, /`x` and `y`/);
  await engine.end();
});

test("an app the user denies stays unseen, and what the app refuses is the tool's error", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("denied", { mac: true });
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  let from = engine.lines.length;
  const typing = call(url, "type_text", { app: "Notes", text: "hi" });
  const found = await engine.until((line) => line.event === "mac.find", from);
  await engine.request("app.reply", { requestId: found.requestId, result: { name: "Notes", bundleId: "com.apple.Notes" } });
  const asked = await engine.until((line) => line.event === "ask", from);
  await engine.request("answer", { requestId: asked.requestId, allow: false, optionId: "deny" });
  assert.match((await typing).error, /didn't let this thread see and use Notes/);
  assert.equal(engine.lines.slice(from).some((line) => line.event === "mac.type"), false);

  from = engine.lines.length;
  const self = call(url, "screenshot", { app: "OriCode" });
  const refused = await engine.until((line) => line.event === "mac.find", from);
  await engine.request("app.reply", { requestId: refused.requestId, error: "OriCode never lets an agent see or use its own windows." });
  assert.deepEqual(await self, { error: "OriCode never lets an agent see or use its own windows." });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "ask"), false);
  await engine.end();
});

const molten = { name: "OriCode Molten", bundleId: "com.realmeric.oricode.molten" };

test("two calls on an app at once ask once, a turn that ends with the ask up takes it back, and the switch going off forgets the app", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("once", { mac: true });
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  // The app says which app each call means, once `count` of them have asked.
  const find = async (from: number, count = 1) => {
    const finds = () => engine.lines.slice(from).filter((line) => line.event === "mac.find");
    await engine.until(() => finds().length >= count, from);
    for (const line of finds()) await engine.request("app.reply", { requestId: line.requestId, result: molten });
  };

  let from = engine.lines.length;
  const first = call(url, "screenshot", { app: "molten" });
  const second = call(url, "screenshot", { app: "molten", window: "Settings" });
  await find(from, 2);
  const asked = await engine.until((line) => line.event === "ask", from);
  await engine.request("answer", { requestId: asked.requestId, allow: false, optionId: "deny" });
  assert.match((await first).error, /didn't let this thread see and use OriCode Molten/);
  assert.match((await second).error, /didn't let this thread see and use OriCode Molten/);
  assert.equal(engine.lines.slice(from).filter((line) => line.event === "ask").length, 1);

  // The agent's call is gone with its turn, so its card is too, and the call is denied.
  from = engine.lines.length;
  const cut = call(url, "screenshot", { app: "molten" });
  await find(from);
  const waiting = await engine.until((line) => line.event === "ask", from);
  await turn("once", { mac: true });
  const cancelled = await engine.until((line) => line.event === "ask.cancelled", from);
  assert.equal(cancelled.requestId, waiting.requestId);
  assert.match((await cut).error, /didn't let this thread see and use OriCode Molten/);
  assert.equal(engine.lines.slice(from).some((line) => line.event === "mac.screenshot"), false);

  // Allowed, then the switch goes off and on: the app is asked about again.
  from = engine.lines.length;
  const allowedOnce = call(url, "press_key", { app: "molten", keys: "return" });
  await find(from);
  const allowing = await engine.until((line) => line.event === "ask", from);
  await engine.request("answer", { requestId: allowing.requestId, allow: true, optionId: "allow" });
  const pressed = await engine.until((line) => line.event === "mac.key", from);
  await engine.request("app.reply", { requestId: pressed.requestId, result: { pressed: "return" } });
  assert.deepEqual(await allowedOnce, { pressed: "return" });
  assert.deepEqual((await engine.request("macOff", {})).result, { ok: true });
  from = engine.lines.length;
  const again = call(url, "press_key", { app: "molten", keys: "return" });
  await find(from);
  const reasked = await engine.until((line) => line.event === "ask", from);
  await engine.request("answer", { requestId: reasked.requestId, allow: false, optionId: "deny" });
  assert.match((await again).error, /didn't let this thread see and use OriCode Molten/);
  await engine.end();
});

test("an app allowed on an ask a quit cut off is used with no second ask", async (t) => {
  const { engine, turn, starts } = await codex(t);
  await turn("quit", { mac: true, grant: { tool: "Mac", input: { app: molten.name, bundleId: molten.bundleId } } });
  const url: string = (await starts())[0].config["mcp_servers.oricode"].url;
  const from = engine.lines.length;
  const picture = call(url, "screenshot", { app: "molten" });
  const found = await engine.until((line) => line.event === "mac.find", from);
  await engine.request("app.reply", { requestId: found.requestId, result: molten });
  const shot = await engine.until((line) => line.event === "mac.screenshot", from);
  await engine.request("app.reply", { requestId: shot.requestId, result: { image: "aGk=", mimeType: "image/jpeg", window: "Molten" } });
  assert.deepEqual(await picture, { window: "Molten" });
  assert.equal(engine.lines.slice(from).some((line) => line.event === "ask"), false);
  await engine.end();
});
