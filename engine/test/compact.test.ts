// K-387: a Claude thread whose context passes Settings' threshold is compacted between turns,
// through a Thread whose CLI is a stand-in fed a faked usage, so nothing reaches Claude.
import { tmpdir } from "node:os";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { Thread } from "../thread.ts";

const events: Record<string, any>[] = [];
const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) => {
  if (typeof chunk === "string" && chunk.startsWith('{"event"')) {
    events.push(JSON.parse(chunk));
    return true;
  }
  return write(chunk, ...rest);
}) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// A CLI that yields the frames it's fed and keeps every message sent to it.
function standIn() {
  const frames: unknown[] = [];
  let wake: (() => void) | undefined;
  const sent: string[] = [];
  const cli = {
    sent,
    feed(...messages: unknown[]) {
      frames.push(...messages);
      wake?.();
    },
    launch: (options: { prompt: AsyncIterable<SDKUserMessage> }) => {
      void (async () => {
        for await (const message of options.prompt) sent.push(String(message.message.content));
      })();
      return {
        async *[Symbol.asyncIterator]() {
          while (true) {
            if (frames.length) yield frames.shift();
            else await new Promise<void>((resolve) => (wake = resolve));
          }
        },
        initializationResult: () => Promise.reject(new Error("no CLI here")),
        setPermissionMode: async () => {},
        applyFlagSettings: async () => {},
        close: () => {},
      };
    },
  };
  return cli;
}

const settle = () => new Promise((resolve) => setImmediate(resolve));
const params = (compactAt?: number) => ({ threadId: "t", cwd: tmpdir(), text: "Go", permissionMode: "default" as const, id: "a", compactAt });
/// A call that read `read` tokens of cache, as a turn deep into a long session does.
const call = (read: number) => ({
  type: "assistant",
  session_id: "s",
  parent_tool_use_id: null,
  message: { id: `m${read}`, role: "assistant", content: [{ type: "text", text: "Done." }], usage: { input_tokens: 2_000, cache_read_input_tokens: read, cache_creation_input_tokens: 1_000, output_tokens: 500 } },
});
const result = {
  type: "result",
  subtype: "success",
  session_id: "s",
  num_turns: 1,
  duration_ms: 10,
  total_cost_usd: 0,
  usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  modelUsage: {},
};
const boundary = { type: "system", subtype: "compact_boundary", session_id: "s", compact_metadata: { trigger: "manual", pre_tokens: 260_000, post_tokens: 18_000 } };

test("past the threshold the session is compacted once, after the turn and not during it, and the app hears only that it was", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params(200_000));
  events.length = 0;
  cli.feed(call(257_000));
  await settle();
  assert.deepEqual(cli.sent, ["Go"]);
  cli.feed(result);
  await settle();
  assert.deepEqual(cli.sent, ["Go", "/compact"]);
  assert.equal(thread.isRunning, true);
  cli.feed(boundary, { ...result, num_turns: 0 });
  await settle();
  assert.equal(thread.isRunning, false);
  assert.deepEqual(
    events.map((event) => event.event).filter((name) => name !== "fast"),
    ["turn.started", "text", "turn.done", "compacted"],
  );
  assert.deepEqual(events.at(-1), { event: "compacted", threadId: "t", before: 260_000, after: 18_000 });
  // The next turn starts from the compacted session, under the threshold, and isn't compacted again.
  await thread.send(params(200_000));
  cli.feed(call(15_000), result);
  await settle();
  assert.deepEqual(cli.sent, ["Go", "/compact", "Go"]);
  thread.close();
});

test("at the threshold or under it, and with it off, nothing is compacted", async () => {
  for (const [compactAt, read] of [[undefined, 900_000], [0, 900_000], [200_000, 197_000]] as const) {
    const cli = standIn();
    const thread = new Thread("t", "claude", cli.launch as never);
    await thread.send(params(compactAt));
    cli.feed(call(read), result);
    await settle();
    assert.deepEqual(cli.sent, ["Go"], `compactAt ${compactAt}, ${read} read`);
    assert.equal(thread.isRunning, false);
    thread.close();
  }
});

test("a turn that ends with a background command still out waits for the next to be compacted", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never) as any;
  await thread.send(params(200_000));
  cli.feed(call(300_000));
  await settle();
  thread.backgroundCalls.add("bg");
  cli.feed(result);
  await settle();
  assert.deepEqual(cli.sent, ["Go"]);
  thread.close();
});
