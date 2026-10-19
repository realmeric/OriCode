// A head moving itself and a thread's budget, through a Thread whose CLI is a stand-in, so nothing
// reaches Claude.
import { tmpdir } from "node:os";
import { after, test } from "node:test";
import assert from "node:assert/strict";
import type { SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { Rays, type Seam } from "../rays.ts";
import { Thread } from "../thread.ts";

const write = process.stdout.write.bind(process.stdout);
process.stdout.write = ((chunk: string | Uint8Array, ...rest: any[]) => (typeof chunk === "string" && chunk.startsWith('{"event"') ? true : write(chunk, ...rest))) as typeof process.stdout.write;
after(() => (process.stdout.write = write));

/// A CLI that yields the frames it's fed and keeps what it was launched with and asked.
function standIn() {
  const frames: unknown[] = [];
  let wake: (() => void) | undefined;
  const cli = {
    launched: [] as Record<string, any>[],
    /// The CLI's running total, as /usage reports it.
    total: 0,
    calls: [] as string[],
    feed(message: unknown) {
      frames.push(message);
      wake?.();
    },
    launch: ({ prompt, options }: { prompt: AsyncIterable<SDKUserMessage>; options: Record<string, any> }) => {
      cli.launched.push(options);
      void (async () => {
        for await (const _ of prompt);
      })();
      return {
        async *[Symbol.asyncIterator]() {
          while (true) {
            if (frames.length) yield frames.shift();
            else await new Promise<void>((resolve) => (wake = resolve));
          }
        },
        interrupt: async () => {},
        initializationResult: () => Promise.reject(new Error("no CLI here")),
        setPermissionMode: async () => {},
        setModel: async (model?: string) => void cli.calls.push(`model ${model}`),
        applyFlagSettings: async (settings: object) => void cli.calls.push(`flags ${JSON.stringify(settings)}`),
        usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET: async () => ({ session: { total_cost_usd: cli.total } }),
        close: () => {},
      };
    },
  };
  return cli;
}

const params = (more: object = {}) => ({ threadId: "t", cwd: tmpdir(), text: "go", permissionMode: "default" as const, model: "sonnet", effort: "low" as const, ...more });
const result = (subtype = "success") => ({
  type: "result",
  subtype,
  session_id: "s",
  num_turns: 1,
  duration_ms: 10,
  total_cost_usd: 0.2,
  usage: { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 },
  modelUsage: {},
  errors: [],
});
const settle = () => new Promise((resolve) => setImmediate(resolve));

test("a head moves itself in its running turn, and the send after, carrying the move, keeps the same CLI", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params());
  assert.equal(await thread.retune("opus", "high"), true);
  assert.deepEqual(cli.calls, ["model opus", 'flags {"effortLevel":"high"}']);
  // A level alone leaves the model as it is.
  assert.equal(await thread.retune(undefined, "max"), true);
  assert.deepEqual(cli.calls.slice(2), ['flags {"effortLevel":"max"}']);
  cli.feed(result());
  await settle();
  await thread.send(params({ model: "opus", effort: "max" }));
  assert.equal(cli.launched.length, 1);
  // Moved back by the user in the picker, the next send starts the CLI with what they picked.
  cli.feed(result());
  await settle();
  await thread.send(params({ model: "sonnet", effort: "low" }));
  assert.equal(cli.launched.length, 2);
});

test("with no CLI running there is nothing to move, and the next send carries it", async () => {
  const thread = new Thread("t", "claude", standIn().launch as never);
  assert.equal(await thread.retune("opus", "high"), false);
});

test("a budget caps the CLI at what the thread has left, and a CLI that reached its cap is started again with what's left then", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  await thread.send(params({ spendCap: { limit: 1, left: 0.8 } }));
  assert.equal(cli.launched[0].maxBudgetUsd, 0.8);
  cli.feed(result());
  await settle();
  // The same budget with less left keeps the CLI, whose own count goes on.
  await thread.send(params({ spendCap: { limit: 1, left: 0.6 } }));
  assert.equal(cli.launched.length, 1);
  cli.feed(result("error_max_budget_usd"));
  await settle();
  await thread.send(params({ spendCap: { limit: 1, left: 0.1 } }));
  assert.equal(cli.launched.length, 2);
  assert.equal(cli.launched[1].maxBudgetUsd, 0.1);
  // No budget, no cap.
  const plain = standIn();
  await new Thread("u", "claude", plain.launch as never).send(params());
  assert.equal(plain.launched[0].maxBudgetUsd, undefined);
});

test("a running turn's spend is the CLI's running total less where it stood when the turn began", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  assert.equal(await thread.spentThisTurn(), undefined);
  await thread.send(params());
  cli.total = 0.05;
  assert.equal(await thread.spentThisTurn(), 0.05);
  cli.feed({ ...result(), total_cost_usd: 0.2 });
  await settle();
  // Between turns nothing is running to count.
  assert.equal(await thread.spentThisTurn(), undefined);
  await thread.send(params());
  cli.total = 0.26;
  assert.ok(Math.abs((await thread.spentThisTurn())! - 0.06) < 1e-9);
});

test("under a budget each tool waits on the thread's count, and one at the line isn't run", async () => {
  const cli = standIn();
  const thread = new Thread("t", "claude", cli.launch as never);
  let over = false;
  await thread.send(params({ spendCap: { limit: 1, left: 0.8, over: async () => over } }));
  const [gate] = cli.launched[0].hooks.PreToolUse[0].hooks;
  assert.deepEqual(await gate({}, "c1", { signal: new AbortController().signal }), { continue: true });
  // The send after carries the count it asks, without starting the CLI again.
  cli.feed(result());
  await settle();
  await thread.send(params({ spendCap: { limit: 1, left: 0.6, over: async () => !over } }));
  over = true;
  assert.deepEqual(await gate({}, "c2", { signal: new AbortController().signal }), { continue: true });
  over = false;
  const refused = await gate({}, "c3", { signal: new AbortController().signal });
  assert.equal(refused.continue, false);
  assert.equal(refused.hookSpecificOutput.permissionDecision, "deny");
  assert.equal(cli.launched.length, 1);
  // No budget, no hook.
  const plain = standIn();
  await new Thread("u", "claude", plain.launch as never).send(params());
  assert.equal(plain.launched[0].hooks, undefined);
});

test("checks that ask at once take turns, so only the one that crosses the line stops the thread, and every one answers true", async () => {
  let interrupts = 0;
  let asked = 0;
  const seam = {
    inFlight: async () => {
      asked += 1;
      await new Promise((done) => setTimeout(done, 20));
      return 1.2;
    },
    interrupt: async () => void (interrupts += 1),
  } as unknown as Seam;
  const rays = new Rays("budget-race", seam, 1, false);
  rays.update(tmpdir(), "default", [], "", undefined, { picked: [], unread: [], keepOff: [], budget: 1, spent: 0, agent: "claude", model: "sonnet" });
  const first = rays.over();
  // Asked while the first reads, the second waits for it, and by then the line was crossed.
  await settle();
  const second = rays.over();
  assert.deepEqual(await Promise.all([first, second, rays.over()]), [true, true, true]);
  await settle();
  assert.equal(interrupts, 1);
  assert.equal(asked, 1);
  rays.close();
});
