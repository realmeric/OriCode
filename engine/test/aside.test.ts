// A side question, with the SDK's query stood in for: nothing reaches a model.
import { test } from "node:test";
import assert from "node:assert/strict";
import { aside, asideLead } from "../claude.ts";
import { drawing } from "../provider.ts";

function standIn(messages: any[], seen: any[]) {
  return ((args: { prompt: string; options: any }) => {
    seen.push(args);
    return {
      async *[Symbol.asyncIterator]() {
        for (const message of messages) yield message;
      },
      interrupt: async () => {},
    };
  }) as never;
}

const delta = (text: string) => ({ type: "stream_event", parent_tool_use_id: null, event: { type: "content_block_delta", delta: { type: "text_delta", text } } });

test("a side question forks the thread's session without saving it, refuses every tool, and streams its answer", async () => {
  const seen: any[] = [];
  const told: string[] = [];
  const launch = standIn([delta("zebra"), delta("-9"), { type: "result", subtype: "success", result: "zebra-9\n" }], seen);
  const answer = await aside("/bin/claude", { cwd: "/tmp", sessionId: "s-1", model: "sonnet", text: "What was the word?" }, (text) => told.push(text), new AbortController().signal, {}, launch);
  assert.equal(answer, "zebra-9");
  assert.deepEqual(told, ["zebra", "-9"]);
  const { prompt, options } = seen[0];
  assert.equal(prompt, `${asideLead}\n\nWhat was the word?`);
  assert.deepEqual(
    [options.resume, options.forkSession, options.persistSession, options.maxTurns, options.model],
    ["s-1", true, false, 1, "sonnet"],
  );
  // The thread's own system prompt and settings, so the request reads the thread's cached prompt.
  assert.deepEqual(options.systemPrompt, { type: "preset", preset: "claude_code", append: drawing });
  assert.deepEqual(options.settingSources, ["user", "project", "local"]);
  assert.equal((await options.canUseTool("Bash", {})).behavior, "deny");
});

test("a side question that ran out of its one turn answers with what it streamed, and with nothing says so", async () => {
  const cut = standIn([delta("Partly"), { type: "result", subtype: "error_max_turns" }], []);
  assert.equal(await aside("/bin/claude", { cwd: "/tmp", sessionId: "s", text: "?" }, () => {}, new AbortController().signal, {}, cut), "Partly");
  const empty = standIn([{ type: "result", subtype: "error_max_turns" }], []);
  await assert.rejects(aside("/bin/claude", { cwd: "/tmp", sessionId: "s", text: "?" }, () => {}, new AbortController().signal, {}, empty), /No answer came back/);
});
