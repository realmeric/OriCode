// K-391: the engine sends a thread's deltas once a frame. Frames on a clock and timer of the
// test's own, then the whole engine with a stand-in Claude that streams a thousand deltas a second.
import { tmpdir } from "node:os";
import { test } from "node:test";
import assert from "node:assert/strict";
import { Frames, frame, hiddenFrame } from "../frames.ts";
import { engineWith, sandbox, standInCli } from "./engine.ts";

/// A Frames whose time moves only when the test moves it.
function framesOnAClock(length = () => frame) {
  const sent: Record<string, unknown>[] = [];
  let now = 0;
  const timers: { at: number; run: () => void }[] = [];
  const frames = new Frames({
    send: (message) => sent.push(message),
    length,
    now: () => now,
    later: (run, ms) => {
      const timer = { at: now + ms, run };
      timers.push(timer);
      return timer as unknown as ReturnType<typeof setTimeout>;
    },
  });
  const advance = (ms: number) => {
    const until = now + ms;
    for (;;) {
      const due = timers.filter((timer) => timer.at <= until).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      timers.splice(timers.indexOf(due), 1);
      now = due.at;
      due.run();
    }
    now = until;
  };
  const text = (delta: string) => frames.delta("t", "text", delta, (joined, parts) => ({ event: "text", threadId: "t", delta: joined, ...(parts ? { parts } : {}) }));
  return { frames, sent, advance, text };
}

test("the first delta goes at once and the frame's others go together when it ends", () => {
  const { sent, advance, text } = framesOnAClock();
  text("Hello");
  assert.deepEqual(sent, [{ event: "text", threadId: "t", delta: "Hello" }]);
  advance(3);
  text(" there");
  advance(5);
  text(", you");
  assert.equal(sent.length, 1);
  advance(8);
  assert.deepEqual(sent[1], { event: "text", threadId: "t", delta: " there, you", parts: [[0, 6], [5, 5]] });
});

test("a steady stream is one message a frame, and a lull lets the next delta go at once", () => {
  const { sent, advance, text } = framesOnAClock();
  for (let i = 0; i < 160; i++) {
    text(`w${i} `);
    advance(1);
  }
  advance(frame);
  assert.ok(sent.length >= 10 && sent.length <= 12, `${sent.length} messages for 160 ms`);
  assert.equal(sent.map((message) => message.delta).join(""), Array.from({ length: 160 }, (_, i) => `w${i} `).join(""));
  advance(100);
  const before = sent.length;
  text("later");
  assert.equal(sent.length, before + 1);
  assert.equal(sent.at(-1)?.delta, "later");
});

test("a single delta held alone carries no parts", () => {
  const { sent, advance, text } = framesOnAClock();
  text("a");
  advance(2);
  text("b");
  advance(frame);
  assert.deepEqual(sent[1], { event: "text", threadId: "t", delta: "b" });
});

test("thinking after text goes in its own message, in order", () => {
  const { frames, sent, advance, text } = framesOnAClock();
  text("a");
  advance(1);
  text("b");
  frames.delta("t", "thinking", "hmm", (delta) => ({ event: "thinking", threadId: "t", delta }));
  advance(frame);
  assert.deepEqual(sent.map((message) => [message.event, message.delta]), [["text", "a"], ["text", "b"], ["thinking", "hmm"]]);
});

test("what a thread holds goes ahead of its next event, workers' included", () => {
  const { frames, sent, advance, text } = framesOnAClock();
  text("a");
  advance(1);
  text("b");
  frames.delta("t/w1", "text", "worker", (delta) => ({ event: "worker.said", threadId: "t", said: { event: "text", delta } }));
  advance(1);
  frames.delta("t/w1", "text", " words", (delta) => ({ event: "worker.said", threadId: "t", said: { event: "text", delta } }));
  frames.flushThread("other");
  assert.equal(sent.length, 2);
  frames.flushThread("t");
  assert.deepEqual(sent.slice(2), [
    { event: "text", threadId: "t", delta: "b" },
    { event: "worker.said", threadId: "t", said: { event: "text", delta: " words" } },
  ]);
});

test("a hidden window's frame is a quarter second", () => {
  const { sent, advance, text } = framesOnAClock(() => hiddenFrame);
  for (let i = 0; i < 1000; i++) {
    text("w");
    advance(1);
  }
  advance(hiddenFrame);
  assert.ok(sent.length >= 4 && sent.length <= 6, `${sent.length} messages for a second`);
});

test("through the engine, a thousand deltas a second reach the app about once a frame, in order, with the tool call where it was", async () => {
  const { bin, env } = await sandbox();
  const claude = await standInCli(bin, "claude-code", "claude-stream.ts", { CLAUDE_STREAM_RATE: "1000", CLAUDE_STREAM_COUNT: "2000", CLAUDE_STREAM_TOOL: "1" });
  const engine = engineWith({ ...env, ORICODE_CLAUDE: claude });
  try {
    const started = performance.now();
    void engine.request("send", { threadId: "s", cwd: tmpdir(), text: "Stream", permissionMode: "default" });
    await engine.until((line) => line.event === "text");
    const firstWord = performance.now() - started;
    const done = await engine.until((line) => line.event === "turn.done");
    assert.ok(done);
    const events = engine.lines.filter((line) => line.threadId === "s" && ["text", "tool.use"].includes(line.event));
    const texts = events.filter((line) => line.event === "text");
    const expected = Array.from({ length: 2000 }, (_, i) => `w${i} `).join("");
    assert.equal(texts.map((line) => line.delta).join(""), expected);
    const call = events.findIndex((line) => line.event === "tool.use");
    assert.ok(call > 0);
    assert.ok(events.slice(0, call).map((line) => line.delta).join("").endsWith("w999 "), "what came before the call was sent before it");
    const span = 2;
    assert.ok(texts.length <= span * 75, `${texts.length} messages for ${span} s of a thousand deltas a second`);
    assert.ok(texts.length >= span * 40, `${texts.length} messages: the stream should still come every frame`);
    assert.ok(texts.some((line) => Array.isArray(line.parts)), "a coalesced message says when its parts came");
    console.log(`first word after ${firstWord.toFixed(0)} ms (the CLI's start included); ${texts.length} messages for 2000 deltas in ${span} s`);
  } finally {
    engine.kill();
  }
});
