import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { agentEnvironment, type Reach } from "./acp.ts";
import { unifiedHunks } from "./acp-map.ts";
import { acpProvider } from "./acp-provider.ts";
import { binary } from "./agents.ts";
import { run } from "./child.ts";
import type { Model } from "./models.ts";
import { called, perSource, replied, type Found, type Source, type Transcript } from "./sessions.ts";

// OpenCode through `opencode acp`. It asks before nothing unless its permission config says to,
// so each thread's process is started with OPENCODE_PERMISSION for the thread's mode, and the
// keys a user gave `opencode auth login` stay in OpenCode's own store. ACP brings no plan from it.

const permission = (rules: Record<string, string>): Reach => ({ mode: "build", env: { OPENCODE_PERMISSION: JSON.stringify(rules) } });

/// Ask asks before every read, edit, command and fetch; Accept edits only before a command; Plan is
/// its read-only plan agent; Don't ask allows it all. Auto isn't offered: nothing in OpenCode
/// judges a call's risk, and OpenCode as the user set it up, which a mode it lacks gets, runs
/// everything in the folder unasked.
export function reach(mode: string): Reach {
  switch (mode) {
    case "default":
      return permission({ read: "ask", edit: "ask", bash: "ask", webfetch: "ask" });
    case "acceptEdits":
      return permission({ edit: "allow", bash: "ask" });
    case "plan":
      return { mode: "plan" };
    case "bypassPermissions":
      return permission({ "*": "allow" });
    default:
      return { mode: "build" };
  }
}

/// OpenCode's variants, lowest first: the reasoning levels a model offers, which its ACP session
/// names only for the model it's on, as a thought_level option with "default" beside them.
export const levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

/// A model as `opencode models --verbose` prints it: its id on a line and its JSON under it, with
/// its name, its provider's id and its variants, which are its levels.
export type Listed = { id: string; name: string; provider: string | null; levels: string[] };

export function listed(output: string): Listed[] {
  const found: Listed[] = [];
  let id: string | undefined;
  let body: string[] = [];
  for (const line of output.split("\n")) {
    if (id === undefined) {
      if (/^[^\s{}]\S*$/.test(line)) id = line;
      continue;
    }
    body.push(line);
    if (line !== "}") continue;
    try {
      const model = JSON.parse(body.join("\n"));
      const named = Object.keys(model.variants ?? {});
      found.push({ id, name: model.name ?? id, provider: model.providerID ?? null, levels: levels.filter((level) => named.includes(level)) });
    } catch {
      // A model whose JSON doesn't read isn't offered.
    }
    id = undefined;
    body = [];
  }
  return found;
}

/// The model OpenCode starts a session on when none is picked, as its ACP session said it: its
/// own pick among its first provider's models. Not the one last used, which its sessions have
/// been seen to pass over, and not a `model` in its config, which can hold keys.
export function preferred(models: Listed[]): string | undefined {
  const first = models.filter((model) => model.provider === models[0]?.provider);
  const favoured = ["gpt-5", "claude-sonnet-4", "big-pickle", "gemini-3-pro"];
  const rank = (model: Listed) => favoured.findIndex((name) => model.id.includes(name));
  return first.toSorted((a, b) => rank(b) - rank(a) || Number(b.id.includes("latest")) - Number(a.id.includes("latest")) || b.id.localeCompare(a.id))[0]?.id;
}

/// OpenCode's models from `opencode models --verbose` alone, which reads its model cache and
/// starts no session: named as its ACP session names them, "OpenCode Zen/Big Pickle", the
/// provider's name from the models.dev catalog it keeps in its cache folder, and the one it would
/// start on first. That file holds no key.
async function models(cli: string): Promise<Model[]> {
  const { stdout } = await run(cli, ["models", "--verbose"], { env: agentEnvironment(), timeout: 20_000, maxBuffer: 16 * 1024 * 1024 });
  const cache = process.env.XDG_CACHE_HOME ?? join(homedir(), ".cache");
  const catalog = await readFile(join(cache, "opencode", "models.json"), "utf8").then(
    (text) => JSON.parse(text) as Record<string, { name?: string }>,
    (): Record<string, { name?: string }> => ({}),
  );
  const all = listed(stdout);
  const first = preferred(all);
  return [...all.filter((model) => model.id === first), ...all.filter((model) => model.id !== first)].map((model) => ({
    id: model.id,
    name: model.provider ? `${catalog[model.provider]?.name ?? model.provider}/${model.name}` : model.name,
    description: "",
    efforts: model.levels,
    fast: false,
    defaultEffort: null,
    ultra: false,
    ultraBlocked: null,
  }));
}

/// OpenCode's tools by name, as the kinds the app draws.
const kinds: Record<string, string> = {
  bash: "run",
  read: "read",
  edit: "edit",
  patch: "edit",
  multiedit: "edit",
  write: "write",
  glob: "search",
  grep: "search",
  list: "list",
  webfetch: "fetch",
  websearch: "web",
  task: "agent",
  todowrite: "plan",
};

type Part = { type: string; text?: string; synthetic?: boolean; callID?: string; tool?: string; state?: { status?: string; input?: unknown; output?: string; error?: string; metadata?: { exit?: number; diff?: string } } };

/// A session as `opencode export` writes it: its messages, each with its parts.
export type Exported = { messages: { info: { role: string }; parts: Part[] }[] };

/// A session's transcript from its export: what the user typed, without what OpenCode added to
/// it, and each reply's text, reasoning and tool calls.
export function transcriptOf(exported: Exported): Transcript {
  const events: Transcript = [];
  for (const { info, parts } of exported.messages) {
    if (info.role === "user") {
      const text = parts.flatMap((part) => (part.type === "text" && !part.synthetic && part.text ? [part.text] : [])).join("\n");
      if (text.trim()) events.push({ event: "user", text });
      continue;
    }
    for (const part of parts) {
      if (part.type === "text" && !part.synthetic) replied(events, part.text);
      if (part.type === "reasoning" && part.text?.trim()) events.push({ event: "thinking", delta: part.text });
      if (part.type !== "tool" || !part.callID || !part.tool) continue;
      const state = part.state ?? {};
      events.push(called(part.callID, part.tool, state.input, kinds[part.tool] ?? "other"));
      if (state.status !== "completed" && state.status !== "error") continue;
      const diff = state.metadata?.diff;
      events.push({
        event: "tool.result",
        toolUseId: part.callID,
        content: state.output ?? state.error ?? "",
        isError: state.status === "error",
        patch: typeof diff === "string" && state.status === "completed" ? unifiedHunks(diff) : undefined,
        exitCode: typeof state.metadata?.exit === "number" ? state.metadata.exit : undefined,
      });
    }
  }
  return events;
}

/// The user's OpenCode sessions, while OpenCode is turned on in Settings › Agents, as its own
/// commands give them: `opencode session list` run in the folder lists its project's, and
/// `opencode export` writes one out. Each picks up over ACP by its id.
export const opencodeSessions: Source = {
  id: "opencode",
  name: "OpenCode",
  async list(folder) {
    const cli = await binary("opencode");
    if (!cli) return [];
    const { stdout } = await run(cli, ["session", "list", "--format", "json", "--max-count", String(perSource)], { cwd: folder.path, env: agentEnvironment(), timeout: 20_000, maxBuffer: 16 * 1024 * 1024 });
    // With no sessions it prints nothing at all.
    const listed: { id: string; title?: string; updated: number; directory?: string }[] = stdout.trim() ? JSON.parse(stdout) : [];
    const found: Found[] = [];
    for (const session of listed) {
      if (!(await folder.holds(session.directory))) continue;
      found.push({ id: session.id, agent: "opencode", sessionId: session.id, title: session.title?.trim() || "Untitled session", modified: session.updated, branch: null });
    }
    return found;
  },
  async read(id) {
    const cli = await binary("opencode");
    if (!cli) throw new Error("OpenCode is off in Settings › Agents, or isn't installed.");
    const { stdout } = await run(cli, ["export", id], { env: agentEnvironment(), timeout: 30_000, maxBuffer: 256 * 1024 * 1024 });
    return transcriptOf(JSON.parse(stdout));
  },
};

export const opencode = acpProvider({
  id: "opencode",
  args: ["acp"],
  permissions: reach,
  resume: true,
  images: true,
  // Its permissions are read as the process starts, so a new mode waits for the next turn, all but
  // Don't ask, whose asks the engine answers.
  modeLive: true,
  handoff: "opencode --session {session}",
  modes: ["default", "acceptEdits", "plan", "bypassPermissions"],
  levels,
  models,
  // Idle, `opencode acp` holds about 430MB and never settles, at 1.7% CPU and 129 context
  // switches a second, and a turn after it's gone starts about 0.3s later.
  idleRelease: 30_000,
});
