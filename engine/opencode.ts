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
  forget: (cli, sessionId) => run(cli, ["session", "delete", sessionId], { env: agentEnvironment(), timeout: 10_000 }),
});
