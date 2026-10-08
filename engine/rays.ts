import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { join, relative, resolve } from "node:path";
import { addWorktree, friendly, git } from "./git.ts";
import { stepOf, type Step } from "./heads.ts";
import type { Model } from "./models.ts";
import type { Provider, SendParams, Session } from "./provider.ts";
import { diffArgs, gitRun, parsePatch, top } from "./review.ts";
import { describe } from "./thread.ts";
import { askApp, mostOpened, openThread, Unanswered } from "./threads.ts";
import { version } from "./version.ts";
import { emit, event, log, tap, untap } from "./wire.ts";

// Rays: a thread's head and the workers it sends out. The head is the thread's own session, and a
// worker is a session on any wired agent that the app has no thread for, started through the same
// providers, headless. OriCode serves the head a few tools of its own over MCP, from one HTTP
// server on the loopback that starts with the first head and gives each head a path of its own. A
// worker's events come back through wire.ts's taps: its asks go to the head's thread as the
// thread's own, its cost is added to the thread's in a `worker` event, and it's a head in the
// thread's `heads`, so its ray lights. Nothing here polls: a worker runs only once started, and
// its session is let go when idle like a thread's. A thread with no rays is served here too, for
// the one tool every thread on such an agent has, open_thread (threads.ts).

/// A model a head may send a worker out on, picked for the thread in the model menu.
export type Ray = { agent: string; model: string };

/// A ray as the app sends it, `agent/model`: only the first slash parts them, since an OpenRouter
/// model's id has one of its own.
export function rayOf(ref: string): Ray {
  const slash = ref.indexOf("/");
  return { agent: ref.slice(0, slash), model: ref.slice(slash + 1) };
}

/// What Rays needs of main.ts: the agents, their CLIs, and the sessions it keeps for idle release.
export type Seam = {
  provider(id: string): Provider | undefined;
  cli(agent: Provider): Promise<string>;
  /// The agent's models, listed once for the engine.
  models(agent: Provider): Promise<Model[]>;
  adopt(threadId: string, session: Session): void;
  forget(threadId: string): void;
};

type Hunk = { oldStart: number; newStart: number; lines: string[] };

type Edit = { path: string; hunks: Hunk[] };

type Worker = {
  id: string;
  /// The session's own thread id, which its events carry and the app never sees.
  threadId: string;
  agent: Provider;
  model: string | null;
  effort: string | null;
  mode: string;
  label: string;
  cwd: string;
  /// Its worktree, its branch there and the commit the branch started from.
  isolated: { path: string; branch: string; base: string } | null;
  session: Session;
  sessionId: string | undefined;
  state: "running" | "done" | "failed" | "stopped";
  startedAt: number;
  endedAt: number | null;
  step: Step | null;
  tokens: number;
  tools: number;
  cost: number;
  /// The latest turn's reply.
  text: string;
  error: string | null;
  /// The file each call is on, and the hunks it came with, until its result says it happened.
  calls: Map<string, { path: string; patch: Hunk[] | null }>;
  /// What its edits in the thread's own folder changed, this turn's and every turn's.
  turnEdits: Edit[];
  edits: Edit[];
  /// Messages for after the turn, for an agent that takes none during one.
  pending: string[];
  waiters: (() => void)[];
};

/// A worker's reply to worker_result waits this long at most, under every head's MCP timeout.
const longestWait = 300_000;
/// Workers at work at once in a thread, one to a ray.
const mostAtWork = 6;

const tools = [
  {
    name: "list_agents",
    description: "This thread's rays: the agents and models its workers may run on, with each model's effort levels.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
  {
    name: "start_worker",
    description:
      "Start a worker on one of this thread's rays: another coding agent that takes one task and works on it on its own while you go on. It works in this thread's folder, or with isolated, in a git worktree of its own on a new branch, whose edits reach this folder only when you merge_worker. What it asks the user goes to the user in this thread. Returns the worker's id.",
    inputSchema: {
      type: "object",
      properties: {
        agent: { type: "string", description: "A ray's agent, such as codex or opencode." },
        model: { type: "string", description: "A ray's model on that agent. The agent's first ray when left out." },
        effort: { type: "string", description: "One of the model's effort levels from list_agents. Your own level when left out and the model has it, else the model's default." },
        task: { type: "string", description: "What the worker should do, written for someone who hasn't seen this conversation." },
        isolated: { type: "boolean", description: "Work in a worktree of its own. Use it for a worker that edits files, so its edits can't run into yours or another worker's." },
      },
      required: ["agent", "task"],
    },
  },
  {
    name: "worker_status",
    description: "Where a worker has got: running, done, failed or stopped, what it's doing now, how long it has taken, and its tokens and cost.",
    inputSchema: { type: "object", properties: { worker: { type: "string" } }, required: ["worker"] },
    annotations: { readOnlyHint: true },
  },
  {
    name: "worker_result",
    description:
      "A worker's last reply, the files it changed with the lines added and removed, and its branch when it's isolated. With wait, waits for it to finish first, up to five minutes; call again if it's still working.",
    inputSchema: { type: "object", properties: { worker: { type: "string" }, wait: { type: "boolean" } }, required: ["worker"] },
    annotations: { readOnlyHint: true },
  },
  {
    name: "message_worker",
    description: "Send a worker a message: into its turn while it works, when its agent takes one, else after that turn; to a worker that has finished, as its next turn.",
    inputSchema: { type: "object", properties: { worker: { type: "string" }, text: { type: "string" } }, required: ["worker", "text"] },
  },
  {
    name: "stop_worker",
    description: "Stop a worker's turn. It keeps its session, so a message can start it again.",
    inputSchema: { type: "object", properties: { worker: { type: "string" } }, required: ["worker"] },
  },
  {
    name: "merge_worker",
    description:
      "Bring an isolated worker's edits into this thread's folder with git merge --squash, so they arrive uncommitted, for the user to review beside yours. Reports the files that conflict, which git leaves marked for you to settle.",
    inputSchema: { type: "object", properties: { worker: { type: "string" } }, required: ["worker"] },
  },
];

/// What a head is told of its rays, in the engine's words and not the user's: its tools' MCP
/// instructions, which the ACP agents have no other way to hear, Claude Code's appended system
/// prompt and Codex's developer instructions.
export function brief(rays: Ray[]): string {
  return (
    `You are this thread's head. The user picked these rays for it, as start_worker's agent and model: ${rays.map((ray) => `${ray.agent} ${ray.model}`).join(", ")}. ` +
    "Use them: give the parts of each task a ray can do to a worker on it with start_worker, rather than doing all of it yourself, and bring their work back with worker_result. " +
    "Workers that edit files should work isolated, and you merge what you keep with merge_worker."
  );
}

/// Heads with workers allowed, by thread and by the path of their tools.
const heads = new Map<string, Rays>();
const byPath = new Map<string, Rays>();
let listening: Promise<number> | undefined;

/// The thread's tools, made with their server the first time the thread is given any.
export async function raysFor(threadId: string, seam: Seam, watched: boolean): Promise<Rays> {
  const port = await serve();
  let found = heads.get(threadId);
  if (!found) {
    found = new Rays(threadId, seam, port, watched);
    heads.set(threadId, found);
    byPath.set(found.path, found);
  }
  return found;
}

export function raysOf(threadId: string): Rays | undefined {
  return heads.get(threadId);
}

function serve(): Promise<number> {
  listening ??= new Promise((done, fail) => {
    const server = createServer((request, response) => void reply(request, response));
    server.on("error", fail);
    // On the loopback only; each head's path is a random UUID, which is all another process on
    // the Mac would have to guess.
    server.listen(0, "127.0.0.1", () => done((server.address() as AddressInfo).port));
    server.unref();
  });
  return listening;
}

/// MCP's streamable HTTP, in its plainest form: each request POSTed and answered as JSON, no
/// stream of the server's own, and nothing kept between requests.
async function reply(request: IncomingMessage, response: ServerResponse): Promise<void> {
  const rays = byPath.get(new URL(request.url ?? "/", "http://localhost").pathname);
  if (!rays) return void response.writeHead(404).end();
  if (request.method !== "POST") return void response.writeHead(405, { allow: "POST" }).end();
  request.setEncoding("utf8");
  let body = "";
  for await (const chunk of request) body += chunk;
  let message: { id?: number | string | null; method?: string; params?: any };
  try {
    message = JSON.parse(body);
  } catch {
    return void response.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Not JSON" } }));
  }
  if (message.id === undefined || message.id === null) return void response.writeHead(202).end();
  const answer = await rays.rpc(message.method ?? "", message.params ?? {});
  response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...answer }));
}

export class Rays {
  readonly threadId: string;
  readonly path: string;
  readonly url: string;
  private seam: Seam;
  private workers = new Map<string, Worker>();
  private count = 0;
  /// The heads the thread's own session last listed, which its workers go out after.
  private own: unknown[] = [];
  private watched: boolean;
  private timer: ReturnType<typeof setTimeout> | undefined;
  private told = "";
  /// The thread's folder, its mode, its rays and what the head is told of them, as its latest
  /// send had them.
  private cwd = "";
  private mode = "default";
  private rays: Ray[] = [];
  private instructions = "";
  /// The head's own level, which a worker takes when it's given none and its model has it.
  private level: string | undefined;
  /// Whether the thread may open others, which one another thread opened may not, and how many
  /// its turn has opened.
  private opens = false;
  private opened = 0;

  constructor(threadId: string, seam: Seam, port: number, watched: boolean) {
    this.threadId = threadId;
    this.seam = seam;
    this.watched = watched;
    this.path = `/${randomUUID()}`;
    this.url = `http://127.0.0.1:${port}${this.path}`;
    // The thread's own `heads` go out with its workers after them.
    tap(threadId, (name, fields) => {
      if (name === "turn.started") this.opened = 0;
      if (name !== "heads") return false;
      this.own = (fields.heads as unknown[]) ?? [];
      this.tell();
      return true;
    });
  }

  /// What the thread's latest send says: where it works, in which mode, at what level, and its
  /// rays, none when it has none left, with what the head is told of them: `brief`, or what
  /// workflows on tell it; and whether it may open threads.
  update(cwd: string, mode: string, rays: Ray[], instructions = brief(rays), level?: string, opens = false): void {
    this.cwd = cwd;
    this.mode = mode;
    this.rays = rays;
    this.instructions = instructions;
    this.level = level;
    this.opens = opens;
  }

  has(workerId: string): boolean {
    return this.workers.has(workerId);
  }

  async rpc(method: string, params: any): Promise<{ result: unknown } | { error: { code: number; message: string } }> {
    switch (method) {
      case "initialize":
        return { result: { protocolVersion: params.protocolVersion ?? "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "oricode", title: "OriCode", version }, instructions: this.instructions } };
      case "ping":
        return { result: {} };
      case "tools/list":
        return { result: { tools: [...(this.rays.length ? tools : []), ...(this.opens ? [openThread] : [])] } };
      case "tools/call":
        try {
          const out = await this.call(params.name, params.arguments ?? {});
          return { result: { content: [{ type: "text", text: JSON.stringify(out, null, 2) }] } };
        } catch (error) {
          return { result: { content: [{ type: "text", text: describe(error) }], isError: true } };
        }
      default:
        return { error: { code: -32601, message: `No ${method} here` } };
    }
  }

  call(name: string, args: Record<string, any>): Promise<unknown> {
    switch (name) {
      case "list_agents":
        return this.agents();
      case "start_worker":
        return this.start(args);
      case "worker_status":
        return Promise.resolve(this.status(this.worker(args.worker)));
      case "worker_result":
        return this.result(this.worker(args.worker), args.wait === true);
      case "message_worker":
        return this.message(this.worker(args.worker), String(args.text ?? ""));
      case "stop_worker":
        return this.stop(args.worker).then(() => this.status(this.worker(args.worker)));
      case "merge_worker":
        return this.merge(this.worker(args.worker));
      case "open_thread":
        return this.open(args);
      default:
        return Promise.reject(new Error(`OriCode has no tool called ${name}.`));
    }
  }

  /// Each ray's agent with its rays' models, named and with their levels as the agent lists them.
  async agents(): Promise<{ agents: unknown[] }> {
    const listed = await Promise.all(
      [...new Set(this.rays.map((ray) => ray.agent))].flatMap((id) => {
        const agent = this.seam.provider(id);
        if (!agent) return [];
        const picked = this.rays.filter((ray) => ray.agent === id).map((ray) => ray.model);
        return [
          this.seam.models(agent).then(
            (models) => ({
              id,
              name: agent.name,
              models: picked.map((id) => {
                const known = models.find((model) => model.id === id);
                return known ? { id, name: known.name, levels: known.efforts } : { id };
              }),
            }),
            () => ({ id, name: agent.name, models: picked.map((id) => ({ id })) }),
          ),
        ];
      }),
    );
    return { agents: listed };
  }

  /// The app makes the thread and sends it its first message, as the composer would, and says
  /// what it made: the tool's answer. The thread it's asked from doesn't wait on the turn.
  async open(args: Record<string, any>): Promise<unknown> {
    if (!this.opens) throw new Error("Another thread opened this one, so it can't open threads of its own.");
    const text = String(args.message ?? "").trim();
    if (!text) throw new Error("A thread needs its first message.");
    if (this.opened >= mostOpened) throw new Error(`This turn has opened ${mostOpened} threads, which is as many as one turn may.`);
    this.opened += 1;
    try {
      return await askApp("thread.open", {
        threadId: this.threadId,
        title: String(args.title ?? "").trim(),
        text,
        ...pick(args, ["agent", "model", "folder"]),
        worktree: args.worktree === true,
      });
    } catch (error) {
      // One the app refused made no thread. One it was slow over may yet, and stays counted.
      if (!(error instanceof Unanswered)) this.opened -= 1;
      throw error;
    }
  }

  async start(args: Record<string, any>): Promise<unknown> {
    const id = String(args.agent ?? "");
    const task = String(args.task ?? "").trim();
    if (!task) throw new Error("A worker needs a task.");
    const model = typeof args.model === "string" && args.model ? args.model : this.rays.find((ray) => ray.agent === id)?.model;
    const agent = this.rays.some((ray) => ray.agent === id && ray.model === model) ? this.seam.provider(id) : undefined;
    if (!agent || !model) {
      const asked = [id, args.model].filter(Boolean).join(" ") || "That";
      throw new Error(`${asked} isn't one of this thread's rays: ${this.rays.map((ray) => `${ray.agent} ${ray.model}`).join(", ")}. start_worker takes only those.`);
    }
    if ([...this.workers.values()].filter((worker) => worker.state === "running").length >= mostAtWork) {
      throw new Error(`${mostAtWork} workers are at work already. Wait for one to finish, or stop one.`);
    }
    const cli = await this.seam.cli(agent);
    const named = typeof args.effort === "string" && args.effort ? args.effort : undefined;
    const level = this.level;
    const inherited =
      named || !level
        ? undefined
        : await this.seam.models(agent).then(
            (models) => (models.find((known) => known.id === model)?.efforts.includes(level) ? level : undefined),
            () => undefined,
          );
    const workerId = `worker-${++this.count}`;
    let cwd = this.cwd;
    let isolated: Worker["isolated"] = null;
    if (args.isolated === true) {
      const root = await top(this.cwd);
      const base = (await git(root, ["rev-parse", "HEAD"]).catch(() => {
        throw new Error("An isolated worker branches from a commit, and this repository has none yet.");
      })).trim();
      // git gives the top with symlinks resolved, /private/tmp for /tmp, so the thread's place in
      // the repository is asked of git rather than worked out from the two paths.
      const inside = (await git(this.cwd, ["rev-parse", "--show-prefix"])).trim();
      const made = await addWorktree(root, `ray-${randomUUID().slice(0, 8)}`);
      cwd = join(made.path, inside);
      isolated = { path: made.path, branch: made.branch, base };
    }
    const threadId = `${this.threadId}/${workerId}`;
    const worker: Worker = {
      id: workerId,
      threadId,
      agent,
      model,
      // The level asked for, or the head's own where the worker's model has it. A worker never
      // runs with workflows on, which would send out workers of its own.
      effort: named ?? inherited ?? null,
      // The thread's mode, or the agent's first when it has no such mode.
      mode: agent.modes.includes(this.mode) ? this.mode : (agent.modes[0] ?? this.mode),
      label: task.split("\n")[0].slice(0, 80),
      cwd,
      isolated,
      session: agent.session(threadId, cli),
      sessionId: undefined,
      state: "running",
      startedAt: Date.now(),
      endedAt: null,
      step: null,
      tokens: 0,
      tools: 0,
      cost: 0,
      text: "",
      error: null,
      calls: new Map(),
      turnEdits: [],
      edits: [],
      pending: [],
      waiters: [],
    };
    this.workers.set(workerId, worker);
    tap(threadId, (name, fields) => this.heard(worker, name, fields));
    this.seam.adopt(threadId, worker.session);
    log(`worker ${workerId} for thread=${this.threadId} on ${agent.id}${isolated ? ` in ${isolated.branch}` : ""}`);
    await this.run(worker, task);
    return { worker: workerId, agent: agent.id, model: worker.model, state: worker.state, branch: isolated?.branch ?? null, folder: cwd, ...(worker.error ? { error: worker.error } : {}) };
  }

  status(worker: Worker) {
    return {
      worker: worker.id,
      agent: worker.agent.id,
      model: worker.model,
      task: worker.label,
      state: worker.state,
      step: worker.step ? [worker.step.tool, worker.step.detail].filter(Boolean).join(" · ") : null,
      seconds: Math.round(((worker.endedAt ?? Date.now()) - worker.startedAt) / 1000),
      tokens: worker.tokens,
      costUSD: worker.cost,
      branch: worker.isolated?.branch ?? null,
      ...(worker.error ? { error: worker.error } : {}),
    };
  }

  async result(worker: Worker, wait: boolean): Promise<unknown> {
    if (wait && worker.state === "running") {
      let timer: ReturnType<typeof setTimeout> | undefined;
      await new Promise<void>((done) => {
        worker.waiters.push(done);
        timer = setTimeout(done, longestWait);
      });
      clearTimeout(timer);
    }
    const files = await this.changes(worker);
    const added = files.reduce((sum, file) => sum + file.added, 0);
    const deleted = files.reduce((sum, file) => sum + file.deleted, 0);
    return {
      worker: worker.id,
      state: worker.state,
      text: worker.state === "running" ? null : worker.text,
      files,
      summary: files.length ? `${files.length} ${files.length === 1 ? "file" : "files"}, +${added} −${deleted}` : "No files changed",
      branch: worker.isolated?.branch ?? null,
      ...(worker.error ? { error: worker.error } : {}),
      ...(worker.state === "running" ? { note: "Still working. Call worker_result again to wait longer." } : {}),
    };
  }

  async message(worker: Worker, text: string): Promise<unknown> {
    if (!text.trim()) throw new Error("The message is empty.");
    if (worker.state !== "running") {
      await this.run(worker, text);
      return { worker: worker.id, state: worker.state, sent: "as its next turn" };
    }
    if (worker.agent.capabilities.steer) {
      await worker.session.send(this.params(worker, text, randomUUID()));
      return { worker: worker.id, state: worker.state, sent: "into its turn" };
    }
    worker.pending.push(text);
    return { worker: worker.id, state: worker.state, sent: "after its turn" };
  }

  async stop(workerId: string): Promise<void> {
    const worker = this.worker(workerId);
    worker.pending = [];
    if (worker.state === "running") await worker.session.interrupt();
  }

  /// Stop on the head stops its workers too.
  async stopAll(): Promise<void> {
    await Promise.all([...this.workers.keys()].map((id) => this.stop(id)));
  }

  async merge(worker: Worker): Promise<unknown> {
    if (!worker.isolated) throw new Error(`${worker.id} worked in this thread's own folder, so its edits are there already.`);
    if (worker.state === "running") throw new Error(`${worker.id} is still at work. Wait for its result, or stop it, first.`);
    await this.commit(worker);
    const { base, branch } = worker.isolated;
    const root = await top(this.cwd);
    const patch = await gitRun(root, [...diffArgs, base, branch]);
    if (!patch.trim()) return { worker: worker.id, merged: false, note: `${worker.id} changed nothing.` };
    let conflicts: string[] = [];
    try {
      await git(root, ["merge", "--squash", branch]);
    } catch (error) {
      conflicts = (await git(root, ["diff", "--name-only", "--diff-filter=U"]).catch(() => "")).split("\n").filter(Boolean);
      if (!conflicts.length) throw new Error(friendly(describe(error)));
    }
    const chunks = parsePatch(patch);
    this.tellWorker(worker, 0, chunks.map((chunk) => ({ path: join(root, chunk.path), hunks: chunk.hunks.map(({ oldStart, newStart, lines }) => ({ oldStart, newStart, lines })) })), branch);
    return {
      worker: worker.id,
      merged: true,
      branch,
      files: chunks.map((chunk) => ({ path: chunk.path, ...counted(chunk.hunks) })),
      conflicts,
      ...(conflicts.length ? { note: "git left conflict markers in these files. Settle them, and the edits stay uncommitted for the user to review." } : {}),
    };
  }

  /// Heads' detail goes out only while the app's Heads surface shows this thread.
  watch(on: boolean): void {
    this.watched = on;
    if (!on) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
    this.tell();
  }

  /// The thread is gone: its workers stop and let go of their sessions. Their worktrees stay, since
  /// they may hold work nobody has merged.
  close(): void {
    clearTimeout(this.timer);
    for (const worker of this.workers.values()) {
      worker.session.close();
      untap(worker.threadId);
      this.seam.forget(worker.threadId);
      for (const done of worker.waiters.splice(0)) done();
    }
    this.workers.clear();
    untap(this.threadId);
    heads.delete(this.threadId);
    byPath.delete(this.path);
  }

  private worker(id: unknown): Worker {
    const found = typeof id === "string" ? this.workers.get(id) : undefined;
    if (!found) throw new Error(`This thread has no worker called ${String(id)}.`);
    return found;
  }

  private params(worker: Worker, text: string, id?: string): SendParams {
    return {
      threadId: worker.threadId,
      sessionId: worker.sessionId,
      cwd: worker.cwd,
      text,
      model: worker.model ?? undefined,
      effort: (worker.effort ?? undefined) as SendParams["effort"],
      permissionMode: worker.mode as SendParams["permissionMode"],
      id,
    };
  }

  private async run(worker: Worker, text: string): Promise<void> {
    Object.assign(worker, { state: "running", text: "", error: null, endedAt: null, step: null, turnEdits: [] });
    this.tell();
    try {
      await worker.session.send(this.params(worker, text));
    } catch (error) {
      worker.error = describe(error);
      this.ended(worker, "failed");
    }
  }

  /// A worker's own events: kept for its status and result, and its asks put to the thread.
  private heard(worker: Worker, name: string, fields: Record<string, any>): boolean {
    switch (name) {
      case "turn.started":
        worker.sessionId = fields.sessionId ?? worker.sessionId;
        break;
      case "text":
        worker.text += fields.delta ?? "";
        break;
      case "tool.use": {
        const view = fields.view ?? {};
        const input = { ...fields.input, ...(view.path ? { file_path: view.path } : {}), ...pick(view, ["command", "pattern", "url", "query"]) };
        worker.tools += 1;
        worker.step = stepOf(fields.name ?? "", input, worker.cwd);
        const path = view.path ?? fields.input?.file_path ?? fields.input?.notebook_path;
        if (typeof path === "string") worker.calls.set(fields.toolUseId, { path: resolve(worker.cwd, path), patch: view.patch ?? null });
        this.soon();
        break;
      }
      case "tool.result": {
        const call = worker.calls.get(fields.toolUseId);
        const hunks = fields.patch ?? call?.patch;
        if (call && Array.isArray(hunks) && !fields.isError && !worker.isolated) worker.turnEdits.push({ path: call.path, hunks });
        break;
      }
      case "ask":
        event("ask", { ...fields, threadId: this.threadId, worker: { id: worker.id, agent: worker.agent.id, label: worker.label } });
        break;
      case "ask.cancelled":
        event("ask.cancelled", { ...fields, threadId: this.threadId });
        break;
      case "error":
        worker.error = fields.message ?? "The worker failed.";
        break;
      case "limited":
        worker.error = `${worker.agent.name} reached a usage limit.`;
        break;
      case "turn.done":
        void this.finished(worker, fields);
        break;
    }
    return true;
  }

  private async finished(worker: Worker, done: Record<string, any>): Promise<void> {
    worker.sessionId = done.sessionId ?? worker.sessionId;
    const usage = done.usage ?? {};
    worker.tokens += (usage.input ?? 0) + (usage.output ?? 0) + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
    const cost = typeof done.costUSD === "number" ? done.costUSD : 0;
    worker.cost += cost;
    worker.edits.push(...worker.turnEdits);
    this.tellWorker(worker, cost, worker.turnEdits);
    // A message sent into the turn that it didn't take up runs next, as a turn of its own.
    if ((done.waiting ?? 0) > 0) return;
    const next = worker.pending.shift();
    if (next !== undefined && done.stopReason !== "interrupted") return void this.run(worker, next);
    if (worker.isolated) await this.commit(worker).catch((error) => (worker.error = `Its edits couldn't be committed to ${worker.isolated!.branch}: ${describe(error)}`));
    this.ended(worker, done.stopReason === "interrupted" ? "stopped" : worker.error || done.stopReason === "error_during_execution" ? "failed" : "done");
  }

  private ended(worker: Worker, state: Worker["state"]): void {
    worker.state = state;
    worker.endedAt = Date.now();
    this.tell();
    for (const done of worker.waiters.splice(0)) done();
  }

  /// An isolated worker's edits go onto its branch as it finishes each turn, which is where they live.
  private async commit(worker: Worker): Promise<void> {
    const { path } = worker.isolated!;
    if (!(await git(path, ["status", "--porcelain"])).trim()) return;
    await git(path, ["add", "-A"]);
    await git(path, ["commit", "-q", "-m", worker.label]);
  }

  private async changes(worker: Worker): Promise<{ path: string; added: number; deleted: number }[]> {
    if (worker.isolated) {
      await this.commit(worker).catch(() => {});
      const out = await git(worker.isolated.path, ["diff", "--numstat", worker.isolated.base, "HEAD"]);
      return out
        .split("\n")
        .filter(Boolean)
        .map((line) => {
          const [added, deleted, ...path] = line.split("\t");
          return { path: path.join("\t"), added: Number(added) || 0, deleted: Number(deleted) || 0 };
        });
    }
    const byPath = new Map<string, { added: number; deleted: number }>();
    for (const edit of worker.edits) {
      const counts = counted(edit.hunks);
      const known = byPath.get(edit.path) ?? { added: 0, deleted: 0 };
      byPath.set(edit.path, { added: known.added + counts.added, deleted: known.deleted + counts.deleted });
    }
    return [...byPath].map(([path, counts]) => ({ path: relative(this.cwd, path), ...counts }));
  }

  /// A `worker` event for the thread, which the app keeps: what the worker's turn cost, which the
  /// thread's cost takes in, and the edits it brought into the thread's folder, which the review
  /// credits to its ray.
  private tellWorker(worker: Worker, cost: number, files: Edit[], merged?: string): void {
    if (cost === 0 && files.length === 0) return;
    event("worker", {
      threadId: this.threadId,
      worker: worker.id,
      agent: worker.agent.id,
      model: worker.model,
      label: worker.label,
      costUSD: cost,
      files,
      ...(merged ? { merged } : {}),
    });
  }

  /// Detail changed: one send in 250ms, and only while the surface watches.
  private soon(): void {
    if (!this.watched || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      this.tell();
    }, 250);
  }

  /// The thread's whole list: its own heads, then each worker at work, with the agent it runs on.
  private tell(): void {
    const working = [...this.workers.values()].filter((worker) => worker.state === "running");
    const listed = [
      ...this.own,
      ...working.map((worker) => ({
        id: worker.id,
        kind: "agent",
        toolUseId: null,
        label: worker.label,
        type: null,
        background: true,
        depth: 1,
        startedAt: worker.startedAt,
        worker: true,
        agent: worker.agent.id,
        model: worker.model,
        ...(this.watched ? { tokens: worker.tokens || null, tools: worker.tools, step: worker.step, cost: worker.cost } : {}),
      })),
    ];
    const told = JSON.stringify(listed);
    if (told === this.told) return;
    this.told = told;
    emit({ event: "heads", threadId: this.threadId, heads: listed });
  }
}

function counted(hunks: { lines: string[] }[]): { added: number; deleted: number } {
  const lines = hunks.flatMap((hunk) => hunk.lines);
  return { added: lines.filter((line) => line.startsWith("+")).length, deleted: lines.filter((line) => line.startsWith("-")).length };
}

function pick(from: Record<string, unknown>, keys: string[]): Record<string, unknown> {
  return Object.fromEntries(keys.filter((key) => typeof from[key] === "string").map((key) => [key, from[key]]));
}
