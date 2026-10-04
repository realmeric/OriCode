import { query, type McpServerStatus, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { run, within } from "./child.ts";
import { cleanEnvironment } from "./claude.ts";

/// An MCP server Claude Code loads for a folder, as Settings lists it.
export type McpServer = {
  name: string;
  /// connected, failed, needs-auth, pending or disabled.
  status: string;
  /// Whose it is: user, project or local.
  scope: string | null;
  error: string | null;
  tools: number;
  /// Its URL, or the command that starts it.
  target: string | null;
};

const idle: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };

/// The folder's servers and where each has got, read from a CLI started for the question with
/// the user's, the project's and the local settings, which is how Claude Code itself loads them.
/// One asked to be switched is switched first: Claude Code keeps that for the folder itself, in
/// its own configuration, so the app touches nobody's settings files and every later session
/// there starts with it. claude.ai's connectors, which run on the account's login, are left out.
export async function mcpServers(claude: string, cwd: string, toggle?: { name: string; on: boolean }, launch: typeof query = query): Promise<McpServer[]> {
  const probe = launch({ prompt: idle, options: { cwd, pathToClaudeCodeExecutable: claude, settingSources: ["user", "project", "local"], env: cleanEnvironment() } });
  try {
    await within(probe.initializationResult(), 30_000, "Claude Code's MCP servers");
    if (toggle) await within(probe.toggleMcpServer(toggle.name, toggle.on), 30_000, "Claude Code's MCP servers");
    let listed = await probe.mcpServerStatus();
    // A server still connecting says so for a moment; a few looks, three seconds at most.
    for (let look = 0; look < 6 && listed.some((server) => server.status === "pending" && server.scope !== "claudeai"); look++) {
      await new Promise((done) => setTimeout(done, 500));
      listed = await probe.mcpServerStatus();
    }
    return listed.filter((server) => server.scope !== "claudeai").map(shown);
  } finally {
    probe.close();
  }
}

function shown(server: McpServerStatus): McpServer {
  const config = server.config as { url?: string; command?: string; args?: string[] } | undefined;
  return {
    name: server.name,
    status: server.status,
    scope: server.scope ?? null,
    error: server.error ?? null,
    tools: server.tools?.length ?? 0,
    target: config?.url ?? (config?.command ? [config.command, ...(config.args ?? [])].join(" ") : null),
  };
}

/// What `claude mcp add` is given for a server typed into Settings: a URL is an HTTP server, and
/// anything else a command with its arguments, split as a shell would on spaces outside quotes.
export function addArguments(name: string, target: string, scope: string): string[] {
  const trimmed = target.trim();
  if (/^https?:\/\//i.test(trimmed)) return ["mcp", "add", "--scope", scope, "--transport", "http", name, trimmed];
  const words = [...trimmed.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)].map((match) => match[1] ?? match[2] ?? match[3]);
  return ["mcp", "add", "--scope", scope, name, "--", ...words];
}

/// Adds a server the way `claude mcp add` does, by running it: the CLI writes its own
/// configuration. `user` is every project's, `local` this folder's alone.
export async function addMcpServer(claude: string, cwd: string, name: string, target: string, scope: string): Promise<void> {
  if (!/^[A-Za-z0-9_-]+$/.test(name)) throw new Error("A server's name is letters, digits, dashes and underscores.");
  if (!target.trim()) throw new Error("Give the server's URL, or the command that starts it.");
  if (!["user", "local", "project"].includes(scope)) throw new Error(`Unknown scope ${scope}`);
  await cli(claude, cwd, addArguments(name, target, scope));
}

export async function removeMcpServer(claude: string, cwd: string, name: string, scope: string): Promise<void> {
  await cli(claude, cwd, ["mcp", "remove", "--scope", scope, name]);
}

async function cli(claude: string, cwd: string, args: string[]): Promise<void> {
  try {
    await run(claude, args, { cwd, env: cleanEnvironment() as NodeJS.ProcessEnv, timeout: 30_000 });
  } catch (error) {
    const said = (error as { stderr?: string; stdout?: string }).stderr?.trim() || (error as { stdout?: string }).stdout?.trim();
    throw new Error(said || (error as Error).message);
  }
}
