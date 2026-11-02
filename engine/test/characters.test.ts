// A character's files: Hans brought in from what made him by hand, and what a thread as him is told.
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { characterBrief, characters, deleteCharacter, readCharacter, saveCharacter, saveNotes, settleProposal, wipeNotes } from "../characters.ts";
import { pass, saveProposals } from "../memory.ts";
import { engineWith, sandbox } from "./engine.ts";

async function handMade(home: string): Promise<void> {
  await mkdir(join(home, ".claude/hans"), { recursive: true });
  await mkdir(join(home, ".claude/skills/hans"), { recursive: true });
  await mkdir(join(home, ".claude/skills/lead"), { recursive: true });
  await writeFile(join(home, ".claude/hans/notes.md"), "# Hans's notes\n\nLast rewrite.\n\n## Meriç\n\nCalls Hans kanka.\n\n## Projects\n\nBlackjack Club.\n");
  await writeFile(join(home, ".claude/skills/hans/SKILL.md"), "---\nname: hans\ndescription: Hans\n---\n\nYou are Hans. Warm and direct.\n\n## Starting\n\nRead the notes.\n\n## More than one project\n\nOne Hans leads each project.\n");
  await writeFile(join(home, ".claude/skills/lead/SKILL.md"), "---\nname: lead\ndescription: Lead\n---\n\nYou own the result.\n");
}

const scratch = () => mkdtemp(join(tmpdir(), "oricode-characters-"));

test("Hans comes in from the hand-made files, once, and leaves them as they are", async () => {
  const home = await scratch();
  const folder = join(home, "Characters");
  await handMade(home);
  assert.deepEqual(await characters(folder, home), [{ id: "hans", name: "Hans", symbol: "suit.spade.fill", colour: "#D8B26E" }]);
  assert.equal((await readFile(join(folder, "hans/voice.md"), "utf8")).trim(), "You are Hans. Warm and direct.");
  const work = await readFile(join(folder, "hans/work.md"), "utf8");
  assert.match(work, /You own the result/);
  assert.match(work, /One Hans leads each project/);
  assert.doesNotMatch(work, /name: lead/);
  const memory = await readFile(join(folder, "hans/memory.md"), "utf8");
  assert.match(memory, /Blackjack Club/);
  assert.doesNotMatch(memory, /kanka/);
  assert.match(await readFile(join(folder, "about.md"), "utf8"), /Calls Hans kanka/);
  assert.match(await readFile(join(home, ".claude/hans/notes.md"), "utf8"), /## Meriç/);

  await rm(join(folder, "hans"), { recursive: true });
  assert.deepEqual(await characters(folder, home), []);
});

test("A Mac without the hand-made files has no Hans, and no folder set has no characters", async () => {
  const home = await scratch();
  assert.deepEqual(await characters(join(home, "Characters"), home), []);
  assert.deepEqual(await characters(undefined, home), []);
  assert.equal(await characterBrief("hans", undefined, join(home, "Characters")), undefined);
});

test("A thread as a character hears its core, its way of working, and its notes as notes", async () => {
  const home = await scratch();
  const folder = join(home, "Characters");
  await handMade(home);
  await characters(folder, home);
  const told = (await characterBrief("hans", undefined, folder))!;
  assert.match(told, /You are Hans\. Warm and direct\./);
  assert.match(told, /You own the result/);
  assert.match(told, /<about_the_user>\nCalls Hans kanka\./);
  assert.match(told, /<your_notes>[\s\S]*Blackjack Club/);
  assert.match(told, /Never claim to remember anything they don't hold/);
  assert.match(told, /only the user changes it/);
});

test("With no notes a character says it remembers nothing", async () => {
  const folder = await scratch();
  await mkdir(join(folder, "ada"));
  await writeFile(join(folder, "ada/character.json"), JSON.stringify({ name: "Ada" }));
  const told = (await characterBrief("ada", undefined, folder))!;
  assert.match(told, /You have no notes from before this thread/);
  assert.doesNotMatch(told, /<your_notes>/);
});

test("characters.list answers through the engine", async () => {
  const { env } = await sandbox();
  const folder = await scratch();
  const { request, end } = engineWith({ ...env, ORICODE_CHARACTERS: join(folder, "Characters"), HOME: folder });
  await handMade(folder);
  await request("hello", {});
  const reply = await request("characters.list");
  assert.deepEqual(reply.result.characters.map((character: { id: string }) => character.id), ["hans"]);
  await end();
});

test("The user's edit is the one path to the core, and a new character gets a plain id", async () => {
  const folder = await scratch();
  const ada = await saveCharacter({ name: "Ayşe Nur", symbol: "star.fill", colour: "#112233", voice: "Dry.", work: "Short." }, folder);
  assert.equal(ada.id, "ayse-nur");
  const again = await saveCharacter({ name: "Ayşe Nur", symbol: "star.fill", colour: "#112233", voice: "Dry.", work: "Short." }, folder);
  assert.equal(again.id, "ayse-nur-2");
  await saveCharacter({ id: "ayse-nur", name: "Ayşe", symbol: "bolt.fill", colour: "#445566", voice: "Warm.", work: "Long." }, folder);
  const read = (await readCharacter("ayse-nur", folder))!;
  assert.deepEqual([read.name, read.symbol, read.colour, read.voice, read.work], ["Ayşe", "bolt.fill", "#445566", "Warm.", "Long."]);
  await deleteCharacter("ayse-nur-2", folder);
  assert.deepEqual((await characters(folder, folder)).map((character) => character.id), ["ayse-nur"]);
});

test("No id climbs out of the characters' folder", async () => {
  const folder = await scratch();
  assert.equal(await characterBrief("../secret", undefined, folder), undefined);
  await assert.rejects(saveCharacter({ id: "../up", name: "X", symbol: "", colour: "", voice: "", work: "" }, folder));
  await assert.rejects(deleteCharacter("..", folder));
  await assert.rejects(wipeNotes("../..", folder));
});

test("The user's notes pass the same gate, and a wipe keeps no copy", async () => {
  const folder = await scratch();
  await saveCharacter({ name: "Ada", symbol: "", colour: "", voice: "", work: "" }, folder);
  assert.equal(await saveNotes("ada", "Likes tea.", folder), 0);
  assert.equal(await saveNotes("ada", `Likes coffee.\npassword: hunter2`, folder), 1);
  assert.equal((await readCharacter("ada", folder))!.memory, "Likes coffee.");
  await wipeNotes("ada", folder);
  assert.equal((await readCharacter("ada", folder))!.memory, "");
  assert.equal(await readFile(join(folder, "ada/memory.md"), "utf8"), "");
  await assert.rejects(readFile(join(folder, "ada/versions"), "utf8"));
  assert.equal(await saveNotes(undefined, "Writes in Turkish.", folder), 0);
  assert.equal((await readCharacter("ada", folder))!.about, "Writes in Turkish.");
});

test("A proposal changes the way of working only when the user takes it", async () => {
  const folder = await scratch();
  await saveCharacter({ name: "Ada", symbol: "", colour: "", voice: "Dry.", work: "Merge by hand." }, folder);
  const place = join(folder, "ada");
  const offer = (id: string, old: string, next: string) => ({ id, at: 1, thread: "T", why: "Because", old, new: next });
  await saveProposals(place, [offer("1", "Merge by hand.", "Merge, then check."), offer("2", "", "Protect the machine."), offer("3", "", "Never.")]);
  assert.equal((await characters(folder, folder))[0].waiting, 3);
  await settleProposal("ada", "3", false, folder);
  assert.equal((await readCharacter("ada", folder))!.work, "Merge by hand.");
  await settleProposal("ada", "1", true, folder);
  assert.equal((await readCharacter("ada", folder))!.work, "Merge, then check.");
  await settleProposal("ada", "2", true, folder);
  assert.equal((await readCharacter("ada", folder))!.work, "Merge, then check.\n\nProtect the machine.");
  assert.equal((await readCharacter("ada", folder))!.voice, "Dry.");
  assert.equal((await characters(folder, folder))[0].waiting, undefined);
  await assert.rejects(settleProposal("ada", "1", true, folder));
});

test("A character's notes on a project go with it to that project alone", async () => {
  const folder = await scratch();
  await saveCharacter({ name: "Ada", symbol: "", colour: "", voice: "", work: "" }, folder);
  const ask = async () => JSON.stringify({ project: "Ships on Fridays." });
  await pass(folder, "ada", "Ada", "User: we ship on Fridays", "Ship", ask, "/work/one");
  assert.match((await characterBrief("ada", "/work/one", folder))!, /<your_notes_on_this_project>\nShips on Fridays\./);
  assert.doesNotMatch((await characterBrief("ada", "/work/two", folder))!, /Ships on Fridays/);
  assert.doesNotMatch((await characterBrief("ada", undefined, folder))!, /Ships on Fridays/);
  const [{ file, notes }] = (await readCharacter("ada", folder))!.projects;
  assert.equal(notes, "Ships on Fridays.");
  assert.equal(await saveNotes("ada", "Ships on Mondays.", folder, file), 0);
  assert.match((await characterBrief("ada", "/work/one", folder))!, /Ships on Mondays/);
  await assert.rejects(saveNotes("ada", "x", folder, "../../voice.md"));
  await wipeNotes("ada", folder);
  assert.deepEqual((await readCharacter("ada", folder))!.projects, []);
});

async function agents(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const logs = await scratch();
  const fixtures = (name: string) => new URL(`./fixtures/${name}`, import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${join(logs, "codex.log")}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${fixtures("codex-app-server.ts")}" "$@" ;;\nesac\n`);
  await writeFile(join(bin, "opencode"), `#!/bin/sh\nexport ACP_LOG='${join(logs, "acp.log")}'\ncase "$1" in\n  --version) echo "1.18.32" ;;\n  acp) exec "${process.execPath}" "${fixtures("acp-agent.ts")}" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  await chmod(join(bin, "opencode"), 0o755);
  const folder = join(logs, "Characters");
  await mkdir(folder);
  await saveCharacter({ name: "Ada", symbol: "star.fill", colour: "#112233", voice: "Dry and exact.", work: "Short." }, folder);
  await saveNotes("ada", "Ships on Fridays.", folder);
  const cwd = join(logs, "work");
  await mkdir(cwd);
  const engine = engineWith({ ...env, ORICODE_CHARACTERS: folder });
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") }, opencode: { path: join(bin, "opencode") } } });
  const turn = async (provider: string, more: object = {}) => {
    const from = engine.lines.length;
    assert.equal((await engine.request("send", { threadId: provider, cwd, text: "hello", permissionMode: "default", provider, character: "ada", ...more })).error, undefined);
    return engine.until((line) => line.event === "turn.done" && line.threadId === provider, from);
  };
  const logged = async (name: string, method: string) =>
    (await readFile(join(logs, name), "utf8")).trim().split("\n").map((line) => JSON.parse(line)).filter((message) => message.method === method).map((message) => message.params);
  return { turn, logged };
}

test("An agent with a system prompt hears a character there and not in its messages", async (t) => {
  const { turn, logged } = await agents(t);
  await turn("codex");
  const [started] = await logged("codex.log", "thread/start");
  assert.match(started.developerInstructions, /You are Ada/);
  assert.match(started.developerInstructions, /Dry and exact/);
  assert.match(started.developerInstructions, /Ships on Fridays/);
  assert.doesNotMatch(JSON.stringify(await logged("codex.log", "turn/start")), /Dry and exact/);
});

test("An agent without one hears it once, ahead of its session's first message", async (t) => {
  const { turn, logged } = await agents(t);
  const done = await turn("opencode");
  await turn("opencode", { sessionId: done.sessionId });
  const said = (await logged("acp.log", "session/prompt")).map((prompt) => JSON.stringify(prompt.prompt));
  assert.match(said[0], /Dry and exact/);
  assert.doesNotMatch(said[1], /Dry and exact/);
});
