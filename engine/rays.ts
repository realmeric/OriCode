import { randomUUID } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import { join, relative, resolve } from "node:path";
import { addWorktree, friendly, git } from "./git.ts";
import { stepOf, type Step } from "./heads.ts";
import type { Model } from "./models.ts";
import type { Provider, SendParams, Session } from "./provider.ts";
import type { Usage } from "./usage.ts";
import { diffArgs, gitRun, parsePatch, top } from "./review.ts";
import { describe } from "./thread.ts";
import { askApp, listThreads, longestTurnWait, messageThread, mostSuggested, openThread, readThread, stopThread, suggestThread, Unanswered, waitThread } from "./threads.ts";
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
// the tools every thread on such an agent has for the user's threads (threads.ts).

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
  /// The plan's windows, from an agent whose CLI says them, or undefined.
  usage(agent: Provider): Promise<Usage | undefined>;
  /// The head's own session takes another model or level: true when its running turn took it.
  retune(threadId: string, model: string | undefined, effort: string | undefined): Promise<boolean>;
  /// Stops the head's own turn, which a spent budget does.
  interrupt(threadId: string): Promise<void>;
  /// What the head's running turn has spent so far, where its CLI can say.
  inFlight(threadId: string): Promise<number | undefined>;
};

/// What a head that chooses works from, from Settings › Agents through the thread's send: the
/// models the model menu shows on every ready agent, less the ones heads keep off, the agents
/// whose models the app hasn't read yet, the rays the user picked anyway, the budget and what
/// the thread has spent, and the head's own agent and model.
export type Choice = {
  picked: Ray[];
  unread: string[];
  keepOff: string[];
  budget: number | null;
  spent: number;
  agent: string;
  model: string | undefined;
};

type Hunk = { oldStart: number; newStart: number; lines: string[] };

type Edit = { path: string; hunks: Hunk[] };

type Worker = {
  id: string;
  /// Its thread's key in the app, which outlives this engine: a later engine counts its workers
  /// from one again.
  key: string;
  /// The session's own thread id, which its events carry and the app never sees.
  threadId: string;
  agent: Provider;
  model: string | null;
  effort: string | null;
  mode: string;
  label: string;
  /// What it may spend at most, held out of the thread's budget while it works; null with none.
  cap: number | null;
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
/// A worker's own events its thread in the app keeps. Its asks go to the head's thread, and its
/// session's other news, its limits, its effort and its heads, belong to no transcript.
const shown = new Set(["turn.started", "text", "thinking", "tool.use", "tool.result", "tool.ended", "note", "error", "limited", "compacted", "retrying", "turn.done"]);

/// The tool a head that chooses moves itself with.
const changeMyModel = {
  name: "change_my_model",
  description:
    "Move yourself to another model of your own agent's, or another effort level, for the work in front of you: up when a part needs more thought than you're on, back down once it's done. The user reads your reason as one line of the transcript. On Claude Code it takes effect from your next request; on another agent, from your next turn.",
  inputSchema: {
    type: "object",
    properties: {
      model: { type: "string", description: "One of your own agent's models from list_agents. Your current model when left out." },
      effort: { type: "string", description: "One of that model's levels from list_agents. Your current level when left out and the model has it." },
      reason: { type: "string", description: "Why, in one line the user reads, such as \"The schema change touches every query, so high\"." },
    },
    required: ["reason"],
  },
};

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

/// start_worker as a head that chooses has it: it says why it picked the model and the level, which
/// the user reads in ⌘I beside the worker.
const startChosen = (() => {
  const start = tools.find((tool) => tool.name === "start_worker")!;
  return {
    ...start,
    description: start.description.replace("on one of this thread's rays", "on any model list_agents gives"),
    inputSchema: {
      ...start.inputSchema,
      properties: {
        ...start.inputSchema.properties,
        agent: { type: "string", description: "An agent from list_agents, such as codex or claude." },
        model: { type: "string", description: "One of that agent's models from list_agents." },
        reason: { type: "string", description: "Why this model at this level for this part, in one line the user reads, such as \"Mechanical rename, so Luna at low\"." },
      },
      required: ["agent", "model", "task", "reason"],
    },
  };
})();

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

/// What a head that chooses is told, in place of `brief`: that the models and levels are its to
/// pick, its own included, which user's picks it should lean to, and the budget. Nothing in it
/// changes from one send to the next unless Settings does, since the CLI opens again when it does.
export function choosing(picked: Ray[], budget: number | null): string {
  return [
    "You run this thread: you choose which models do its work and how hard each one thinks, your own model and level included. The user doesn't pick them; they watch and talk to you. " +
      "list_agents gives every model you may use, on each agent that's ready, with its effort levels and each agent's plan windows where its CLI says them. " +
      "When a task has parts that don't depend on each other, don't start on them yourself: first give each part a worker with start_worker, on the model and at the level that part needs, with a one-line reason the user reads, then bring their work together with worker_result, however small the parts are. " +
      "A quick model at low effort does something mechanical; a stronger model or a higher level does something hard. Spread the parts across agents where more than one is ready: each agent's plan has windows of its own, so a part on Codex leaves Claude's untouched. " +
      "Keep for yourself what needs the whole picture. Workers that edit files work isolated, and you merge what you keep with merge_worker.",
    "Your own model and level are yours to change with change_my_model, with a one-line reason the user reads: move up before a part that needs more thought than you're on, and back down once it's done. Starting low and moving up when the work asks for it is the point.",
    picked.length ? `The user picked these models for this thread, so lean to them: ${picked.map((ray) => `${ray.agent} ${ray.model}`).join(", ")}.` : "",
    budget !== null
      ? `This thread may spend ${usd(budget)} in all, you and your workers together, as the agents report it; list_agents says what's left. OriCode stops everything at that line, starts no worker on an agent whose spending it can't count, and refuses open_thread and message_thread, since another thread's spending isn't this one's.`
      : "",
    "These tools are the oricode MCP server's; if they aren't among yours yet, load them with tool_search.",
  ]
    .filter(Boolean)
    .join(" ");
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
  /// What the head chooses from, null while it works on the rays picked for it.
  private choice: Choice | null = null;
  /// The thread's spend as counted: what the app said with the send, and each cost since.
  private spent = 0;
  /// The budget was reached and everything stopped, which a send under it again clears.
  private stopped = false;
  /// The most one worker's turn has cost in this thread, which what's left must cover for another
  /// to start.
  private dearest = 0;
  /// The budget check running, and the one waiting to run after it.
  private checking: Promise<unknown> = Promise.resolve();
  private queued: Promise<boolean> | undefined;
  /// How many threads its turn has suggested.
  private suggested = 0;

  constructor(threadId: string, seam: Seam, port: number, watched: boolean) {
    this.threadId = threadId;
    this.seam = seam;
    this.watched = watched;
    this.path = `/${randomUUID()}`;
    this.url = `http://127.0.0.1:${port}${this.path}`;
    // The thread's own `heads` go out with its workers after them.
    tap(threadId, (name, fields) => {
      if (name === "turn.started") this.suggested = 0;
      if (name === "turn.done") this.tally(typeof fields.costUSD === "number" ? fields.costUSD : 0);
      if (name !== "heads") return false;
      this.own = (fields.heads as unknown[]) ?? [];
      this.tell();
      return true;
    });
  }

  /// What the thread's latest send says: where it works, in which mode, at what level, and its
  /// rays, none when it has none left, with what the head is told of them: `brief`, or what
  /// workflows on tell it.
  update(cwd: string, mode: string, rays: Ray[], instructions = brief(rays), level?: string, choice?: Choice): void {
    this.cwd = cwd;
    this.mode = mode;
    this.rays = choice ? rays.filter((ray) => !choice.keepOff.includes(`${ray.agent}/${ray.model}`)) : rays;
    this.instructions = instructions;
    this.level = level;
    this.choice = choice ?? null;
    if (choice) {
      this.spent = choice.spent;
      if (choice.budget === null || this.spent < choice.budget) this.stopped = false;
    }
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
        return { result: { tools: [...(this.choice ? tools.map((tool) => (tool.name === "start_worker" ? startChosen : tool)) : this.rays.length ? tools : []), ...(this.choice ? [changeMyModel] : []), openThread, messageThread, waitThread, stopThread, suggestThread, listThreads, readThread] } };
      case "tools/call":
        try {
          if (this.choice?.budget != null && (await this.over())) throw new Error(`This thread has spent its ${usd(this.choice.budget)} budget, so OriCode stopped it and its workers. Say so in one line and stop.`);
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
      case "change_my_model":
        return this.retune(args);
      case "open_thread":
        return this.open(args);
      case "message_thread":
        this.uncounted("message_thread");
        return this.act("thread.message", args, { text: required(args.text, "A message needs its text.") });
      case "wait_thread":
        return this.wait(args);
      case "stop_thread":
        return this.act("thread.stop", args, {});
      case "suggest_thread":
        return this.suggest(args);
      case "list_threads":
        return this.read("threads.list", pick(args, ["edited"]));
      case "read_thread":
        if (!String(args.thread ?? "").trim()) return Promise.reject(new Error("read_thread needs a thread's id, which list_threads gives."));
        return this.read("thread.read", { thread: String(args.thread).trim(), ...(Number.isSafeInteger(args.before) && args.before >= 0 ? { before: args.before } : {}) });
      default:
        return Promise.reject(new Error(`OriCode has no tool called ${name}.`));
    }
  }

  /// Each ray's agent with its rays' models, named and with their levels as the agent lists them.
  /// A head that chooses is told every model it may use instead, and where it stands.
  async agents(): Promise<unknown> {
    if (this.choice) return this.choices(this.choice);
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

  /// Every model a head that chooses may use, by agent: its levels and default, whether the user
  /// picked it as a ray, each agent's plan windows where its CLI says them and whether OriCode can
  /// count what it spends; then the head's own model and level, and the thread's budget.
  async choices(choice: Choice): Promise<unknown> {
    const offered = await this.offered();
    const ids = [...new Set([choice.agent, ...offered.map((ray) => ray.agent)])];
    const agents = await Promise.all(
      ids.flatMap((id) => {
        const agent = this.seam.provider(id);
        if (!agent) return [];
        const mine = offered.filter((ray) => ray.agent === id).map((ray) => ray.model);
        return [
          Promise.all([this.seam.models(agent).catch(() => [] as Model[]), within(this.seam.usage(agent).catch(() => undefined), 5_000)]).then(([models, usage]) => ({
            id,
            name: agent.name,
            ...(usage?.windows.length ? { planWindows: usage.windows.map((window) => ({ window: window.label, used: window.used === null ? null : `${Math.round(window.used * 100)}%`, resetsAt: window.resetsAt })) } : {}),
            ...(choice.budget !== null ? { spendCounted: agent.costs === true } : {}),
            models: mine.map((model) => {
              const known = models.find((listed) => listed.id === model);
              const picked = choice.picked.some((ray) => ray.agent === id && ray.model === model);
              return {
                id: model,
                ...(known ? { name: known.name, ...(known.description ? { description: known.description } : {}), levels: known.efforts, defaultLevel: known.defaultEffort } : {}),
                ...(picked ? { pickedByUser: true } : {}),
              };
            }),
          })),
        ];
      }),
    );
    return {
      you: { agent: choice.agent, model: choice.model ?? "default", level: this.level ?? "the model's default" },
      ...(choice.budget !== null ? { budget: { usd: choice.budget, spent: round(this.spent), left: round(Math.max(0, choice.budget - this.spent)) } } : {}),
      agents,
    };
  }

  /// The models a head that chooses may use: the app's, and for an agent whose models it hasn't
  /// read yet, the ones the model menu shows of it out of the box, its whole list when that's five
  /// or fewer and else its first. None of them one heads keep off.
  private async offered(): Promise<Ray[]> {
    const choice = this.choice;
    if (!choice) return this.rays;
    const more = await Promise.all(
      choice.unread.map(async (id) => {
        const agent = this.seam.provider(id);
        const models = agent ? await this.seam.models(agent).catch(() => [] as Model[]) : [];
        const shown = models.length <= 5 ? models : models.slice(0, 1);
        return shown.filter((model) => !model.forbidden && !model.needs).map((model) => ({ agent: id, model: model.id }));
      }),
    );
    return [...this.rays, ...more.flat()].filter((ray) => !choice.keepOff.includes(`${ray.agent}/${ray.model}`));
  }

  /// change_my_model: the head's own model or level, on its own agent, with the reason the
  /// transcript shows. The app takes them as the thread's, so its next send carries them.
  async retune(args: Record<string, any>): Promise<unknown> {
    const choice = this.choice;
    if (!choice) throw new Error("Only a head that chooses its models moves itself, and the user has Heads choose off.");
    const why = required(args.reason, "Say why in `reason`, one line the user reads.");
    const agent = this.seam.provider(choice.agent);
    if (!agent) throw new Error("This thread's agent isn't one OriCode can move.");
    const current = choice.model ?? "default";
    const asked = typeof args.model === "string" && args.model.trim() ? args.model.trim() : undefined;
    const mine = (await this.offered()).filter((ray) => ray.agent === agent.id).map((ray) => ray.model);
    if (asked && asked !== current && !mine.includes(asked)) {
      throw new Error(`${asked} isn't one of the ${agent.name} models you may move to: ${mine.join(", ") || "there are none"}.`);
    }
    const target = asked ?? current;
    const known = (await this.seam.models(agent).catch(() => [] as Model[])).find((model) => model.id === target);
    const levels = known?.efforts ?? [];
    const named = typeof args.effort === "string" && args.effort.trim() ? args.effort.trim() : undefined;
    if (named && levels.length && !levels.includes(named)) throw new Error(`${known?.name ?? target} has no ${named} level. Its levels: ${levels.join(", ")}.`);
    if (named && !levels.length) throw new Error(`${known?.name ?? target} has no effort levels.`);
    const level = named ?? (this.level && levels.includes(this.level) ? this.level : undefined);
    if (target === current && level === this.level) throw new Error(`You're on ${known?.name ?? target}${level ? ` at ${level}` : ""} already.`);
    const live = await this.seam.retune(this.threadId, target === current ? undefined : target, level === this.level ? undefined : level);
    choice.model = target;
    this.level = level;
    event("head.changed", { threadId: this.threadId, agent: agent.id, model: target, name: known?.name ?? target, modelChanged: target !== current, effort: level ?? null, reason: why, live });
    return { model: target, level: level ?? "the model's default", takesEffect: live ? "from your next request" : "from your next turn" };
  }

  /// A cost the thread's head or one of its workers reported, which may take it to its budget.
  private tally(cost: number): void {
    this.spent += cost;
    if (this.choice?.budget != null) void this.over();
  }

  /// What the thread has spent, the running turns of the head and its workers included where
  /// their CLIs can say. What the turns that ended cost is read first: a turn ending meanwhile is
  /// then counted in neither, never in both, and its end checks again.
  private async total(): Promise<number> {
    const ended = this.spent;
    const running = [...this.workers.values()].filter((worker) => worker.state === "running");
    const turns = await Promise.all([this.seam.inFlight(this.threadId), ...running.map((worker) => worker.session.spentThisTurn?.())]);
    return turns.reduce<number>((sum, turn) => sum + (turn ?? 0), ended);
  }

  /// Whether the thread is at its budget, counting the running turns. Asked before each tool any
  /// of its Claude Code sessions calls, so none sends another request past the line, and at each
  /// OriCode tool call and each turn's end. One check runs at a time, so the one that crosses the
  /// line stops everything, once, and says why, and every check after it answers true.
  over(): Promise<boolean> {
    if ((this.choice?.budget ?? null) === null) return Promise.resolve(false);
    if (this.stopped) return Promise.resolve(true);
    this.queued ??= this.checking.then(() => {
      this.queued = undefined;
      return this.check();
    });
    this.checking = this.queued.catch(() => false);
    return this.queued;
  }

  private async check(): Promise<boolean> {
    const budget = this.choice?.budget ?? null;
    if (budget === null) return false;
    if (this.stopped) return true;
    const total = await this.total();
    if (total < budget) return false;
    this.stopped = true;
    log(`budget thread=${this.threadId} spent=${total.toFixed(4)} of ${budget}`);
    event("note", { threadId: this.threadId, text: `This thread has spent its ${usd(budget)} budget, so OriCode stopped it and its workers.` });
    // Not waited on: the session whose tool asked is waiting on this answer.
    Promise.all([this.stopAll(), this.seam.interrupt(this.threadId)]).catch((error) => log(`budget stop thread=${this.threadId}: ${describe(error)}`));
    return true;
  }

  /// Another thread's turns are its own, outside this thread's budget, so under one a head that
  /// chooses neither opens a thread nor sends one a message.
  private uncounted(tool: string): void {
    const budget = this.choice?.budget ?? null;
    if (budget === null) return;
    throw new Error(`This thread has a ${usd(budget)} budget, and what another thread spends isn't counted in it, so ${tool} is off while it's set. Give the part to a worker with start_worker instead.`);
  }

  /// What a worker on the agent may spend: half of what the thread has left, the head's running
  /// turn counted, less what the workers at work hold, so workers started together never hold more
  /// than there is; or why it can't start, under a budget. What's left must cover the dearest worker
  /// the thread has run, or the next would likely end past it.
  private async allowance(agent: Provider): Promise<number | null> {
    const budget = this.choice?.budget ?? null;
    if (budget === null) return null;
    if (agent.costs !== true) throw new Error(`${agent.name} doesn't say what it spends, so with a budget set OriCode can't start a worker on it. Pick a model whose agent has spendCounted in list_agents.`);
    const total = await this.total();
    const held = [...this.workers.values()].filter((worker) => worker.state === "running").reduce((sum, worker) => sum + (worker.cap ?? 0), 0);
    const left = budget - total - held;
    if (left <= this.dearest) {
      throw new Error(
        `This thread has ${usd(Math.max(0, round(budget - total)))} left of its ${usd(budget)} budget${held > 0 ? `, ${usd(round(held))} of it held by the workers at work` : ""}, ` +
          `${this.dearest > 0 ? `less than the ${usd(round(this.dearest))} a worker has cost here, ` : ""}so no worker can start. Finish with what you have.`,
      );
    }
    return round(left / 2);
  }

  /// The app makes the thread and sends it its first message, as the composer would, and says
  /// what it made: the tool's answer. The thread it's asked from doesn't wait on the turn.
  async open(args: Record<string, any>): Promise<unknown> {
    this.uncounted("open_thread");
    const text = required(args.message, "A thread needs its first message.");
    const why = required(args.reason, "Say why in `reason`, one line the user reads.");
    return await askApp("thread.open", {
      threadId: this.threadId,
      title: String(args.title ?? "").trim(),
      text,
      reason: why,
      ...pick(args, ["agent", "model", "folder"]),
      worktree: args.worktree === true,
    });
  }

  /// A message to another thread, or a stop: the app does it as the user would, and says so in
  /// both threads with the reason.
  async act(name: string, args: Record<string, any>, fields: Record<string, unknown>): Promise<unknown> {
    const other = required(args.thread, "Name the thread by its id, which list_threads gives.");
    const why = required(args.reason, "Say why in `reason`, one line the user reads.");
    return await askApp(name, { threadId: this.threadId, thread: other, ...fields, reason: why });
  }

  /// The app answers when the thread's turn ends, or with its state once the wait is up; nothing
  /// polls. The engine gives it a little longer than that, so the app's answer is the one read.
  async wait(args: Record<string, any>): Promise<unknown> {
    const other = required(args.thread, "Name the thread by its id, which list_threads gives.");
    try {
      return await askApp("thread.wait", { threadId: this.threadId, thread: other }, longestTurnWait + 30_000);
    } catch (error) {
      if (error instanceof Unanswered) throw new Error("OriCode didn't say how that thread is doing. Nothing was changed, so call wait_thread again.");
      throw error;
    }
  }

  /// Nothing is made: the app shows the suggestion under the reply, and the user's click makes
  /// the thread, with the prompt in the composer for them to send or not.
  async suggest(args: Record<string, any>): Promise<unknown> {
    const title = String(args.title ?? "").trim();
    const text = String(args.prompt ?? "").trim();
    if (!title) throw new Error("A suggestion needs a title for its button.");
    if (!text) throw new Error("A suggestion needs the prompt its thread would start on.");
    if (this.suggested >= mostSuggested) throw new Error(`This turn has suggested ${mostSuggested} threads, which is as many as one turn may.`);
    this.suggested += 1;
    emit({ event: "thread.suggested", threadId: this.threadId, title, text });
    return { shown: title, started: false };
  }

  /// The app answers from the events it has stored, the engine keeping none. Nothing is made or
  /// sent, so an answer that came late lost nothing.
  async read(name: string, fields: Record<string, unknown>): Promise<unknown> {
    try {
      return await askApp(name, { threadId: this.threadId, ...fields });
    } catch (error) {
      if (error instanceof Unanswered) throw new Error("OriCode took too long to read that. Nothing was started or changed, so ask again.");
      throw error;
    }
  }

  async start(args: Record<string, any>): Promise<unknown> {
    const id = String(args.agent ?? "");
    const task = String(args.task ?? "").trim();
    if (!task) throw new Error("A worker needs a task.");
    // A head that chooses names the model it chose; the first of the agent's would be one it never picked.
    if (this.choice) required(args.model, "Name the model in `model`, one of that agent's from list_agents.");
    const why = this.choice ? required(args.reason, "Say why this model at this level in `reason`, one line the user reads.") : undefined;
    const offered = await this.offered();
    const model = typeof args.model === "string" && args.model ? args.model : offered.find((ray) => ray.agent === id)?.model;
    const agent = offered.some((ray) => ray.agent === id && ray.model === model) ? this.seam.provider(id) : undefined;
    if (!agent || !model) {
      const asked = [id, args.model].filter(Boolean).join(" ") || "That";
      const named = offered.map((ray) => `${ray.agent} ${ray.model}`).join(", ");
      throw new Error(this.choice ? `${asked} isn't one of the models you may use: ${named}. list_agents says each one's levels.` : `${asked} isn't one of this thread's rays: ${named}. start_worker takes only those.`);
    }
    if ([...this.workers.values()].filter((worker) => worker.state === "running").length >= mostAtWork) {
      throw new Error(`${mostAtWork} workers are at work already. Wait for one to finish, or stop one.`);
    }
    const cap = await this.allowance(agent);
    const cli = await this.seam.cli(agent);
    const named = typeof args.effort === "string" && args.effort ? args.effort : undefined;
    const level = this.level;
    // The agent's list is asked only when there is a level to take from it or a choice to name.
    const known = why || (!named && level) ? (await this.seam.models(agent).catch(() => [] as Model[])).find((listed) => listed.id === model) : undefined;
    const inherited = !named && level && known?.efforts.includes(level) ? level : undefined;
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
      key: randomUUID(),
      threadId,
      agent,
      model,
      // The level asked for, or the head's own where the worker's model has it. A worker never
      // runs with workflows on, which would send out workers of its own.
      effort: named ?? inherited ?? null,
      // The thread's mode, or the agent's first when it has no such mode.
      mode: agent.modes.includes(this.mode) ? this.mode : (agent.modes[0] ?? this.mode),
      label: task.split("\n")[0].slice(0, 80),
      cap,
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
    // The head's choice, which the app keeps for ⌘I: the model, the level and why.
    if (why) event("head.chose", { threadId: this.threadId, worker: workerId, agent: agent.id, model, name: known?.name ?? model, effort: worker.effort, label: worker.label, reason: why });
    tap(threadId, (name, fields) => this.heard(worker, name, fields));
    this.seam.adopt(threadId, worker.session);
    log(`worker ${workerId} for thread=${this.threadId} on ${agent.id}${isolated ? ` in ${isolated.branch}` : ""}`);
    await this.run(worker, task);
    return { worker: workerId, agent: agent.id, model: worker.model, effort: worker.effort, ...(cap !== null ? { maySpendUSD: cap } : {}), state: worker.state, branch: isolated?.branch ?? null, folder: cwd, ...(worker.error ? { error: worker.error } : {}) };
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
      worker.cap = await this.allowance(worker.agent);
      await this.run(worker, text);
      return { worker: worker.id, state: worker.state, sent: "as its next turn" };
    }
    if (worker.agent.capabilities.steer) {
      await worker.session.send(this.params(worker, text, randomUUID()));
      this.show(worker, "user", { text, midTurn: true });
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
      if (worker.state === "running") this.ended(worker, "stopped");
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
      // A resumed session's first result carries the turns before it, which are counted already.
      costSoFar: worker.cost,
      ...(worker.cap !== null ? { spendCap: { limit: worker.cap, left: worker.cap, over: () => this.over() } } : {}),
    };
  }

  private async run(worker: Worker, text: string): Promise<void> {
    Object.assign(worker, { state: "running", text: "", error: null, endedAt: null, step: null, turnEdits: [] });
    this.tell();
    this.tellThread(worker);
    this.show(worker, "user", { text });
    try {
      await worker.session.send(this.params(worker, text));
    } catch (error) {
      worker.error = describe(error);
      // Its thread took the message as a turn begun, which only a turn.done ends.
      this.show(worker, "error", { message: worker.error });
      this.show(worker, "turn.done", { stopReason: "error_during_execution" });
      this.ended(worker, "failed");
    }
  }

  /// A worker's own events: kept for its status and result, and its asks put to the thread.
  private heard(worker: Worker, name: string, fields: Record<string, any>): boolean {
    if (shown.has(name)) this.show(worker, name, fields);
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
        event("ask", { ...fields, threadId: this.threadId, agentId: worker.key, worker: { id: worker.id, agent: worker.agent.id, label: worker.label } });
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
    if (worker.cap !== null) worker.cap = Math.max(0, worker.cap - cost);
    this.dearest = Math.max(this.dearest, cost);
    this.tally(cost);
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
    this.tellThread(worker);
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

  /// The worker's thread under the head's in the app: made as it starts, and told how each of its
  /// turns ended with what it said last, or why it failed.
  private tellThread(worker: Worker): void {
    emit({
      event: "agent.thread",
      threadId: this.threadId,
      agentId: worker.key,
      task: worker.id,
      kind: "worker",
      label: worker.label,
      state: worker.state,
      agent: worker.agent.id,
      model: worker.model,
      ...(worker.state === "running" ? {} : { result: worker.error ?? worker.text }),
    });
  }

  /// One of the worker's events, for its thread in the app, as a thread's own. Its cost is the
  /// head's already, through `worker`, and its session is its own, which the app never resumes.
  private show(worker: Worker, name: string, fields: Record<string, any>): void {
    const { threadId: _, sessionId: __, costUSD: ___, ...said } = fields;
    emit({ event: "worker.said", threadId: this.threadId, agentId: worker.key, said: { ...said, event: name } });
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

/// Dollars as a person reads them: $1, $0.50.
export function usd(amount: number): string {
  return Number.isInteger(amount) ? `$${amount}` : `$${amount.toFixed(2)}`;
}

function round(amount: number): number {
  return Math.round(amount * 10_000) / 10_000;
}

/// The promise's answer, or undefined once it has taken longer than `ms`.
function within<T>(promise: Promise<T>, ms: number): Promise<T | undefined> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const late = new Promise<undefined>((done) => {
    timer = setTimeout(() => done(undefined), ms);
  });
  return Promise.race([promise, late]).finally(() => clearTimeout(timer));
}

/// A tool's argument as trimmed text, or the tool's error when there is none.
function required(value: unknown, why: string): string {
  const text = typeof value === "string" ? value.trim() : "";
  if (!text) throw new Error(why);
  return text;
}
