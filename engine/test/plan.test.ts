// A project's plan through the real engine: a stand-in Codex in the thread's place, the test
// calling the plan tools over MCP as its agent would and answering the app's events as the app
// would, and a thread working a task told it ahead of its messages.
import { chmod, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import { taskLead } from "../plan.ts";
import { leading, opening } from "../threads.ts";
import { engineWith, sandbox } from "./engine.ts";

async function mcp(url: string, method: string, params: object = {}): Promise<any> {
  const response = await fetch(url, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  assert.equal(response.status, 200);
  return (await response.json()).result;
}

async function call(url: string, name: string, args: object = {}): Promise<any> {
  const result = await mcp(url, "tools/call", { name, arguments: args });
  const text = result.content[0].text;
  return result.isError ? { error: text } : JSON.parse(text);
}

async function codex(t: { after: (fn: () => unknown) => void }) {
  const { bin, env } = await sandbox();
  const log = join(await mkdtemp(join(tmpdir(), "oricode-plan-logs-")), "codex.log");
  const standIn = new URL("./fixtures/codex-app-server.ts", import.meta.url).pathname;
  await writeFile(join(bin, "codex"), `#!/bin/sh\nexport CODEX_LOG='${log}'\ncase "$*" in\n  --version) echo "codex-cli 9.9.9" ;;\n  *) exec "${process.execPath}" "${standIn}" "$@" ;;\nesac\n`);
  await chmod(join(bin, "codex"), 0o755);
  const cwd = await mkdtemp(join(tmpdir(), "oricode-plan-"));
  const engine = engineWith(env);
  t.after(engine.kill);
  await engine.request("hello", { agents: { codex: { path: join(bin, "codex") } } });
  const turn = async (threadId: string, more: object = {}) => {
    const from = engine.lines.length;
    assert.deepEqual((await engine.request("send", { threadId, cwd, text: "hello", permissionMode: "default", provider: "codex", ...more })).result, { ok: true });
    await engine.until((line) => line.event === "turn.done" && line.threadId === threadId, from);
  };
  const logged = async (method: string) => (await readFile(log, "utf8")).trim().split("\n").map((line) => JSON.parse(line)).filter((message) => message.method === method).map((message) => message.params);
  return { engine, cwd, turn, logged };
}

test("the plan's tools go to the app with what they name, and the app's answer is the tool's", async (t) => {
  const { engine, turn, logged } = await codex(t);
  await turn("lead");
  const url: string = (await logged("thread/start"))[0].config["mcp_servers.oricode"].url;
  const tools = (await mcp(url, "tools/list")).tools;
  const described = (name: string) => tools.find((tool: { name: string }) => tool.name === name);
  assert.match(described("read_plan").description, /It reads and changes nothing\./);
  assert.deepEqual(described("add_tasks").inputSchema.properties.tasks.items.required, ["title", "done"]);
  assert.deepEqual(described("claim_task").inputSchema.required, ["task"]);
  assert.equal(described("update_task").inputSchema.required, undefined);
  assert.match(described("open_thread").inputSchema.properties.task.description, /takes it as it opens/);
  assert.match(opening, /write every part as a task of the project's plan with add_tasks and `run`/);
  assert.match(described("add_tasks").description, /With `run`, OriCode runs them for you/);
  assert.equal(described("add_tasks").inputSchema.properties.run.type, "boolean");
  assert.match(described("wait_plan").description, /`planDone` says every task you run is done/);

  const answered = async (name: string, args: object, event: string, answer: object) => {
    const from = engine.lines.length;
    const calling = call(url, name, args);
    const { requestId, ...asked } = await engine.until((line) => line.event === event, from);
    await engine.request("app.reply", { requestId, result: answer });
    assert.deepEqual(await calling, answer);
    return asked;
  };
  const tasks = [{ title: "Write a.py", done: "a.py runs" }, { title: "Test a.py", done: "its tests pass", waitsOn: ["Write a.py"] }];
  assert.deepEqual(await answered("add_tasks", { tasks }, "plan.add", { added: ["T1", "T2"] }), { event: "plan.add", threadId: "lead", tasks });
  // A task named by its number waits on it as by its id, never on nothing.
  assert.deepEqual(await answered("add_tasks", { tasks: [{ title: "Run a.py", done: "it ran", waitsOn: [1, "T2"] }] }, "plan.add", { added: ["T3"] }), {
    event: "plan.add", threadId: "lead", tasks: [{ title: "Run a.py", done: "it ran", waitsOn: ["1", "T2"] }],
  });
  assert.deepEqual(await answered("read_plan", { project: "x" }, "plan.read", { plan: [] }), { event: "plan.read", threadId: "lead" });
  assert.deepEqual(await answered("claim_task", { task: " T1 " }, "plan.claim", { id: "T1" }), { event: "plan.claim", threadId: "lead", task: "T1" });
  assert.deepEqual(await answered("update_task", { state: "done", note: "Runs.", waitsOn: ["T3", 4], thread: "x" }, "plan.update", { id: "T1" }), {
    event: "plan.update", threadId: "lead", state: "done", note: "Runs.", waitsOn: ["T3", "4"],
  });

  // What the app refuses, the agent reads; what can't be asked, the engine refuses itself.
  const from = engine.lines.length;
  const refused = call(url, "claim_task", { task: "T2" });
  const { requestId } = await engine.until((line) => line.event === "plan.claim", from);
  await engine.request("app.reply", { requestId, error: "T2 waits on T1, which isn't done." });
  assert.deepEqual(await refused, { error: "T2 waits on T1, which isn't done." });
  const asked = engine.lines.length;
  assert.match((await call(url, "add_tasks", { tasks: [] })).error, /add_tasks needs `tasks`/);
  assert.match((await call(url, "claim_task", {})).error, /Name the task/);
  assert.equal(engine.lines.slice(asked).some((line) => line.requestId), false);

  // open_thread names the task the thread is for.
  const opens = engine.lines.length;
  const opened = call(url, "open_thread", { title: "Write a.py", message: "Write a.py.", reason: "T1 waits on nothing.", task: "T1" });
  const open = await engine.until((line) => line.event === "thread.open", opens);
  assert.equal(open.task, "T1");
  await engine.request("app.reply", { requestId: open.requestId, result: { id: "C1" } });
  await opened;
  await engine.end();
});

test("a thread working a task hears it ahead of each message that starts a turn, and only then", async (t) => {
  const { engine, cwd, turn, logged } = await codex(t);
  const task = { id: "T2", title: "Test a.py", done: "its tests pass" };
  await turn("worker", { task, from: { id: "LEAD", title: "Lead" } });
  await turn("worker", { text: "and now?", task });
  // A message sent into the running turn carries the task as every send does, and isn't told it.
  const from = engine.lines.length;
  const send = (text: string) => engine.request("send", { threadId: "worker", cwd, text, permissionMode: "default", provider: "codex", task });
  assert.deepEqual((await send("slow")).result, { ok: true });
  await engine.until((line) => line.event === "text" && line.threadId === "worker", from);
  assert.deepEqual((await send("and the tests")).result, { ok: true, waiting: true });
  await engine.until((line) => line.event === "turn.done" && line.threadId === "worker", from);
  // Once the task is done the app sends none, and the thread hears none.
  await turn("worker", { text: "thanks" });
  const [first, second, third, fourth] = await logged("turn/start");
  const lead = JSON.stringify(taskLead(task)).slice(1, -1);
  assert.equal(JSON.stringify(first.input).includes(JSON.stringify(`${leading}\n\n${taskLead(task)}\n\n[From another thread]`).slice(1, -1)), true);
  assert.match(taskLead(task), /^\[OriCode\] This thread works T2 of the project's plan, "Test a\.py"\. Done means: its tests pass /);
  // A task its plan runs is done when the turn ends, which its thread is told.
  assert.equal(taskLead(task).includes("when your turn ends"), false);
  assert.match(taskLead({ ...task, run: true }), /The plan runs by itself: when your turn ends the task is done, and your last reply is its result/);
  assert.equal(JSON.stringify(second.input).includes(`${lead}\\n\\nand now?`), true);
  assert.equal(JSON.stringify(third.input).includes(`${lead}\\n\\nslow`), true);
  const [steer] = await logged("turn/steer");
  assert.deepEqual(steer.input.map((part: { text: string }) => part.text), ["and the tests"]);
  assert.doesNotMatch(JSON.stringify(fourth.input), /works T2/);
  await engine.end();
});
