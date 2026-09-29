import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { agentEnvironment, type Reach } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";
import { run } from "./child.ts";
import type { Model } from "./models.ts";

// OpenCode through `opencode acp`. It asks before nothing unless its permission config says to,
// so each thread's process is started with OPENCODE_PERMISSION for the thread's mode, and the
// keys a user gave `opencode auth login` stay in OpenCode's own store. ACP brings no plan from it.

const permission = (rules: Record<string, string>): Reach => ({ mode: "build", env: { OPENCODE_PERMISSION: JSON.stringify(rules) } });

/// Ask asks before every read, edit, command and fetch; Accept edits only before a command; Auto
/// is OpenCode as the user set it up; Plan is its read-only plan agent; Don't ask allows it all.
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

export const opencode = acpProvider({
  id: "opencode",
  args: ["acp"],
  permissions: reach,
  resume: true,
  images: true,
  // Its permissions are read as the process starts, so a new mode waits for the next turn.
  modeLive: false,
  handoff: "opencode --session {session}",
  modes: ["default", "acceptEdits", "plan", "auto", "bypassPermissions"],
  levels,
  models,
  // Idle, `opencode acp` holds about 430MB and never settles, at 1.7% CPU and 129 context
  // switches a second, and a turn after it's gone starts about 0.3s later.
  idleRelease: 30_000,
});
