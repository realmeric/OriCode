import type { Reach } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";

// Devin through `devin acp`, signed in by the user's own `devin auth login`, which it reads from
// its stored credentials. acpx sends clientInfo "windsurf" with a cognition.ai/requestDiagnostics
// flag "for compatibility with supported Devin versions"; Devin 3000.11.3 answered initialize,
// session/new and a prompt for a client named "oricode" with neither, so the engine sends its own
// name. Its ACP sign-in, "Log in with browser", would open a browser from inside a thread, so it
// isn't run: a missing login gets the Terminal line.

/// Devin's ACP session modes by a thread's. Its CLI's Normal, which asks before an edit, isn't
/// among them in 3000.11.3, nor is Autonomous, which needs `--sandbox`; Smart is rolling out by
/// account, and a mode Devin lacks would leave the session in whichever it was, so Auto isn't
/// offered either.
const modes: Record<string, string> = { acceptEdits: "accept-edits", plan: "plan", bypassPermissions: "bypass" };

export function reach(mode: string): Reach {
  return { mode: modes[mode] ?? mode };
}

export const devin = acpProvider({
  id: "devin",
  args: ["acp"],
  permissions: reach,
  // session/load, which replays the conversation the app already has.
  resume: true,
  images: true,
  modeLive: true,
  handoff: "devin --resume {session}",
  modes: ["acceptEdits", "plan", "bypassPermissions"],
});
