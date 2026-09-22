import { execFile } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

async function executable(path: string): Promise<boolean> {
  try {
    await access(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

let found: Promise<string | null> | undefined;

/// The `claude` the user installed and logged into. The SDK's own bundled CLI is left
/// out of the app on purpose, so this is the only one the engine will run.
export function findClaude(): Promise<string | null> {
  found ??= (async () => {
    const override = process.env.ORICODE_CLAUDE;
    if (override && (await executable(override))) return override;
    try {
      const { stdout } = await run("/bin/zsh", ["-lc", "command -v claude"], { timeout: 5000 });
      const path = stdout.trim().split("\n").pop();
      if (path && path.startsWith("/") && (await executable(path))) return path;
    } catch {}
    const candidates = [
      join(homedir(), ".local/bin/claude"),
      join(homedir(), ".claude/local/claude"),
      "/opt/homebrew/bin/claude",
      "/usr/local/bin/claude",
    ];
    for (const path of candidates) if (await executable(path)) return path;
    return null;
  })();
  return found;
}

/// Asks the CLI whether it has a login. The engine never sees the credential itself.
export async function loggedIn(claude: string): Promise<boolean> {
  try {
    const { stdout } = await run(claude, ["auth", "status"], { timeout: 10000 });
    return JSON.parse(stdout).loggedIn === true;
  } catch (error) {
    const stdout = (error as { stdout?: string }).stdout;
    try {
      return JSON.parse(stdout ?? "").loggedIn === true;
    } catch {
      return false;
    }
  }
}
