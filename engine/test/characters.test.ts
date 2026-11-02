// A character's files: Hans brought in from what made him by hand, and what a thread as him is told.
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { characterBrief, characters } from "../characters.ts";
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
  assert.equal(await characterBrief("hans", join(home, "Characters")), undefined);
});

test("A thread as a character hears its core, its way of working, and its notes as notes", async () => {
  const home = await scratch();
  const folder = join(home, "Characters");
  await handMade(home);
  await characters(folder, home);
  const told = (await characterBrief("hans", folder))!;
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
  const told = (await characterBrief("ada", folder))!;
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
