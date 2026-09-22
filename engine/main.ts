import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { query, type PermissionMode, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { cleanEnvironment, cliDebugFile, findClaude, loggedIn } from "./claude.ts";
import { fallback, fromSDK, type Model } from "./models.ts";
import { answer, describe, Thread, type Answer, type SendParams } from "./thread.ts";
import { emit, event, log, type Request } from "./wire.ts";

const version = "0.1.0";
const threads = new Map<string, Thread>();
let models: Model[] | undefined;

async function requireClaude(): Promise<string> {
  const claude = await findClaude();
  if (!claude) throw new Error("claude isn't installed. Install Claude Code, run `claude` in Terminal and log in.");
  return claude;
}

async function supportedModels(claude: string): Promise<Model[]> {
  const idle: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
  const probe = query({ prompt: idle, options: { cwd: homedir(), pathToClaudeCodeExecutable: claude, settingSources: [], env: cleanEnvironment(), stderr: (data: string) => process.stderr.write(data), debugFile: cliDebugFile("probe") } });
  try {
    const timeout = new Promise<never>((_, reject) => setTimeout(() => reject(new Error("timed out")), 20000));
    return fromSDK(await Promise.race([probe.supportedModels(), timeout]));
  } finally {
    probe.close();
  }
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
