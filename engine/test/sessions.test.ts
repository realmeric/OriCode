// A CLI session read as a thread's events, with the SDK's readers stood in for.
import { test } from "node:test";
import assert from "node:assert/strict";
import { sessionEvents, sessionsIn } from "../sessions.ts";

test("a folder's CLI sessions are listed by their title, without the engine's own", async () => {
  const asked: any[] = [];
  const list = (async (options: any) => {
    asked.push(options);
    return [
      { sessionId: "a", summary: "Fix the drawer", lastModified: 2, customTitle: "Drawer", gitBranch: "main" },
      { sessionId: "b", summary: "", lastModified: 1, firstPrompt: "hello there" },
    ];
  }) as never;
  assert.deepEqual(await sessionsIn("/tmp/p", list), [
    { id: "a", title: "Drawer", modified: 2, branch: "main" },
    { id: "b", title: "hello there", modified: 1, branch: null },
  ]);
  assert.deepEqual(asked[0], { dir: "/tmp/p", limit: 40, includeWorktrees: false, includeProgrammatic: false });
});

test("a session's messages become a thread's events, without what the CLI wrote for itself or a subagent said", async () => {
  const main = { parent_tool_use_id: null, parent_agent_id: null, uuid: "u", session_id: "s" };
  const read = (async () => [
    { ...main, type: "user", message: { content: "<command-name>/clear</command-name>" } },
    { ...main, type: "user", message: { content: "Read the Makefile" } },
    { ...main, type: "assistant", message: { content: [{ type: "thinking", thinking: "Which one?" }, { type: "text", text: "Reading it." }, { type: "tool_use", id: "t1", name: "Read", input: { file_path: "Makefile" } }] } },
    { ...main, type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: [{ type: "text", text: "all:" }] }] } },
    { ...main, type: "assistant", parent_tool_use_id: "t9", message: { content: [{ type: "text", text: "A subagent's." }] } },
    { ...main, type: "assistant", message: { content: [{ type: "text", text: "It builds everything." }] } },
  ]) as never;
  assert.deepEqual(await sessionEvents("/tmp/p", "s", read), [
    { event: "user", text: "Read the Makefile" },
    { event: "thinking", delta: "Which one?" },
    { event: "text", delta: "Reading it." },
    { event: "tool.use", toolUseId: "t1", name: "Read", input: { file_path: "Makefile" } },
    { event: "tool.result", toolUseId: "t1", content: "all:", isError: false },
    { event: "text", delta: "It builds everything." },
  ]);
});
