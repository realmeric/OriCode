// A message sent while a turn runs, through a Thread whose CLI is a stand-in, so nothing reaches Claude.
import { tmpdir } from "node:os";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { lifecycleEvent, Thread, type Lifecycle } from "../thread.ts";

const frame = (id: string, state: Lifecycle["state"]): Lifecycle => ({ type: "command_lifecycle", command_uuid: id, state });

test("taken up during a turn, the message joins it", () => {
  assert.deepEqual(lifecycleEvent(frame("b", "started"), new Set(["b"]), true), {
    name: "message.taken",
    id: "b",
    fields: { messageId: "b", newTurn: false },
  });
});

test("taken up with no turn running, it starts one of its own", () => {
  assert.deepEqual(lifecycleEvent(frame("b", "started"), new Set(["b"]), false)?.fields, { messageId: "b", newTurn: true });
});

test("a cancelled message is handed back", () => {
  assert.deepEqual(lifecycleEvent(frame("b", "cancelled"), new Set(["b"]), true), {
    name: "message.cancelled",
    id: "b",
    fields: { messageId: "b" },
  });
});

test("frames about messages that never waited, and queued ones, say nothing", () => {
  assert.equal(lifecycleEvent(frame("a", "started"), new Set(["b"]), true), undefined);
  assert.equal(lifecycleEvent(frame("a", "cancelled"), new Set(), false), undefined);
  assert.equal(lifecycleEvent(frame("a", "completed"), new Set(["b"]), true), undefined);
  assert.equal(lifecycleEvent(frame("b", "queued"), new Set(["b"]), true), undefined);
});

test("any other end for a waiting message hands it back", () => {
  for (const state of ["discarded", "refused", "completed", "something new"]) {
    assert.equal(lifecycleEvent(frame("b", state), new Set(["b"]), true)?.name, "message.cancelled", state);
  }
});

/// The events the thread writes to stdout, kept here instead.
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

/// A CLI that yields the frames it's fed and remembers what it was asked.
function standIn() {
  const frames: unknown[] = [];
  let wake: (() => void) | undefined;
  let prompt: AsyncIterator<SDKUserMessage> | undefined;
  const cli = {
    launches: 0,
    /// The arguments of each interrupt.
    interrupts: [] as unknown[][],
    cancels: [] as string[],
    /// Whether cancelAsyncMessage finds the message still in the queue.
    takesBack: false,
    /// What an interrupt waits on before the CLI answers it.
    answer: Promise.resolve(),
    feed(message: unknown) {
      frames.push(message);
      wake?.();
    },
    next: () => prompt!.next().then((result) => result.value as SDKUserMessage),
    launch: (options: { prompt: AsyncIterable<SDKUserMessage> }) => {
      cli.launches += 1;
      prompt = options.prompt[Symbol.asyncIterator]();
      return {
        async *[Symbol.asyncIterator]() {
          while (true) {
            if (frames.length) yield frames.shift();
            else await new Promise<void>((resolve) => (wake = resolve));
          }
        },
        interrupt: async (...options: unknown[]) => {
          cli.interrupts.push(options);
          await cli.answer;
        },
        cancelAsyncMessage: async (id: string) => {
          cli.cancels.push(id);
          return cli.takesBack;
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

const params = (text: string, id: string, model?: string) => ({ threadId: "t", cwd: tmpdir(), text, permissionMode: "default" as const, id, model });
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
const settle = () => new Promise((resolve) => setImmediate(resolve));
const init = (capabilities: string[]) => ({ type: "system", subtype: "init", session_id: "s", capabilities });
const capable = init(["msg_lifecycle_v1", "interrupt_cancel_queued_v1"]);

/// A thread whose first turn runs, on a CLI that has said in its init that it reports on messages.
async function running(cli: ReturnType<typeof standIn>) {
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params("First", "a"));
  cli.feed(capable);
  await settle();
  return thread;
}

test("a send during a turn goes into it with its id, and the turn goes on", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  assert.equal(await thread.send(params("First", "a")), false);
  assert.equal((await cli.next()).uuid, "a");
  cli.feed(capable);
  await settle();
  assert.equal(await thread.send(params("Also this", "b", "opus")), true);
  const second = await cli.next();
  assert.equal(second.uuid, "b");
  assert.equal(second.message.content, "Also this");
  // Another model mid-turn waits for the next send rather than restarting the CLI.
  assert.equal(cli.launches, 1);
  events.length = 0;
  cli.feed(frame("b", "queued"));
  cli.feed(frame("b", "started"));
  await settle();
  assert.deepEqual(events, [{ event: "message.taken", threadId: "t", messageId: "b", newTurn: false }]);
  thread.close();
});

test("a turn that ends with a message still waiting says so", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  events.length = 0;
  cli.feed(result);
  cli.feed(frame("b", "started"));
  await settle();
  const [done, taken, started] = events.slice(-3);
  assert.equal(done.event, "turn.done");
  assert.equal(done.waiting, 1);
  assert.deepEqual(taken, { event: "message.taken", threadId: "t", messageId: "b", newTurn: true });
  assert.equal(started.event, "turn.started");
  assert.equal(thread.isRunning, true);
  thread.close();
});

test("Stop takes back what waits by its id, even between the turns, and interrupts plainly", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  await thread.interrupt();
  // cancelQueued would also drop the reports of background tasks queued beside b.
  assert.deepEqual(cli.interrupts, [[]]);
  assert.deepEqual(cli.cancels, ["b"]);
  cli.feed(result);
  await settle();
  cli.takesBack = true;
  events.length = 0;
  await thread.interrupt();
  assert.deepEqual(cli.cancels, ["b", "b"]);
  assert.deepEqual(events, [{ event: "message.cancelled", threadId: "t", messageId: "b" }]);
  // Nothing waits and nothing runs, so another Stop has nothing to do.
  await thread.interrupt();
  assert.equal(cli.interrupts.length, 2);
  thread.close();
});

test("closing the CLI hands back what still waits", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  events.length = 0;
  thread.close();
  assert.deepEqual(events, [{ event: "message.cancelled", threadId: "t", messageId: "b" }]);
});

test("sent after the turn ended, the message starts one, said after that turn's end", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await cli.next();
  events.length = 0;
  cli.feed(result);
  await settle();
  assert.equal(await thread.send(params("Also this", "b")), false);
  assert.equal((await cli.next()).uuid, "b");
  const told = events.filter((told) => told.event === "turn.done" || told.event === "message.taken");
  assert.deepEqual(told.map((told) => told.event), ["turn.done", "message.taken"]);
  assert.deepEqual(told[1], { event: "message.taken", threadId: "t", messageId: "b", newTurn: true });
  thread.close();
});

test("a Stop between the turns stops the one the waiting message starts", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  cli.feed(result);
  await settle();
  // The CLI had already started the message's turn when the interrupt reached it.
  await thread.interrupt();
  events.length = 0;
  cli.feed(frame("b", "started"));
  cli.feed({ ...result, subtype: "error_during_execution", errors: ["Request was aborted."] });
  await settle();
  assert.deepEqual(events.map((told) => told.event), ["message.taken", "turn.started", "turn.done"]);
  assert.equal(events[2].stopReason, "interrupted");
  thread.close();
});

test("a Stop the CLI answered before the turn's result doesn't stop the next", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  await thread.interrupt();
  cli.feed(result);
  await settle();
  events.length = 0;
  cli.feed(frame("b", "started"));
  cli.feed(result);
  await settle();
  assert.equal(events.at(-1)!.stopReason, "end_turn");
  thread.close();
});

test("a Stop still on its way as the turn ends by itself stops the next turn rather than failing it", async () => {
  const cli = standIn();
  const thread = await running(cli);
  await thread.send(params("Also this", "b"));
  let answer!: () => void;
  cli.answer = new Promise((resolve) => (answer = resolve));
  const stopping = thread.interrupt();
  events.length = 0;
  // The turn ends before the interrupt reaches the CLI, which takes b up and gets the
  // interrupt in b's turn.
  cli.feed(result);
  cli.feed(frame("b", "started"));
  await settle();
  answer();
  await stopping;
  cli.feed({ ...result, subtype: "error_during_execution", errors: ["Request was aborted."] });
  await settle();
  assert.deepEqual(events.map((told) => told.event), ["turn.done", "message.taken", "turn.started", "turn.done"]);
  assert.equal(events[3].stopReason, "interrupted");
  thread.close();
});

test("a CLI that doesn't report on messages won't take one mid-turn", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params("First", "a"));
  cli.feed(init([]));
  await settle();
  await assert.rejects(thread.send(params("Also this", "b")), /can't take a message during a turn/);
  cli.feed(capable);
  await settle();
  assert.equal(await thread.send(params("Also this", "b")), true);
  thread.close();
});

test("a send before the CLI's init waits for it, then goes in or is refused", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params("First", "a"));
  await cli.next();
  const sent = thread.send(params("Also this", "b"));
  await settle();
  cli.feed(capable);
  assert.equal(await sent, true);
  assert.equal((await cli.next()).uuid, "b");
  thread.close();

  const old = standIn();
  const older = new Thread("t", "claude", old.launch as never);
  await older.send(params("First", "a"));
  const refused = older.send(params("Also this", "b"));
  await settle();
  old.feed(init([]));
  await assert.rejects(refused, /can't take a message during a turn/);
  older.close();
});

test("a Stop or a close before the init hands back what waits for it", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params("First", "a"));
  events.length = 0;
  const stopped = thread.send(params("Also this", "b"));
  await settle();
  await thread.interrupt();
  assert.deepEqual(events, [{ event: "message.cancelled", threadId: "t", messageId: "b" }]);
  assert.deepEqual(cli.cancels, []);
  cli.feed(capable);
  assert.equal(await stopped, true);
  assert.equal((await cli.next()).uuid, "a");
  // b never reaches the CLI.
  assert.equal(await Promise.race([cli.next().then((message) => message.uuid), settle().then(() => "nothing")]), "nothing");
  thread.close();

  const other = standIn();
  const closing = new Thread("t", "claude", other.launch as never);
  await closing.send(params("First", "a"));
  events.length = 0;
  const lost = closing.send(params("Also this", "c"));
  await settle();
  closing.close();
  assert.equal(await lost, true);
  assert.deepEqual(events, [{ event: "message.cancelled", threadId: "t", messageId: "c" }]);
});
