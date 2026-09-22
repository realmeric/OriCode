import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { query, type PermissionMode, type SDKUserMessage, type SlashCommand } from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment, cliDebugFile, findClaude, loggedIn } from "./claude.ts";
import { fallback, fromSDK, type Model } from "./models.ts";
import { answer, describe, Thread, type Answer, type SendParams } from "./thread.ts";
import { addWorktree, branch, commit, diffFor, push, removeWorktree, status, worktreeLoss } from "./git.ts";
import { listFiles, readProjectFile } from "./files.ts";
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

async function supportedModels(claude: string): Promise<Model[]> {
  const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment(), stderr: (data: string) => process.stderr.write(data), debugFile: cliDebugFile("probe") } });
  try {
    const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), 20000));
    return fromSDK(await Promise.race([probe.supportedModels(), timeout]));
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
    }
    return { version, models: models ?? fallback, claude, loggedIn: login };
  },

  async send(params: SendParams) {
    await thread(params.threadId, await requireClaude()).send(params);
    return { ok: true };
  },

  async interrupt({ threadId }: { threadId: string }) {
    await threads.get(threadId)?.interrupt();
    return { ok: true };
  },

  async setMode({ threadId, permissionMode }: { threadId: string; permissionMode: PermissionMode }) {
    const found = threads.get(threadId);
    return { applied: found ? await found.setMode(permissionMode) : true };
  },

  async answer(params: Answer) {
    answer(params);
    return { ok: true };
  },

  async "git.branch"({ cwd }: { cwd: string }) {
    return branch(cwd);
  },

  async "git.status"({ cwd }: { cwd: string }) {
    return { files: await status(cwd) };
  },

  async "git.commit"({ cwd, paths, message }: { cwd: string; paths: string[]; message: string }) {
    return { hash: await commit(cwd, paths, message) };
  },

  async "git.push"({ cwd }: { cwd: string }) {
    await push(cwd);
    return { ok: true };
  },

  async "git.message"({ cwd, paths }: { cwd: string; paths: string[] }) {
    const diff = await diffFor(cwd, paths);
    if (!diff.trim()) throw new Error("Nothing to describe.");
    return { message: await writeMessage(await requireClaude(), cwd, diff) };
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
    for (const found of threads.values()) found.close();
    process.exit(0);
  }, 200);
});
