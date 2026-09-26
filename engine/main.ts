import { createInterface } from "node:readline";
import type { PermissionMode } from "@anthropic-ai/claude-agent-sdk";
import { claude } from "./claude.ts";
import { releaseIdle, type Shown } from "./idle.ts";
import { answer, type Answer, type Provider, type SendParams, type Session } from "./provider.ts";
import { describe } from "./thread.ts";
import { addWorktree, branch, branches, create, previous, pull, push, remote, removeWorktree, switchTo, worktreeLoss } from "./git.ts";
import { applyPatch, commitAll, commitReviewed, restore, unrestore, workingDiff, type IndexEntry } from "./review.ts";
import { listFiles, readProjectFile } from "./files.ts";
import { run, stopAll } from "./shell.ts";
import { version } from "./version.ts";
import { emit, event, log, type Request } from "./wire.ts";

const providers = new Map<string, Provider>([[claude.id, claude]]);
const sessions = new Map<string, Session>();
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
    found.watchHeads(watched.has(threadId));
    // After the turn.done it's called from, and outside the CLI's message loop it would close.
    found.onIdle = () => setImmediate(letGo);
    sessions.set(threadId, found);
  }
  return found;
}

const methods: Record<string, (params: any) => Promise<unknown>> = {
  async hello() {
    const found = await claude.availability();
    const replied = Promise.withResolvers<void>();
    const models = await claude.models(found, (fields) => void replied.promise.then(() => event("models", fields)));
    // Nothing awaits after this, so it runs once the reply is written: a `models` event
    // arriving first would be undone by the reply.
    setImmediate(replied.resolve);
    return { version, models, claude: found.cli, loggedIn: found.state === "ready" };
  },

  async send(params: SendParams & { provider?: string }) {
    const agent = provider(params.provider);
    const waiting = await session(params.threadId, agent, await cli(agent)).send(params);
    return waiting ? { ok: true, waiting: true } : { ok: true };
  },

  async interrupt({ threadId }: { threadId: string }) {
    await sessions.get(threadId)?.interrupt();
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
  async "git.message"({ cwd, diff, provider: id }: { cwd: string; diff: string; provider?: string }) {
    if (!diff?.trim()) throw new Error("Nothing to describe.");
    const agent = provider(id);
    if (!agent.oneShot) throw new Error(`${agent.name} can't write a commit message.`);
    const prompt =
      "Write a git commit message for this diff. Imperative subject under 60 characters, no prefix, " +
      "then a short body only if the why isn't obvious from the diff. Reply with the message and nothing else.\n\n" +
      diff.slice(0, 60_000);
    return { message: await agent.oneShot(await cli(agent), cwd, prompt) };
  },

  async "worktree.add"({ cwd, slug }: { cwd: string; slug: string }) {
    return addWorktree(cwd, slug);
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

  async "heads.watch"({ threadId, on }: { threadId: string; on: boolean }) {
    if (on) watched.add(threadId);
    else watched.delete(threadId);
    sessions.get(threadId)?.watchHeads(on);
    return { ok: true };
  },

  async "task.stop"({ threadId, taskId }: { threadId: string; taskId: string }) {
    const found = sessions.get(threadId);
    if (!found) throw new Error("That has already stopped.");
    await found.stopTask(taskId);
    return { ok: true };
  },

  async close({ threadId }: { threadId: string }) {
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
