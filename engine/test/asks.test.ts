// What a Claude thread's ask tells the app of who asked, which the app counts it under.
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { Thread } from "../thread.ts";
import { tap, untap } from "../wire.ts";

test("an ask from a subagent names the subagent, and one from the thread's own loop names nobody", async () => {
  const launched: any[] = [];
  const launch = ((args: { prompt: AsyncIterable<SDKUserMessage>; options: any }) => {
    launched.push(args.options);
    return {
      async *[Symbol.asyncIterator]() {
        await new Promise(() => {});
      },
      initializationResult: () => Promise.reject(new Error("no CLI here")),
      close: () => {},
      interrupt: async () => {},
    };
  }) as never;
  const cwd = await mkdtemp(join(tmpdir(), "oricode-asks-"));
  const thread = new Thread("k286-asks", "claude", launch);
  await thread.send({ threadId: "k286-asks", cwd, text: "Go", permissionMode: "default" });
  const heard: Record<string, unknown>[] = [];
  tap("k286-asks", (name, fields) => {
    if (name === "ask") heard.push(fields);
    return true;
  });
  const stop = new AbortController();
  const asked = launched[0].canUseTool("Bash", { command: "ls" }, { signal: stop.signal, toolUseID: "c1", agentID: "a7" });
  const own = launched[0].canUseTool("Bash", { command: "pwd" }, { signal: stop.signal, toolUseID: "c2" });
  assert.equal(heard.length, 2);
  assert.equal(heard[0].agentId, "a7");
  assert.equal("agentId" in heard[1], false);
  stop.abort();
  assert.equal((await asked).behavior, "deny");
  await own;
  untap("k286-asks");
  thread.close();
});
