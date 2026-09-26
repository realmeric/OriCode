import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { query, type FastModeDisabledReason, type FastModeState, type PermissionMode, type SDKUserMessage, type SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { readCatalog, readSettingsEffort } from "./catalog.ts";
import { cleanEnvironment, cliDebugFile, findClaude, loggedIn } from "./claude.ts";
import { fallback, helloList, withDefaults, type Model } from "./models.ts";
import { answer, describe, Thread, type Answer, type SendParams } from "./thread.ts";
import { addWorktree, branch, branches, create, previous, pull, push, remote, removeWorktree, switchTo, worktreeLoss } from "./git.ts";
import { applyPatch, commitAll, commitReviewed, restore, unrestore, workingDiff, type IndexEntry } from "./review.ts";
import { listFiles, readProjectFile } from "./files.ts";
import { run, stopAll } from "./shell.ts";
import { usage } from "./usage.ts";
import { version } from "./version.ts";
import { emit, event, log, type Request } from "./wire.ts";

const threads = new Map<string, Thread>();
let models: Model[] | undefined;

async function requireClaude(): Promise<string> {
  const claude = await findClaude();
  if (!claude) throw new Error("claude isn't installed. Install Claude Code, run `claude` in Terminal and log in.");
  return claude;
}

const idle: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
const commandsByFolder = new Map<string, Promise<SlashCommand[]>>();

/// Commands for a folder when no thread there has a CLI yet: one probe with the user's and
/// the project's settings, kept for the engine's lifetime.
function folderCommands(claude: string, cwd: string): Promise<SlashCommand[]> {
  let found = commandsByFolder.get(cwd);
  if (!found) {
    found = (async () => {
      const probe = query({
        prompt: idle,
        options: { cwd, pathToClaudeCodeExecutable: claude, settingSources: ["user", "project", "local"], env: cleanEnvironment() },
      });
      try {
        return await probe.supportedCommands();
      } finally {
        probe.close();
      }
    })();
    found.catch(() => commandsByFolder.delete(cwd));
    commandsByFolder.set(cwd, found);
  }
  return found;
}

/// Claude Code is moving its list of models to the catalog it caches, behind a flag, and serves
/// that list only while its copy is fresh: the rows and their ids change from one launch to the
/// next. With the catalog off the probe lists the same rows every time, and the engine adds the
/// catalog's names, older models and newer ones itself.
async function supportedModels(claude: string): Promise<Model[]> {
  const env = { ...cleanEnvironment(), CLAUDE_CODE_MODEL_CATALOG: "0" };
  const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env, stderr: (data: string) => process.stderr.write(data), debugFile: cliDebugFile("probe") } });
  try {
    const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), 20000));
    const [list, catalog, settingsEffort] = await Promise.all([Promise.race([probe.supportedModels(), timeout]), readCatalog(), readSettingsEffort()]);
    return helloList(list, catalog, settingsEffort);
  } finally {
    probe.close();
  }
}

/// Each model's default effort and Ultracode, which take a model switch each in two idle CLIs,
/// the second launched with Ultracode on (about two seconds in all), so hello answers without
/// them and the list follows as a `models` event. The user's own settings are read, since an
/// effortLevel there is what a thread's default turns into, but not their hooks, which have no
/// business with a probe. A reading the CLIs can't give leaves that model on its fallback, and
/// the event goes out all the same.
async function learnDefaults(claude: string, base: Model[]): Promise<void> {
  const probe = query({
    prompt: idle,
    options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: ["user"], settings: { disableAllHooks: true }, env: cleanEnvironment() },
  });
  const ultraProbe = query({
    prompt: idle,
    options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: ["user"], settings: { disableAllHooks: true, ultracode: true }, env: cleanEnvironment() },
  });
  try {
    const learned = await withDefaults(probe, ultraProbe, base);
    for (const miss of learned.missed) {
      log(`model defaults: the ${miss.ultracode ? "Ultracode " : ""}probe missed ${miss.id}: ${describe(miss.error)}`);
    }
    models = learned.models;
    event("models", { models, settingsEffort: learned.settingsEffort, ultraKnown: learned.ultraKnown });
  } catch (error) {
    log(`model defaults unavailable: ${describe(error)}`);
  } finally {
    probe.close();
    ultraProbe.close();
  }
}

/// Whether the user's CLI would serve a model fast, asked without sending it anything: the
/// initialize handshake carries the state, and the reason when it can't be on.
async function fastCheck(claude: string, model: string | undefined): Promise<{ state: FastModeState; reason: FastModeDisabledReason | null }> {
  const probe = query({
    prompt: idle,
    options: { cwd: homedir(), model, pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment(), settings: { fastMode: true } },
  });
  try {
    const init = await probe.initializationResult();
    return { state: init.fast_mode_state ?? "off", reason: init.fast_mode_disabled_reason ?? null };
  } finally {
    probe.close();
  }
}

/// One small Haiku call, no tools and no settings, so hooks and MCP servers stay out of it.
async function writeMessage(claude: string, cwd: string, diff: string): Promise<string> {
  const prompt =
    "Write a git commit message for this diff. Imperative subject under 60 characters, no prefix, " +
    "then a short body only if the why isn't obvious from the diff. Reply with the message and nothing else.\n\n" +
    diff;
  const run = query({
    prompt,
    options: { cwd, model: "haiku", tools: [], maxTurns: 1, settingSources: [], pathToClaudeCodeExecutable: claude, env: cleanEnvironment() },
  });
  let text = "";
  for await (const message of run) {
    if (message.type === "result") {
      if (message.subtype !== "success") throw new Error("Couldn't write a message just now.");
      text = message.result;
    }
  }
  return text.trim();
}

function thread(threadId: string, claude: string): Thread {
  let found = threads.get(threadId);
  if (!found) {
    found = new Thread(threadId, claude);
    threads.set(threadId, found);
  }
  return found;
}

const methods: Record<string, (params: any) => Promise<unknown>> = {
  async hello() {
    const claude = await findClaude();
    if (!claude) return { version, models: fallback, claude: null, loggedIn: false };
    const login = await loggedIn(claude);
    if (login && !models) {
      models = await supportedModels(claude).catch((error) => {
        log(`supported models unavailable, using the fallback list: ${describe(error)}`);
        return undefined;
      });
      if (models) void learnDefaults(claude, models);
    }
    return { version, models: models ?? fallback, claude, loggedIn: login };
  },

  async send(params: SendParams) {
    const waiting = await thread(params.threadId, await requireClaude()).send(params);
    return waiting ? { ok: true, waiting: true } : { ok: true };
  },

  async interrupt({ threadId }: { threadId: string }) {
    await threads.get(threadId)?.interrupt();
    return { ok: true };
  },

  async setMode({ threadId, permissionMode }: { threadId: string; permissionMode: PermissionMode }) {
    const found = threads.get(threadId);
    return { applied: found ? await found.setMode(permissionMode) : true };
  },

  async setFast({ threadId, fast }: { threadId: string; fast: boolean }) {
    const found = threads.get(threadId);
    return { applied: found ? await found.setFast(fast) : true };
  },

  /// Tells the app, as a `fast` event for the thread, what the CLI would say about fast mode for
  /// the model it names.
  async "fast.check"({ threadId, model }: { threadId: string; model?: string }) {
    const result = await fastCheck(await requireClaude(), model);
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

  async "git.diff"({ cwd }: { cwd: string }) {
    return workingDiff(cwd);
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
  async "git.message"({ cwd, diff }: { cwd: string; diff: string }) {
    if (!diff?.trim()) throw new Error("Nothing to describe.");
    return { message: await writeMessage(await requireClaude(), cwd, diff.slice(0, 60_000)) };
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

  async usage({ fresh }: { fresh?: boolean }) {
    return usage(await requireClaude(), fresh ? 15_000 : 60_000);
  },

  async commands({ threadId, cwd }: { threadId?: string; cwd: string }) {
    const live = threadId ? await threads.get(threadId)?.commands().catch(() => undefined) : undefined;
    const commands = live ?? (await folderCommands(await requireClaude(), cwd));
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

  async close({ threadId }: { threadId: string }) {
    threads.get(threadId)?.close();
    threads.delete(threadId);
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

/// A thread's CLI stays up between turns, a few hundred MB each, so one left idle this long
/// is let go. The app hears about it and drops the transcript it no longer needs in memory.
const idleRelease = 5 * 60_000;
setInterval(() => {
  for (const [threadId, found] of threads) {
    if (!found.releaseIfIdle(idleRelease)) continue;
    log(`released thread=${threadId}`);
    event("released", { threadId });
  }
}, 60_000).unref();

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
    if (!orphaned && (inFlight > 0 || [...threads.values()].some((found) => found.isRunning))) return;
    stopAll();
    for (const found of threads.values()) found.close();
    process.exit(0);
  }, 200);
});

// The app's restart and its quit end the engine with SIGTERM; quiet actions go with it.
process.on("SIGTERM", () => {
  stopAll();
  for (const found of threads.values()) found.close();
  process.exit(0);
});
