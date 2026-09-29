import { spawn } from "node:child_process";

// Every git and every question put to an agent's CLI outside a thread runs through here: in a
// process group of its own, with a deadline. At the deadline, or when the engine goes, the whole
// group goes, so a git blocked in getcwd behind a privacy prompt, or a CLI that never answers,
// can't outlive its request or the app, and neither can anything it started.

/// The groups of children still running, which the engine takes down as it goes.
const running = new Set<number>();

process.on("exit", () => {
  for (const group of running) signal(group, "SIGTERM");
});

export type RunOptions = {
  cwd?: string;
  env?: NodeJS.ProcessEnv;
  /// Written to its standard input, which is otherwise empty.
  input?: string;
  /// How long it may take, in ms.
  timeout: number;
  /// How much it may print; past this it's ended. A megabyte, as execFile has it.
  maxBuffer?: number;
};

/// Rejected with an error shaped as execFile's: `code` is the exit status or the spawn's errno,
/// with what the child printed.
export type RunError = Error & { code?: number | string; killed?: boolean; signal?: NodeJS.Signals | null; stdout: string; stderr: string };

/// execFile's promise, but the child can't outlive the deadline or the engine. Past the deadline
/// the request fails at once and the group is asked to stop, SIGTERM so that a git can let go of
/// its locks, and killed two seconds later.
export function run(command: string, args: string[], options: RunOptions): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: options.cwd, env: options.env, detached: true });
    const group = child.pid;
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let size = 0;
    let settled = false;
    const failed = (message: string, fields: Partial<RunError>) =>
      Object.assign(new Error(message), { stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") }, fields) as RunError;
    const settle = (then: () => void) => {
      if (settled) return;
      settled = true;
      clearTimeout(deadline);
      then();
    };
    const end = (message: string, code?: string) =>
      settle(() => {
        reject(failed(message, { code, killed: true }));
        if (group === undefined) return;
        signal(group, "SIGTERM");
        // Something that left the group can hold the pipes open long after; stop reading them.
        child.stdout.destroy();
        child.stderr.destroy();
        setTimeout(() => {
          signal(group, "SIGKILL");
          running.delete(group);
        }, 2000).unref();
      });
    const deadline = setTimeout(() => end(`${command} ${args.join(" ")} didn't finish in ${options.timeout / 1000}s.`), options.timeout);
    if (group !== undefined) running.add(group);
    child.stdout.on("data", (chunk: Buffer) => {
      size += chunk.length;
      if (size > (options.maxBuffer ?? 1024 * 1024)) end("stdout maxBuffer length exceeded", "ERR_CHILD_PROCESS_STDIO_MAXBUFFER");
      else out.push(chunk);
    });
    child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
    child.on("error", (error: NodeJS.ErrnoException) => settle(() => reject(failed(error.message, { code: error.code }))));
    // Once its pipes have closed, so everything it printed has been read.
    child.on("close", (code, killedBy) => {
      if (group !== undefined) running.delete(group);
      settle(() => {
        if (code === 0) return resolve({ stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") });
        reject(failed(`Command failed: ${command} ${args.join(" ")}\n${Buffer.concat(err).toString("utf8")}`, { code: code ?? undefined, killed: false, signal: killedBy }));
      });
    });
    // A child can exit before it has read everything it was given.
    child.stdin.on("error", () => {});
    child.stdin.end(options.input ?? "");
  });
}

/// run's outcome either way, as execFile's callback has it: what the child printed, and why it
/// failed when it did.
export function runSettled(command: string, args: string[], options: RunOptions): Promise<{ stdout: string; stderr: string; error: RunError | null }> {
  return run(command, args, options).then(
    ({ stdout, stderr }) => ({ stdout, stderr, error: null }),
    (error: RunError) => ({ stdout: error.stdout, stderr: error.stderr, error }),
  );
}

/// What's waited on, or an error once `ms` have gone by; the timer goes either way. The caller's
/// `finally` ends whatever was being asked.
export async function within<T>(waited: Promise<T>, ms: number, what: string): Promise<T> {
  let timer: NodeJS.Timeout | undefined;
  const late = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${what} didn't answer in ${ms / 1000}s.`)), ms);
  });
  try {
    return await Promise.race([waited, late]);
  } finally {
    clearTimeout(timer);
  }
}

/// A group whose processes have all gone is no longer there to signal.
function signal(group: number, name: NodeJS.Signals): void {
  try {
    process.kill(-group, name);
  } catch {}
}
