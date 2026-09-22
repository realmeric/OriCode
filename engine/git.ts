import { execFile } from "node:child_process";
import { promisify } from "node:util";

const run = promisify(execFile);

/// Git for the app, which has no shell of its own. Every call runs in the thread's cwd.
export async function git(cwd: string, args: string[]): Promise<string> {
  try {
    const { stdout } = await run("git", args, { cwd, maxBuffer: 32 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } });
    return stdout;
  } catch (error) {
    const stderr = (error as { stderr?: string }).stderr?.trim();
    throw new Error(stderr || (error as Error).message);
  }
}

/// The branch and how many commits it has that its upstream doesn't.
export async function branch(cwd: string): Promise<{ branch: string; ahead: number; upstream: boolean }> {
  const name = (await git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])).trim();
  try {
    const ahead = Number((await git(cwd, ["rev-list", "--count", "@{upstream}..HEAD"])).trim());
    return { branch: name, ahead, upstream: true };
  } catch {
    return { branch: name, ahead: 0, upstream: false };
  }
}
