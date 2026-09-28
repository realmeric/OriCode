import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { agentEnvironment, type Reach } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";

// OpenCode through `opencode acp`. It asks before nothing unless its permission config says to,
// so each thread's process is started with OPENCODE_PERMISSION for the thread's mode, and the
// keys a user gave `opencode auth login` stay in OpenCode's own store. ACP brings no plan from it.

const run = promisify(execFile);

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

/// Each model's variants from `opencode models --verbose`, which prints each model's id on a line
/// and its JSON under it, read from OpenCode's own model cache without reaching a model.
export function variants(output: string): Map<string, string[]> {
  const found = new Map<string, string[]>();
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
      const named = Object.keys(JSON.parse(body.join("\n")).variants ?? {});
      found.set(id, levels.filter((level) => named.includes(level)));
    } catch {
      // A model whose JSON doesn't read offers no levels.
    }
    id = undefined;
    body = [];
  }
  return found;
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
  variants: async (cli) =>
    variants((await run(cli, ["models", "--verbose"], { env: agentEnvironment(), timeout: 20_000, maxBuffer: 16 * 1024 * 1024 })).stdout),
  forget: (cli, sessionId) => run(cli, ["session", "delete", sessionId], { env: agentEnvironment(), timeout: 10_000 }),
});
