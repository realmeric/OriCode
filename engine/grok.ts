import { tmpdir } from "node:os";
import { AcpSession, type Reach } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";

// Grok Build through `grok agent stdio`, signed in by the user's own `grok login`, which its ACP
// offers as cached_token. Grok comes in by its binary and never by a key: GROK_DISABLE_API_KEY_AUTH
// is xAI's own switch that keeps xai.api_key from being offered or taken, even with XAI_API_KEY in
// the environment. `--no-auto-update` is what xAI's docs give for ACP.

const args = ["--no-auto-update", "agent", "stdio"];
const env = { GROK_DISABLE_API_KEY_AUTH: "1" };

/// Grok's permission mode is set as its process starts, `--permission-mode` on its command line
/// winning over the user's config; plan is a session mode on top. Always-approve can't come from
/// the environment, which Grok ignores for it on purpose. Accept edits and Auto aren't offered:
/// agent stdio starts in neither, and Auto blocks rather than asks in a client Grok doesn't know.
export function reach(mode: string): Reach {
  if (mode === "bypassPermissions") return { mode: "default", args: ["--permission-mode", "bypassPermissions"] };
  return { mode: mode === "plan" ? "plan" : "default", args: ["--permission-mode", "default"] };
}

/// Grok has no status command. Its initialize offers cached_token only when `grok login` left a
/// session it could refresh, which is how xAI's own ACP example decides to say "Run `grok login`".
export async function signedIn(cli: string): Promise<boolean | null> {
  const session = new AcpSession("grok-check", { name: "Grok Build", command: cli, args, env });
  // One that never answers is ended, as a CLI's status call would be.
  const timer = setTimeout(() => session.close(), 15_000);
  try {
    return (await session.signIns(tmpdir())).includes("cached_token");
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

export const grok = acpProvider({
  id: "grok",
  args,
  env,
  authMethod: "cached_token",
  permissions: reach,
  // session/resume, which doesn't replay the conversation.
  resume: true,
  images: false,
  modeLive: false,
  handoff: "grok --resume {session}",
  levels: ["low", "medium", "high", "xhigh"],
  modes: ["default", "plan", "bypassPermissions"],
  unlistedModes: ["default", "plan"],
});
