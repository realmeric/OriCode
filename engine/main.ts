import { createInterface } from "node:readline";
import type { PermissionMode } from "@anthropic-ai/claude-agent-sdk";
import { agent, change, check, isOn, lookUp, registry, turnedOn, turnOn, unasked, type Setting } from "./agents.ts";
import { antigravity } from "./antigravity-provider.ts";
import { claude } from "./claude.ts";
import { deepseek, meta, openrouter, zai } from "./claude-compatible.ts";
import { codex } from "./codex-provider.ts";
import { commandcode } from "./commandcode-provider.ts";
import { copilot } from "./copilot.ts";
import { cursor } from "./cursor.ts";
import { devin } from "./devin.ts";
import { grok } from "./grok.ts";
import { opencode } from "./opencode.ts";
import { releaseIdle, type Shown } from "./idle.ts";
import { pi } from "./pi-provider.ts";
import { handed } from "./handover.ts";
import { brief, rayOf, raysFor, raysOf, type Seam } from "./rays.ts";
import { appReplied, openedByAnother, opening, suggesting } from "./threads.ts";
import { brief as fanning, claudeLead, lead, levels, onRays } from "./ultracode.ts";
import type { Model } from "./models.ts";
import { answer, brevity, scratch, type Answer, type Availability, type Capabilities, type Provider, type SendParams, type Session } from "./provider.ts";
import { describe } from "./thread.ts";
import { addWorktree, branch, branches, create, previous, pull, push, remote, removeWorktree, switchTo, worktreeLoss } from "./git.ts";
import { commentsIn, reviewLead, applyPatch, commitAll, commitReviewed, restore, unrestore, workingDiff, type IndexEntry } from "./review.ts";
import { addMcpServer, mcpServers, removeMcpServer } from "./mcp.ts";
import { failureLog, mergePull, openPull, pullOf } from "./pr.ts";
import { sessionEvents, sessionsIn } from "./sessions.ts";
import { listFiles, readProjectFile, writeProjectFile } from "./files.ts";
import { run, stopAll } from "./shell.ts";
import { version } from "./version.ts";
import { emit, event, log, type Request } from "./wire.ts";

// The compile cache is for this engine's own modules; the CLIs and servers it starts don't inherit it.
delete process.env.NODE_COMPILE_CACHE;

const providers = new Map<string, Provider>([
  [claude.id, claude],
  [codex.id, codex],
  [zai.id, zai],
  [deepseek.id, deepseek],
  [openrouter.id, openrouter],
  [meta.id, meta],
  [opencode.id, opencode],
  [pi.id, pi],
  [commandcode.id, commandcode],
  [antigravity.id, antigravity],
  [cursor.id, cursor],
  [copilot.id, copilot],
  [grok.id, grok],
  [devin.id, devin],
]);
const sessions = new Map<string, Session>();
/// The agent each thread's session runs, so a send for another agent lets the old one go.
const agentOf = new WeakMap<Session, string>();
/// Agents whose models were read while they could run; hello's list for one signed out is a fallback.
const listed = new Set<string>();
/// Each agent's models as it last listed them, with OriCode's Ultracode where it's on Rays, kept
/// until Settings › Agents changes the agent or a check finds its login made or gone: a check
/// and the menu after it, Rays and a send at Ultracode all read one listing, which for OpenCode or
/// Cursor is a second or more and several hundred MB.
const lists = new Map<string, Promise<Model[]>>();
/// Threads whose Heads surface is open, which a thread made after the surface opened starts with.
const watched = new Set<string>();

/// The agent a request names, Claude Code when it names none.
function provider(id: string | undefined): Provider {
  const found = providers.get(id ?? "claude");
  if (!found) throw new Error(`Unknown provider ${id}`);
  return found;
}

/// The agent's CLI, found without asking it anything, so a send never waits on a login check.
async function cli(agent: Provider): Promise<string> {
  const path = await agent.found();
  if (!path) throw new Error(agent.missing);
  return path;
}

function session(threadId: string, agent: Provider, path: string): Session {
  let found = sessions.get(threadId);
  if (!found) {
    found = agent.session(threadId, path);
    agentOf.set(found, agent.id);
    found.watchHeads(watched.has(threadId));
    kept(threadId, found);
  }
  return found;
}

/// A thread that changed agent: the old agent's session ends, and its workers with it, so the send
/// that follows starts a session of the new agent's own. The thread's heads watch stays.
function leave(threadId: string, agent?: Provider): void {
  const found = sessions.get(threadId);
  if (!found || (agent && agentOf.get(found) === agent.id)) return;
  raysOf(threadId)?.close();
  found.close();
  sessions.delete(threadId);
}

/// A thread's session or a worker's, let go when idle like every other.
function kept(threadId: string, found: Session): void {
  // After the turn.done it's called from, and outside the CLI's message loop it would close.
  found.onIdle = () => setImmediate(letGo);
  sessions.set(threadId, found);
}

/// The side questions being answered, by thread, for `side.stop`.
const asides = new Map<string, AbortController>();

const seam: Seam = {
  provider: (id) => providers.get(id),
  cli,
  models: listOf,
  adopt: kept,
  forget: (threadId) => sessions.delete(threadId),
};

/// The URL of the thread's tools and what it's told of them, on an agent that takes them: a head's
/// worker tools when the thread has rays, or runs OriCode's workflows, on its own model when it
/// has no rays; open_thread unless another thread opened this one; and suggest_thread, which every
/// such thread has and is told when to call. A thread with no rays left keeps the workers it has, and can't start more.
async function threadTools(params: SendParams & { rays?: string[]; opened?: boolean }, agent: Provider, fans?: Model): Promise<Pick<SendParams, "tools" | "instructions">> {
  const takes = agent.capabilities.workers === true;
  const picked = takes ? (params.rays ?? []).map(rayOf).filter((ray) => providers.has(ray.agent)) : [];
  const rays = fans && !picked.length ? [{ agent: agent.id, model: fans.id }] : picked;
  const opens = takes && !params.opened;
  const instructions = [rays.length ? (fans ? fanning(rays) : brief(rays)) : undefined, opens ? opening : takes ? openedByAnother : undefined, takes ? suggesting : undefined].filter(Boolean).join("\n\n") || undefined;
  const head = takes ? await raysFor(params.threadId, seam, watched.has(params.threadId)) : raysOf(params.threadId);
  head?.update(params.cwd, params.permissionMode, rays, instructions, params.effort, opens);
  return takes && head ? { tools: head.url, instructions } : { instructions };
}

/// An agent's models as the app gets them, from its CLI the first time and kept after, with
/// OriCode's Ultracode where it's on Rays; Claude Code's Ultracode is always its own.
function listOf(agent: Provider, path?: string): Promise<Model[]> {
  let found = lists.get(agent.id);
  if (!found) {
    found = (async () => {
      const models = agent.listModels ? await agent.listModels(path ?? (await cli(agent))) : await agent.models(await agent.availability(), () => {});
      return agent.id === claude.id ? models : onRays(agent, models);
    })();
    // A failure is asked again next time rather than kept.
    found.catch(() => lists.delete(agent.id));
    lists.set(agent.id, found);
  }
  return found;
}

/// The model a send with workflows on runs, from the agent's list: one that can run them, on an
/// agent that can be a head other than Claude Code, whose workflows are its own.
async function workflowsModel(agent: Provider, path: string, id: string | undefined): Promise<Model | undefined> {
  if (agent.id === claude.id || !agent.capabilities.workers || !agent.listModels) return undefined;
  const models = await listOf(agent, path);
  const model = id ? models.find((model) => model.id === id) : models[0];
  return model?.ultra ? model : undefined;
}

/// An agent's models, read once a check finds it signed in after hello didn't, as `models`
/// events: the list, unless its defaults came with it, and then the defaults. Claude Code's go
/// unnamed, as they always have, and come with their defaults.
async function listAfterLogin(agent: Provider, found: Availability): Promise<void> {
  if (agent.id !== claude.id) {
    event("models", { models: await listOf(agent, found.cli ?? undefined), settingsEffort: null, ultraKnown: false, provider: agent.id });
    return;
  }
  let told = false;
  const listedFirst = Promise.withResolvers<void>();
  const models = await agent.models(found, (fields) => {
    told = true;
    void listedFirst.promise.then(() => event("models", fields));
  });
  if (!told) event("models", { models, settingsEffort: null, ultraKnown: false });
  listedFirst.resolve();
}

/// What an agent with no session in the engine yet can do: nothing, so the app offers nothing.
const unwired: Capabilities = {
  steer: false,
  resume: false,
  modeLive: false,
  attachments: false,
  heads: false,
  stopTask: false,
  limits: false,
  usage: false,
  commands: false,
  compact: false,
  commitMessage: false,
  handoff: null,
};

/// An agent as hello gives it to the app: whether it can run here, and what a thread on it can do.
function described(id: string, found: Availability) {
  const wired = providers.get(id);
  const entry = agent(id)!;
  return {
    id,
    name: wired?.name ?? entry.name,
    agent: wired?.agent ?? entry.agent,
    state: found.state,
    hint: found.hint,
    cli: found.cli,
    version: found.version,
    capabilities: wired?.capabilities ?? unwired,
    levels: wired ? levels(wired) : [],
    modes: wired?.modes ?? [],
  };
}

/// One agent turned on, asked again. One with a session asks its provider, which reads its models
/// after the reply if it has just become ready; the rest are asked what the registry can ask them.
async function checked(id: string) {
  const wired = providers.get(id);
  if (!wired) {
    const entry = agent(id);
    if (!entry) throw new Error(`Unknown provider ${id}`);
    if (!isOn(id)) throw new Error(`${entry.name} is off in Settings › Agents.`);
    return described(id, await check(entry));
  }
  const found = await wired.availability();
  if (found.state === "ready" && !listed.has(id)) {
    listed.add(id);
    // A login made since: what was listed before it may not be what it runs now.
    lists.delete(id);
    // After the reply, as hello's are.
    setImmediate(() => void listAfterLogin(wired, found).catch((error) => log(`models not read after a login: ${describe(error)}`)));
  } else if (found.state !== "ready") {
    listed.delete(id);
    lists.delete(id);
  }
  return described(id, found);
}

/// Claude Code asked again after hello answered from what it remembered: a `provider` event only
/// if it's no longer signed in, after the reply, which would undo it before.
async function confirmed(): Promise<void> {
  try {
    const found = await checked(claude.id);
    if (found.state !== "ready") event("provider", found);
  } catch (error) {
    log(`Claude Code's login not asked again: ${describe(error)}`);
  }
}

const methods: Record<string, (params: any) => Promise<unknown>> = {
  /// `agents` are the ones turned on in Settings › Agents beside Claude Code, all looked for in
  /// one login shell; none of their CLIs is asked anything until a check.
  async hello({ agents: on }: { agents?: Record<string, Setting> }) {
    turnOn(on);
    const others = turnedOn().filter((entry) => entry.id !== claude.id);
    lookUp([claude.id, ...others.map((entry) => entry.id)]);
    // Signed in when last asked and the same CLI: hello answers with that, and asks again behind it.
    const known = await claude.remembered?.();
    const [found, ...theirs] = await Promise.all([known ?? claude.availability(), ...others.map(unasked)]);
    if (found.state === "ready") listed.add(claude.id);
    const replied = Promise.withResolvers<void>();
    const models = await claude.models(found, (fields) => void replied.promise.then(() => event("models", fields)));
    // Nothing awaits after this, so it runs once the reply is written: a `models` event
    // arriving first would be undone by the reply.
    setImmediate(replied.resolve);
    if (known) setImmediate(() => void confirmed());
    const providers = [described(claude.id, found), ...others.map((entry, index) => described(entry.id, theirs[index]))];
    return { version, models, claude: found.cli, loggedIn: found.state === "ready", providers };
  },

  /// One agent asked again, after a login in Terminal, without a restart that would end every
  /// thread's CLI.
  async "provider.check"({ provider: id }: { provider?: string }) {
    return checked(id ?? claude.id);
  },

  /// Settings › Agents turned an agent on or off, chose its CLI, kept or removed its key, or
  /// turned a forbidden login on or off. On, it's looked for if it needs to be, and checked.
  async "agent.set"({ provider: id, on, ...setting }: { provider: string; on: boolean } & Setting) {
    if (!agent(id)) throw new Error(`Unknown provider ${id}`);
    change(id, on, setting);
    // Another CLI, key or login lists other models.
    lists.delete(id);
    if (!isOn(id)) return { provider: null };
    lookUp([id]);
    return { provider: await checked(id) };
  },

  /// Every agent OriCode knows, for Settings › Agents.
  async agents() {
    return { agents: registry() };
  },

  /// An agent's models, asked of its CLI the first time the app needs them rather than at launch.
  /// Claude Code has none of its own to ask, so its answer is hello's list.
  async "models.list"({ provider: id = claude.id }: { provider?: string }) {
    const wired = providers.get(id);
    if (!wired) throw new Error(agent(id) ? `${agent(id)!.name} can't list its models yet.` : `Unknown provider ${id}`);
    if (id === claude.id) return { models: await wired.models(await wired.availability(), () => {}) };
    return { models: await listOf(wired) };
  },

  /// `rays` are the models, as `agent/model`, the thread's workers may run on, which makes its
  /// session a head. With workflows on, Claude Code runs its own, as Ultracode at xhigh and asked
  /// for with each message below it; Codex its own ultra at Max on a model that has it; and any
  /// other head OriCode's, told to fan each task out to workers on its rays, with the message too.
  /// Every one of them at the thread's own level. `opened` says another thread opened this one,
  /// which leaves it without open_thread.
  async send({ rays, handover, concise, noFolder, opened, ...params }: SendParams & { provider?: string; rays?: string[]; handover?: string; concise?: boolean; noFolder?: boolean; opened?: boolean }) {
    const agent = provider(params.provider);
    const path = await cli(agent);
    leave(params.threadId, agent);
    const model = params.workflows ? await workflowsModel(agent, path, params.model) : undefined;
    const own = agent.id === claude.id ? params.workflows === true : model !== undefined && !model.ultraRays && params.effort === "max";
    const fans = own ? undefined : model;
    const head = await threadTools({ ...params, rays, opened }, agent, fans);
    const told = agent.id === claude.id && own && params.effort !== "xhigh" ? claudeLead : fans ? lead : undefined;
    // A message into a running turn joins one that was told already.
    const running = sessions.get(params.threadId)?.isRunning;
    // A handover goes ahead of the first message of a session made for it, and never into a turn.
    const opening = handover && !sessions.has(params.threadId) ? `${handed(handover)}\n\n` : "";
    const text = `${opening}${told && !running ? `${told}\n\n` : ""}${params.text}`;
    // Concise replies, asked for in Settings, go where a head's rays do, ahead of them, and after
    // what a thread without a folder is told of where it is.
    const instructions = [noFolder ? scratch : undefined, concise ? brevity : undefined, head.instructions].filter(Boolean).join("\n\n") || undefined;
    const waiting = await session(params.threadId, agent, path).send({ ...params, text, workflows: own, ...head, instructions });
    return waiting ? { ok: true, waiting: true } : { ok: true };
  },

  /// Stop on a head stops its workers too.
  async interrupt({ threadId }: { threadId: string }) {
    await Promise.all([sessions.get(threadId)?.interrupt(), raysOf(threadId)?.stopAll()]);
    return { ok: true };
  },

  async setMode({ threadId, permissionMode }: { threadId: string; permissionMode: PermissionMode }) {
    const found = sessions.get(threadId);
    return { applied: found ? await found.setMode(permissionMode) : true };
  },

  async setFast({ threadId, fast }: { threadId: string; fast: boolean }) {
    const found = sessions.get(threadId);
    return { applied: found ? await found.setFast(fast) : true };
  },

  /// Tells the app, as a `fast` event for the thread, what the CLI would say about fast mode for
  /// the model it names.
  async "fast.check"({ threadId, model, provider: id }: { threadId: string; model?: string; provider?: string }) {
    const agent = provider(id);
    if (!agent.fastCheck) throw new Error(`${agent.name} has no fast mode.`);
    const result = await agent.fastCheck(await cli(agent), model);
    event("fast", { threadId, model: model ?? null, ...result });
    return result;
  },

  async answer(params: Answer) {
    answer(params);
    return { ok: true };
  },

  /// The app's answer to something a tool asked it for, a thread opened say (threads.ts).
  async "app.reply"(params: { requestId: string; result?: unknown; error?: string }) {
    appReplied(params);
    return { ok: true };
  },

  async "git.branch"({ cwd }: { cwd: string }) {
    return branch(cwd);
  },

  async "git.branches"({ cwd }: { cwd: string }) {
    return branches(cwd);
  },
  async "git.switch"({ cwd, branch: name }: { cwd: string; branch: string }) {
    return switchTo(cwd, name);
  },
  async "git.create"({ cwd, name, from }: { cwd: string; name: string; from?: string }) {
    return create(cwd, name, from);
  },
  async "git.previous"({ cwd }: { cwd: string }) {
    return previous(cwd);
  },
  async "git.pull"({ cwd }: { cwd: string }) {
    return pull(cwd);
  },
  async "git.remote"({ cwd }: { cwd: string }) {
    return remote(cwd);
  },
  async "git.commit"({ cwd, paths, message }: { cwd: string; paths: string[]; message: string }) {
    return { hash: await commitAll(cwd, paths, message) };
  },

  async "git.diff"({ cwd, since }: { cwd: string; since?: string }) {
    return workingDiff(cwd, since);
  },

  async "git.apply"({ cwd, patch, reverse, index }: { cwd: string; patch: string; reverse: boolean; index?: boolean }) {
    return applyPatch(cwd, patch, reverse, index ?? false);
  },

  async "git.restore"({ cwd, paths }: { cwd: string; paths: string[] }) {
    return restore(cwd, paths);
  },

  async "git.unrestore"({ cwd, paths, index }: { cwd: string; paths: string[]; index: IndexEntry[] }) {
    await unrestore(cwd, paths, index);
    return { ok: true };
  },

  async "git.commitReviewed"(params: { cwd: string; paths: string[]; patch: string; partial: string[]; message: string }) {
    return { hash: await commitReviewed(params.cwd, params) };
  },

  async "git.push"({ cwd }: { cwd: string }) {
    await push(cwd);
    return { ok: true };
  },

  /// The app sends the diff it's about to commit, cut to keep the Haiku call small.
  async "git.message"({ cwd, diff, model, provider: id }: { cwd: string; diff: string; model?: string; provider?: string }) {
    if (!diff?.trim()) throw new Error("Nothing to describe.");
    const agent = provider(id);
    if (!agent.oneShot) throw new Error(`${agent.name} can't write a commit message.`);
    const prompt =
      "Write a git commit message for this diff. Imperative subject under 60 characters, no prefix, " +
      "then a short body only if the why isn't obvious from the diff. Reply with the message and nothing else.\n\n" +
      diff.slice(0, 60_000);
    return { message: await agent.oneShot(await cli(agent), cwd, prompt, model) };
  },

  /// A question beside a thread, answered from a copy of its session that's never saved. The
  /// answer streams as `side` events and comes whole in the reply; `side.stop` ends it.
  async side({ threadId, sessionId, cwd, text, model, provider: id }: { threadId: string; sessionId: string; cwd: string; text: string; model?: string; provider?: string }) {
    const agent = provider(id);
    if (!agent.aside) throw new Error(`${agent.name} can't answer a side question.`);
    asides.get(threadId)?.abort();
    const stop = new AbortController();
    asides.set(threadId, stop);
    try {
      const answer = await agent.aside(await cli(agent), { cwd, sessionId, model, text }, (delta) => event("side", { threadId, delta }), stop.signal);
      return { text: answer, stopped: stop.signal.aborted };
    } finally {
      if (asides.get(threadId) === stop) asides.delete(threadId);
    }
  },

  async "side.stop"({ threadId }: { threadId: string }) {
    asides.get(threadId)?.abort();
    return { ok: true };
  },

  /// Claude Code's own sessions for a folder, started with `claude` in Terminal, and one of them
  /// as the events a thread stores.
  async "sessions.list"({ cwd }: { cwd: string }) {
    return { sessions: await sessionsIn(cwd) };
  },

  async "sessions.read"({ cwd, sessionId }: { cwd: string; sessionId: string }) {
    return { events: await sessionEvents(cwd, sessionId) };
  },

  /// The MCP servers Claude Code loads for a folder, for Settings › MCP: listed, switched on or
  /// off, added and removed, each through the user's own CLI.
  async "mcp.list"({ cwd }: { cwd: string }) {
    return { servers: await mcpServers(await cli(claude), cwd) };
  },

  async "mcp.toggle"({ cwd, name, on }: { cwd: string; name: string; on: boolean }) {
    return { servers: await mcpServers(await cli(claude), cwd, { name, on }) };
  },

  async "mcp.add"({ cwd, name, target, scope }: { cwd: string; name: string; target: string; scope: string }) {
    const path = await cli(claude);
    await addMcpServer(path, cwd, name, target, scope);
    return { servers: await mcpServers(path, cwd) };
  },

  async "mcp.remove"({ cwd, name, scope }: { cwd: string; name: string; scope: string }) {
    const path = await cli(claude);
    await removeMcpServer(path, cwd, name, scope);
    return { servers: await mcpServers(path, cwd) };
  },

  /// The pull request of the folder's branch through GitHub's CLI: what it is and where its
  /// checks have got, opening one, and what a failing check printed.
  async "pr.status"({ cwd }: { cwd: string }) {
    return { pr: await pullOf(cwd) };
  },

  async "pr.create"({ cwd }: { cwd: string }) {
    return { pr: await openPull(cwd) };
  },

  async "pr.merge"({ cwd }: { cwd: string }) {
    return { pr: await mergePull(cwd) };
  },

  async "pr.log"({ cwd, link }: { cwd: string; link: string | null }) {
    return { log: await failureLog(cwd, link) };
  },

  /// The thread's agent reads a diff and comments on its lines: from a copy of the thread's
  /// session where the agent has side questions and the thread a session, so it knows what was
  /// asked for, and else in one small call that knows only the diff.
  async "review.ask"({ threadId, sessionId, cwd, diff, model, provider: id }: { threadId: string; sessionId?: string; cwd: string; diff: string; model?: string; provider?: string }) {
    if (!diff?.trim()) throw new Error("Nothing to review.");
    const agent = provider(id);
    const prompt = `${reviewLead}\n\n<diff>\n${diff.slice(0, 120_000)}\n</diff>`;
    if (agent.aside && sessionId) {
      const stop = new AbortController();
      return { comments: commentsIn(await agent.aside(await cli(agent), { cwd, sessionId, model, text: prompt }, () => {}, stop.signal)) };
    }
    if (!agent.oneShot) throw new Error(`${agent.name} can't review a diff here.`);
    return { comments: commentsIn(await agent.oneShot(await cli(agent), cwd, prompt)) };
  },

  async "worktree.add"({ cwd, slug, prefix }: { cwd: string; slug: string; prefix?: string }) {
    return addWorktree(cwd, slug, prefix);
  },

  async "worktree.loss"({ path, branch: branchName }: { path: string; branch: string }) {
    return worktreeLoss(path, branchName);
  },

  async "worktree.remove"({ cwd, path, branch: branchName }: { cwd: string; path: string; branch: string }) {
    await removeWorktree(cwd, path, branchName);
    return { ok: true };
  },

  async usage({ provider: id }: { provider?: string }) {
    const agent = provider(id);
    if (!agent.usage) return { available: false, plan: null, windows: [] };
    return agent.usage(await cli(agent));
  },

  async commands({ threadId, cwd, provider: id }: { threadId?: string; cwd: string; provider?: string }) {
    const live = threadId ? await sessions.get(threadId)?.commands().catch(() => undefined) : undefined;
    const agent = provider(id);
    const commands = live ?? (agent.folderCommands ? await agent.folderCommands(await cli(agent), cwd) : []);
    return {
      commands: commands.map((command) => ({ name: command.name, description: command.description, hint: command.argumentHint })),
    };
  },

  /// A custom action run quietly; the app has already quoted every value in the line.
  async "shell.run"({ cwd, command }: { cwd: string; command: string }) {
    return run(cwd, command);
  },

  async "files.list"({ cwd }: { cwd: string }) {
    return { files: await listFiles(cwd) };
  },

  async "files.read"({ cwd, path }: { cwd: string; path: string }) {
    return readProjectFile(cwd, path);
  },

  async "files.write"({ cwd, path, content, stamp }: { cwd: string; path: string; content: string; stamp: string }) {
    return writeProjectFile(cwd, path, content, stamp);
  },

  async "heads.watch"({ threadId, on }: { threadId: string; on: boolean }) {
    if (on) watched.add(threadId);
    else watched.delete(threadId);
    sessions.get(threadId)?.watchHeads(on);
    raysOf(threadId)?.watch(on);
    return { ok: true };
  },

  /// A head's worker stops through its own session; anything else the CLI runs, through the CLI.
  async "task.stop"({ threadId, taskId }: { threadId: string; taskId: string }) {
    const head = raysOf(threadId);
    if (head?.has(taskId)) {
      await head.stop(taskId);
      return { ok: true };
    }
    const found = sessions.get(threadId);
    if (!found) throw new Error("That has already stopped.");
    await found.stopTask(taskId);
    return { ok: true };
  },

  /// The thread's agent changed: its session and workers end, and its next send starts on the new
  /// agent. `send`'s own check does the same when this is late.
  async leave({ threadId }: { threadId: string }) {
    leave(threadId);
    return { ok: true };
  },

  async close({ threadId }: { threadId: string }) {
    raysOf(threadId)?.close();
    sessions.get(threadId)?.close();
    sessions.delete(threadId);
    watched.delete(threadId);
    return { ok: true };
  },

  async window({ threadId, visible }: { threadId?: string | null; visible: boolean }) {
    shown = { threadId: threadId ?? null, visible };
    letGo();
    return { ok: true };
  },
};

let inFlight = 0;

async function handle(line: string): Promise<void> {
  let request: Request;
  try {
    request = JSON.parse(line);
  } catch {
    event("error", { message: `Not JSON: ${line.slice(0, 80)}` });
    return;
  }
  const method = methods[request.method];
  if (!method) {
    emit({ id: request.id, error: `Unknown method ${request.method}` });
    return;
  }
  inFlight += 1;
  try {
    emit({ id: request.id, result: await method(request.params ?? {}) });
  } catch (error) {
    emit({ id: request.id, error: describe(error) });
  } finally {
    inFlight -= 1;
  }
}

let shown: Shown = { threadId: null, visible: true };
let sweep: NodeJS.Timeout | undefined;

/// Lets idle CLIs go, then sleeps until the next one is due, so nothing wakes while none is up.
/// The app hears about each and drops the transcript it no longer needs in memory.
function letGo(): void {
  clearTimeout(sweep);
  const { released, next } = releaseIdle(sessions, shown);
  for (const threadId of released) {
    log(`released thread=${threadId}`);
    event("released", { threadId });
  }
  sweep = next === undefined ? undefined : setTimeout(letGo, next).unref();
}

const input = createInterface({ input: process.stdin });
input.on("line", (line) => {
  if (line.trim()) void handle(line);
});
// Stdin closing means the app is gone. Finish what was asked (so a piped request from
// Terminal still gets its answer), then take the CLIs down with us.
input.on("close", () => {
  setInterval(() => {
    // Reparented to launchd means the app died; a turn nobody can see isn't worth finishing.
    const orphaned = process.ppid === 1;
    if (!orphaned && (inFlight > 0 || [...sessions.values()].some((found) => found.isRunning))) return;
    stopAll();
    for (const found of sessions.values()) found.close();
    process.exit(0);
  }, 200);
});

// The app's restart and its quit end the engine with SIGTERM; quiet actions go with it.
process.on("SIGTERM", () => {
  stopAll();
  for (const found of sessions.values()) found.close();
  process.exit(0);
});
