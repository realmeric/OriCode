import { access } from "node:fs/promises";
import { run } from "./child.ts";
import { push } from "./git.ts";

/// A branch's pull request and its checks, as the thread's line shows them.
export type Pull = {
  number: number;
  title: string;
  url: string;
  /// OPEN, MERGED or CLOSED.
  state: string;
  checks: Check[];
};

export type Check = {
  name: string;
  /// pass, fail, pending or skipped.
  state: string;
  link: string | null;
};

let found: Promise<string> | undefined;

/// GitHub's own CLI, with the login its user made: where Homebrew puts it, or wherever a login
/// shell finds it. OriCode holds no GitHub credential.
function gh(): Promise<string> {
  found ??= (async () => {
    for (const path of ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]) {
      try {
        await access(path);
        return path;
      } catch {}
    }
    const { stdout } = await run("/bin/zsh", ["-lc", "command -v gh"], { timeout: 10_000 }).catch(() => ({ stdout: "" }));
    if (stdout.trim().startsWith("/")) return stdout.trim();
    throw new Error("Pull requests go through GitHub's CLI. Install it with `brew install gh`, then run `gh auth login` in Terminal.");
  })();
  found.catch(() => (found = undefined));
  return found;
}

async function call(cwd: string, args: string[], timeout = 60_000): Promise<string> {
  const path = await gh();
  try {
    return (await run(path, args, { cwd, timeout, maxBuffer: 32 * 1024 * 1024, env: { ...process.env, GH_PROMPT_DISABLED: "1", NO_COLOR: "1" } })).stdout;
  } catch (error) {
    const said = (error as { stderr?: string }).stderr?.trim();
    throw new Error(said || (error as Error).message);
  }
}

type Rolled = { __typename?: string; name?: string; workflowName?: string; context?: string; status?: string; conclusion?: string; state?: string; detailsUrl?: string; targetUrl?: string };

/// One check from gh's rollup, a check run or a commit status, in the four states the app shows.
export function checkOf(rolled: Rolled): Check {
  if (rolled.__typename === "StatusContext") {
    const state = rolled.state === "SUCCESS" ? "pass" : rolled.state === "PENDING" || rolled.state === "EXPECTED" ? "pending" : "fail";
    return { name: rolled.context ?? "status", state, link: rolled.targetUrl ?? null };
  }
  const name = [rolled.workflowName, rolled.name].filter(Boolean).join(" / ") || "check";
  if (rolled.status !== "COMPLETED") return { name, state: "pending", link: rolled.detailsUrl ?? null };
  const state = rolled.conclusion === "SUCCESS" ? "pass" : rolled.conclusion === "SKIPPED" || rolled.conclusion === "NEUTRAL" ? "skipped" : "fail";
  return { name, state, link: rolled.detailsUrl ?? null };
}

/// The pull request of the folder's branch, or null when it has none.
export async function pullOf(cwd: string): Promise<Pull | null> {
  let out: string;
  try {
    out = await call(cwd, ["pr", "view", "--json", "number,title,url,state,statusCheckRollup"]);
  } catch (error) {
    if (/no pull requests found|no open pull requests/i.test((error as Error).message)) return null;
    throw error;
  }
  const pr = JSON.parse(out) as { number: number; title: string; url: string; state: string; statusCheckRollup?: Rolled[] };
  return { number: pr.number, title: pr.title, url: pr.url, state: pr.state, checks: (pr.statusCheckRollup ?? []).map(checkOf) };
}

/// Pushes the branch and opens its pull request, title and body from its commits.
export async function openPull(cwd: string): Promise<Pull | null> {
  await push(cwd);
  await call(cwd, ["pr", "create", "--fill"], 120_000);
  return pullOf(cwd);
}

/// The run a check's link points at, when it's one of GitHub Actions'.
export function runOf(link: string | null): { run: string; job: string | null } | null {
  const match = link?.match(/\/actions\/runs\/(\d+)(?:\/job\/(\d+))?/);
  return match ? { run: match[1], job: match[2] ?? null } : null;
}

/// How much of a failing check's log goes to the agent: its end, where the failure is.
const most = 24_000;

/// What a failing check printed, the failed steps only, cut to its end.
export async function failureLog(cwd: string, link: string | null): Promise<string> {
  const ids = runOf(link);
  if (!ids) throw new Error("This check isn't a GitHub Actions run, so its log can't be read here. Open it on GitHub.");
  const log = await call(cwd, ["run", "view", ids.run, "--log-failed", ...(ids.job ? ["--job", ids.job] : [])], 120_000);
  return tail(log, most);
}

export function tail(log: string, limit: number): string {
  // gh prefixes each line with the job, the step and a timestamp, the first behind a byte-order
  // mark; Actions colours its lines and brackets a step's commands in group markers.
  const plain = log
    .replace(/^[^\t\n]*\t[^\t\n]*\t\uFEFF?\d{4}-\d\d-\d\dT[\d:.]+Z ?/gm, "")
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/^##\[(?:group|endgroup)\].*\n?/gm, "")
    .replace(/^##\[error\]/gm, "")
    .trimEnd();
  if (plain.length <= limit) return plain;
  const cut = plain.slice(plain.length - limit);
  return "…\n" + cut.slice(cut.indexOf("\n") + 1);
}
