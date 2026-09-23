import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { constants } from "node:os";

/// A custom action run quietly: one command line in the user's shell, in the thread's folder,
/// with no terminal. The app builds the line, quoting every value it puts in; nothing here
/// decides what runs.
export type ShellResult = {
  code: number;
  /// The last line of output, without colour codes, for the note under the composer.
  line: string;
};

const colour = /\x1b\[[0-9;?]*[ -/]*[@-~]/g;

export function lastLine(output: string): string {
  const lines = output.replace(colour, "").split(/\r\n|\r|\n/).map((line) => line.trim()).filter(Boolean);
  return lines.at(-1) ?? "";
}

/// The process groups of quiet actions still running, which go when the engine does.
const running = new Set<number>();

export function stopAll(): void {
  for (const group of running) {
    try {
      process.kill(-group, "SIGTERM");
    } catch {
      // It has gone already.
    }
  }
  running.clear();
}

// Whichever way the engine ends (stdin closing at quit, SIGTERM on restart, a crash), its quiet
// actions end with it.
process.on("exit", stopAll);

function shell(): string {
  const mine = process.env.SHELL;
  return mine && existsSync(mine) ? mine : "/bin/zsh";
}

/// The engine's environment without what a Claude Code session leaves in it, as for the CLI,
/// so a `claude` in an action doesn't wait for a host that isn't there.
function environment(): NodeJS.ProcessEnv {
  const kept: NodeJS.ProcessEnv = {};
  for (const [key, value] of Object.entries(process.env)) {
    if ((key.startsWith("CLAUDE") && key !== "CLAUDE_CONFIG_DIR") || key === "AI_AGENT" || key === "PWD" || key === "OLDPWD") continue;
    kept[key] = value;
  }
  // Nothing can answer a prompt, so a git that wants a password fails instead of waiting.
  kept.GIT_TERMINAL_PROMPT = "0";
  return kept;
}

/// Runs `command` with the user's shell in `cwd`, stdin closed, and stops it and everything it
/// started after `timeout` ms: SIGTERM, and SIGKILL two seconds later for whatever ignored it.
export function run(cwd: string, command: string, timeout = 120_000): Promise<ShellResult> {
  if (!existsSync(cwd)) return Promise.reject(new Error("The folder isn't there any more."));
  return new Promise((resolve, reject) => {
    // Its own process group, so a timeout reaches whatever the command started.
    const child = spawn(shell(), ["-c", command], { cwd, env: environment(), stdio: ["ignore", "pipe", "pipe"], detached: true });
    const group = child.pid;
    if (group) running.add(group);
    let output = "";
    const keep = (chunk: Buffer) => {
      output = (output + chunk.toString("utf8")).slice(-8192);
    };
    child.stdout.on("data", keep);
    child.stderr.on("data", keep);
    const signal = (name: NodeJS.Signals) => {
      try {
        if (child.pid) process.kill(-child.pid, name);
      } catch {
        // The group has gone already.
      }
    };
    let settled = false;
    const timer = setTimeout(() => {
      // The request answers now, whether or not the command ever lets go.
      settled = true;
      reject(new Error(`Stopped after ${Math.round(timeout / 1000)}s.`));
      signal("SIGTERM");
      // Something that left the group can hold the pipes open long after; stop reading them.
      child.stdout.destroy();
      child.stderr.destroy();
      setTimeout(() => signal("SIGKILL"), 2000);
    }, timeout);
    child.on("error", (error) => {
      if (group) running.delete(group);
      clearTimeout(timer);
      if (!settled) reject(error);
      settled = true;
    });
    child.on("close", (code, ended) => {
      // Tracked until the pipes close, not the shell: a job it left running still holds them.
      if (group) running.delete(group);
      clearTimeout(timer);
      // After a timeout the SIGKILL still goes: the shell can die on SIGTERM while something it
      // started ignores it.
      if (settled) return;
      settled = true;
      resolve({ code: code ?? 128 + (ended ? constants.signals[ended] : 0), line: lastLine(output) });
    });
  });
}
