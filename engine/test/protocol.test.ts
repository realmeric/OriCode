// Exercises the wire protocol without starting Claude, so the suite costs nothing.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { after, test } from "node:test";
import assert from "node:assert/strict";

const engine = spawn(process.execPath, [new URL("../main.ts", import.meta.url).pathname], { stdio: ["pipe", "pipe", "inherit"] });
const lines = createInterface({ input: engine.stdout });
const waiting: ((message: any) => void)[] = [];
lines.on("line", (line) => waiting.shift()?.(JSON.parse(line)));

function next(): Promise<any> {
  return new Promise((resolve) => waiting.push(resolve));
}

function request(id: number, method: string, params?: object): Promise<any> {
  const reply = next();
  engine.stdin.write(JSON.stringify({ id, method, params }) + "\n");
  return reply;
}

after(() => engine.stdin.end());

test("an unknown method is an error with the same id", async () => {
  assert.deepEqual(await request(1, "nope"), { id: 1, error: "Unknown method nope" });
});

test("a line that isn't JSON is an engine error event", async () => {
  const reply = next();
  engine.stdin.write("hello there\n");
  const message = await reply;
  assert.equal(message.event, "error");
  assert.equal(message.threadId, undefined);
});

test("answering a question nobody asked says so", async () => {
  const reply = await request(2, "answer", { requestId: "missing", allow: true });
  assert.equal(reply.id, 2);
  assert.match(reply.error, /no longer waiting/);
});

test("setMode on a thread with no turn holds for the next one", async () => {
  assert.deepEqual(await request(3, "setMode", { threadId: "t", permissionMode: "plan" }), { id: 3, result: { applied: true } });
});

test("interrupting an idle thread is fine", async () => {
  assert.deepEqual(await request(4, "interrupt", { threadId: "t" }), { id: 4, result: { ok: true } });
});

test("the window hidden, with no thread holding a CLI, lets nothing go", async () => {
  assert.deepEqual(await request(6, "window", { threadId: "t", visible: false }), { id: 6, result: { ok: true } });
});

test("a send into a missing folder is refused", async () => {
  const reply = await request(5, "send", { threadId: "t", cwd: "/nowhere/at/all", text: "hi", permissionMode: "default" });
  assert.match(reply.error, /isn't where it was/);
});
