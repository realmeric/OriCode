// Sessions from other tools, listed for a folder and read as a thread's events: Claude Code's with
// the SDK's readers stood in for, Codex's from a stand-in app-server, OpenCode's from a stand-in
// CLI, and Cursor's, Copilot's and T3 Code's from made-up stores in a home of the test's own.
import { cp, mkdir, mkdtemp, readdir, readFile, realpath, symlink, writeFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { change } from "../agents.ts";
import { threadEvents, threadsIn } from "../codex.ts";
import { copilotEvents, copilotSessionsIn, workspace } from "../copilot.ts";
import { chatEvents, chatsIn, storeEvents } from "../cursor.ts";
import { opencodeSessions } from "../opencode.ts";
import { claudeEvents, claudeSessionsIn, folderAt, readOnly, sessionsIn, type Found, type Source } from "../sessions.ts";
import { t3ThreadEvents, t3ThreadsIn } from "../t3code.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

// T3 Code asks Claude Code whether a session it names is still kept, which mustn't read yours.
process.env.CLAUDE_CONFIG_DIR = await mkdtemp(join(tmpdir(), "oricode-claude-"));

const fixture = (name: string) => new URL(`./fixtures/sessions/${name}`, import.meta.url).pathname;

/// A SQLite store made from a fixture's SQL, as the tool would have left it.
async function storeAt(path: string, sql: string): Promise<void> {
  await mkdir(join(path, ".."), { recursive: true });
  const db = new DatabaseSync(path);
  db.exec(await readFile(fixture(sql), "utf8"));
  db.close();
}

const found = (id: string, fields: Partial<Found> = {}): Found => ({ id, agent: "claude", sessionId: id, title: id, modified: 0, branch: null, ...fields });

test("a folder's Claude Code sessions are listed under whichever path to it they ran in, and only those under its own path resume", async () => {
  const real = await realpath(await mkdtemp(join(tmpdir(), "oricode-real-")));
  const linked = join(await mkdtemp(join(tmpdir(), "oricode-link-")), "p");
  await symlink(real, linked);
  const asked: any[] = [];
  const list = (async (options: any) => {
    asked.push(options);
    return [
      { sessionId: "a", summary: "Fix the drawer", lastModified: 3, customTitle: "Drawer", gitBranch: "main", cwd: linked },
      { sessionId: "b", summary: "", lastModified: 2, firstPrompt: "hello there", cwd: real },
      { sessionId: "c", summary: "Elsewhere", lastModified: 1, cwd: "/w/q" },
    ];
  }) as never;
  assert.deepEqual(await claudeSessionsIn(await folderAt(linked), list), [
    { id: "a", agent: "claude", sessionId: "a", title: "Drawer", modified: 3, branch: "main" },
    { id: "b", agent: "claude", sessionId: null, title: "hello there", modified: 2, branch: null },
  ]);
  assert.deepEqual(asked[0], { includeProgrammatic: false });
});

test("every source's sessions are listed latest first, a session two sources list once, and a source that fails leaves the rest", async () => {
  const source = (id: string, list: () => Promise<Found[]>): Source => ({ id, name: id.toUpperCase(), list, read: async () => [] });
  const listed = await sessionsIn("/w/p", [
    source("app", async () => [found("t-1", { sessionId: "s-1", modified: 1 }), found("t-2", { agent: "cursor", sessionId: null, modified: 4 })]),
    source("claude", async () => [found("s-1", { modified: 2 }), found("s-3", { modified: 3 })]),
    source("broken", async () => {
      throw new Error("no store");
    }),
  ]);
  assert.deepEqual(
    listed.map((session) => [session.source, session.sourceName, session.id]),
    [
      ["app", "APP", "t-2"],
      ["claude", "CLAUDE", "s-3"],
      ["app", "APP", "t-1"],
    ],
  );
});

test("a store with no log beside it is read without one being made", async () => {
  const folder = await mkdtemp(join(tmpdir(), "oricode-store-"));
  const path = join(folder, "store.db");
  const db = new DatabaseSync(path);
  db.exec("pragma journal_mode = wal; create table t (x); insert into t values (1);");
  db.close();
  assert.deepEqual(await readdir(folder), ["store.db"]);
  const read = readOnly(path);
  assert.equal((read.prepare("select count(*) as n from t").get() as { n: number }).n, 1);
  read.close();
  assert.deepEqual(await readdir(folder), ["store.db"]);
});

test("a Codex thread is listed by its name or its first line, without OriCode's own, and read as a live thread's events", async () => {
  const binary = { command: process.execPath, args: [new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname] };
  const threads = await threadsIn(binary, ["/w/p"], 40);
  assert.deepEqual(
    threads.map((thread) => thread.id),
    ["019a-tui", "019a-oricode", "019a-app", "019a-elsewhere"],
  );
  assert.deepEqual(await threadEvents(binary, "019a-tui"), [
    { event: "user", text: "Why does the drawer flicker?" },
    { event: "thinking", delta: "Looking at the drawer." },
    { event: "text", delta: "Reading it." },
    { event: "tool.use", toolUseId: "c1", name: "Shell", input: { command: "cat Drawer.swift", cwd: "/w/p" }, kind: "read", view: { path: "Drawer.swift", command: "cat Drawer.swift" } },
    { event: "tool.result", toolUseId: "c1", content: "struct Drawer {}", isError: false, patch: undefined, exitCode: 0 },
    { event: "text", delta: "It redraws on every scroll." },
    { event: "text", delta: "\n\nFixed by keeping its height." },
  ]);
});

test("OpenCode's sessions are its own commands', run in the folder, and an export reads as a thread's events", async () => {
  const { bin } = await sandbox();
  const folder = await mkdtemp(join(tmpdir(), "oricode-opencode-"));
  const log = `${folder}.log`;
  change("opencode", true, { path: await standInCli(bin, "opencode", "opencode-cli.ts", { OPENCODE_LOG: log }) });
  // The folder is under /var, which is /private/var underneath, where OpenCode says it ran.
  assert.deepEqual(await opencodeSessions.list(await folderAt(folder)), [
    { id: "ses_tidy", agent: "opencode", sessionId: "ses_tidy", title: "Tidy the README", modified: 1790000500000, branch: null },
  ]);
  assert.deepEqual(await opencodeSessions.read("ses_tidy"), [
    { event: "user", text: "Tidy the README" },
    { event: "thinking", delta: "Read it first." },
    { event: "tool.use", toolUseId: "call-read", name: "read", input: { filePath: "/w/p/README.md" }, kind: "read", view: { path: "/w/p/README.md" } },
    { event: "tool.result", toolUseId: "call-read", content: "# p", isError: false, patch: undefined, exitCode: undefined },
    { event: "tool.use", toolUseId: "call-edit", name: "edit", input: { filePath: "/w/p/README.md" }, kind: "edit", view: { path: "/w/p/README.md" } },
    { event: "tool.result", toolUseId: "call-edit", content: "", isError: false, patch: [{ oldStart: 1, newStart: 1, lines: ["-# p", "+# P"] }], exitCode: undefined },
    { event: "tool.use", toolUseId: "call-test", name: "bash", input: { command: "make test" }, kind: "run", view: { command: "make test" } },
    { event: "tool.result", toolUseId: "call-test", content: "exit 2", isError: true, patch: undefined, exitCode: 2 },
    { event: "text", delta: "Capitalised the title." },
  ]);
  const runs = (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(runs[0].args, ["session", "list", "--format", "json", "--max-count", "40"]);
  assert.equal(runs[0].cwd, await realpath(folder));
  change("opencode", false, {});
});

/// What the Cursor store fixture holds, as a thread's events.
const cursorTranscript = [
  { event: "user", text: "What does make test run?" },
  { event: "text", delta: "Reading the Makefile." },
  { event: "tool.use", toolUseId: "call-1", name: "Read", input: { path: "/w/p/Makefile" }, kind: "read", view: { path: "/w/p/Makefile" } },
  { event: "tool.result", toolUseId: "call-1", content: "test:\n\tnode --test", isError: false },
  { event: "text", delta: "It runs node --test." },
];

test("Cursor's chats from Terminal are listed by where they ran, come in to be handed over, and read in their root's order", async () => {
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  const chats = join(home, ".cursor", "chats", "f5c3");
  await storeAt(join(chats, "chat-1", "store.db"), "cursor-store.sql");
  await writeFile(join(chats, "chat-1", "meta.json"), JSON.stringify({ schemaVersion: 1, cwd: "/w/p", title: "Make test", hasConversation: true, updatedAtMs: 5 }));
  await mkdir(join(chats, "chat-2"));
  await writeFile(join(chats, "chat-2", "meta.json"), JSON.stringify({ schemaVersion: 1, cwd: "/w/p", hasConversation: false, updatedAtMs: 6 }));
  assert.deepEqual(await chatsIn(await folderAt("/w/p"), home), [{ id: "chat-1", agent: "cursor", sessionId: null, title: "Make test", modified: 5, branch: null }]);
  assert.deepEqual(await chatEvents("chat-1", home), cursorTranscript);
  assert.deepEqual((await readdir(join(chats, "chat-1"))).sort(), ["meta.json", "store.db"]);
});

test("Copilot's sessions are listed by their first message, without OriCode's own, and read from their log without a subagent's", async () => {
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  await cp(fixture("copilot"), join(home, ".copilot", "session-state"), { recursive: true });
  assert.deepEqual(await copilotSessionsIn(await folderAt("/w/p"), home), [
    { id: "0c6b1f2e-cli", agent: "copilot", sessionId: "0c6b1f2e-cli", title: "List the tests", modified: Date.parse("2026-09-19T09:05:00.000Z"), branch: null },
  ]);
  assert.deepEqual(await copilotEvents("0c6b1f2e-cli", home), [
    { event: "user", text: "List the tests\nand count them" },
    { event: "thinking", delta: "Glob for them." },
    { event: "text", delta: "Looking." },
    { event: "tool.use", toolUseId: "tc1", name: "glob", input: { pattern: "test/*.ts" }, kind: "search", view: { pattern: "test/*.ts" } },
    { event: "tool.result", toolUseId: "tc1", content: "test/a.test.ts\ntest/b.test.ts", isError: false },
    { event: "text", delta: "Two." },
  ]);
  assert.deepEqual(workspace('summary: "A: b"\nname: \'c\'\n'), { summary: "A: b", name: "c" });
});

test("T3 Code's threads come in on the agent underneath where it can pick the session up, and read from its transcript or else T3 Code's copy", async () => {
  const home = await mkdtemp(join(tmpdir(), "oricode-home-"));
  await storeAt(join(home, ".t3", "userdata", "state.sqlite"), "t3code.sql");
  await storeAt(join(home, ".cursor", "acp-sessions", "acp-1", "store.db"), "cursor-store.sql");
  assert.deepEqual(await t3ThreadsIn(await folderAt("/w/p"), home), [
    { id: "t-cursor", agent: "cursor", sessionId: "acp-1", title: "Make test, explained", modified: Date.parse("2026-09-20T10:00:00.000Z"), branch: "main" },
    // Claude Code ran it under another path to the folder, and keeps it no longer.
    { id: "t-claude", agent: "claude", sessionId: null, title: "Before the move", modified: Date.parse("2026-09-19T10:00:00.000Z"), branch: null },
    { id: "t-grok", agent: null, sessionId: null, title: "On Grok", modified: Date.parse("2026-09-18T10:00:00.000Z"), branch: null },
  ]);
  assert.deepEqual(await t3ThreadEvents("t-cursor", home), cursorTranscript);
  assert.deepEqual(await t3ThreadEvents("t-claude", home), [
    { event: "user", text: "Where does the store live?" },
    { event: "text", delta: "In Application Support." },
    { event: "text", delta: "\n\nUnder OriCode." },
  ]);
  assert.deepEqual(storeEvents(join(home, ".cursor", "acp-sessions", "acp-1")), cursorTranscript);
});

test("the engine lists a folder's sessions from every tool it finds, and reads one by its source", async (t) => {
  const { bin, env } = await sandbox();
  const home = env.HOME!;
  await cp(fixture("claude"), join(home, ".claude", "projects"), { recursive: true });
  await storeAt(join(home, ".t3", "userdata", "state.sqlite"), "t3code.sql");
  await storeAt(join(home, ".cursor", "acp-sessions", "acp-1", "store.db"), "cursor-store.sql");
  await cp(fixture("copilot"), join(home, ".copilot", "session-state"), { recursive: true });
  const codex = await standInCli(bin, "codex", "codex-app-server.ts", {});
  const engine = engineWith({ ...env, CLAUDE_CONFIG_DIR: join(home, ".claude") });
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: codex } } });
  const listed = await engine.request("sessions.list", { cwd: "/w/p" });
  assert.deepEqual(
    listed.result.sessions.map((session: any) => [session.sourceName, session.id, session.agent, session.sessionId]),
    [
      // Claude Code's is as new as its transcript's file, copied in just now.
      ["Claude Code", "5b3c1a9e-0000-4000-8000-000000000001", "claude", "5b3c1a9e-0000-4000-8000-000000000001"],
      ["Codex", "019a-tui", "codex", "019a-tui"],
      ["Codex", "019a-app", "codex", "019a-app"],
      ["T3 Code", "t-cursor", "cursor", "acp-1"],
      ["T3 Code", "t-claude", "claude", null],
      ["Copilot", "0c6b1f2e-cli", "copilot", "0c6b1f2e-cli"],
      ["T3 Code", "t-grok", null, null],
    ],
  );
  const read = await engine.request("sessions.read", { source: "claude", id: "5b3c1a9e-0000-4000-8000-000000000001" });
  assert.deepEqual(read.result.events, [
    { event: "user", text: "Read the Makefile" },
    { event: "tool.use", toolUseId: "toolu_1", name: "Read", input: { file_path: "/w/p/Makefile" } },
    { event: "tool.result", toolUseId: "toolu_1", content: "all:", isError: false },
    { event: "text", delta: "It builds everything." },
  ]);
  await engine.end();
});

test("a Claude Code session's messages become a thread's events, without what the CLI wrote for itself or a subagent said", async () => {
  const main = { parent_tool_use_id: null, parent_agent_id: null, uuid: "u", session_id: "s" };
  const read = (async () => [
    { ...main, type: "user", message: { content: "<command-name>/clear</command-name>" } },
    { ...main, type: "user", message: { content: "Read the Makefile" } },
    { ...main, type: "assistant", message: { content: [{ type: "thinking", thinking: "Which one?" }, { type: "text", text: "Reading it." }, { type: "tool_use", id: "t1", name: "Read", input: { file_path: "Makefile" } }] } },
    { ...main, type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "all:" }] }] } },
    { ...main, type: "assistant", parent_tool_use_id: "t9", message: { content: [{ type: "text", text: "A subagent's." }] } },
    { ...main, type: "assistant", message: { content: [{ type: "text", text: "It builds everything." }] } },
  ]) as never;
  assert.deepEqual(await claudeEvents("s", read), [
    { event: "user", text: "Read the Makefile" },
    { event: "thinking", delta: "Which one?" },
    { event: "text", delta: "Reading it." },
    { event: "tool.use", toolUseId: "t1", name: "Read", input: { file_path: "Makefile" } },
    { event: "tool.result", toolUseId: "t1", content: "all:", isError: false },
    { event: "text", delta: "It builds everything." },
  ]);
});
