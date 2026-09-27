import { spawn } from "node:child_process";
import { agentEnvironment } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";
import { agent } from "./agents.ts";
import type { Availability } from "./provider.ts";

// GitHub Copilot through `copilot --acp`. Whether it's signed in, and whether that GitHub account
// has a Copilot plan at all, comes from its headless server (`copilot --headless --stdio`, the
// protocol GitHub's own SDK speaks), which ACP can't say: without a plan ACP opens a session and
// answers every prompt with "Error: Authorization error…" as the reply's text.

const modes: Record<string, string> = {
  default: "agent",
  plan: "plan",
  bypassPermissions: "autopilot",
};

/// GitHub's own words when its CLI finds no plan, and the Terminal line that offers Copilot Free.
export const noPlan = "You don't currently have a Copilot subscription. Run `copilot` in Terminal to sign up for Copilot Free.";

type Status = { isAuthenticated?: boolean; authType?: string };
type CopilotUser = { access_type_sku?: string; chat_enabled?: boolean; can_signup_for_limited?: boolean };

/// Asks the headless server who's signed in, and for a GitHub login, what Copilot that account
/// has. Other logins (a token in the environment, gh's) are reported with their token, so they're
/// never asked about and read ready.
export async function availability(cli: string, env: Record<string, string> = {}): Promise<Omit<Availability, "cli">> {
  const server = headless(cli, env);
  try {
    const connected: { version?: string } = await server.request("connect", { supportedTaskKinds: [], clientInfo: { editorName: "oricode", editorVersion: "1" } });
    const version = connected.version ?? null;
    const status: Status = await server.request("auth.getStatus");
    if (!status.isAuthenticated) return { state: "signedOut", version, hint: agent("copilot")!.login };
    if (status.authType !== "user") return { state: "ready", version, hint: null };
    const current: { authInfo?: { copilotUser?: CopilotUser } } = await server.request("account.getCurrentAuth");
    const user = current.authInfo?.copilotUser;
    if (user?.access_type_sku === "no_access" || user?.chat_enabled === false) {
      return { state: "noPlan", version, hint: user.can_signup_for_limited === false ? "You don't currently have a Copilot subscription." : noPlan };
    }
    return { state: "ready", version, hint: null };
  } finally {
    server.close();
  }
}

/// JSON-RPC over stdio framed as LSP frames it, a Content-Length header before each message.
function headless(cli: string, env: Record<string, string>) {
  const child = spawn(cli, ["--headless", "--stdio", "--no-auto-update"], { env: agentEnvironment(env), stdio: ["pipe", "pipe", "ignore"] });
  const pending = new Map<number, { resolve: (result: any) => void; reject: (error: Error) => void }>();
  let nextId = 1;
  let buffer = Buffer.alloc(0);
  const fail = (error: Error) => {
    for (const request of pending.values()) request.reject(error);
    pending.clear();
  };
  child.on("error", fail);
  child.on("close", (code) => fail(new Error(`Copilot's server stopped (exit code ${code}).`)));
  child.stdin.on("error", () => {});
  child.stdout.on("data", (chunk: Buffer) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (true) {
      const end = buffer.indexOf("\r\n\r\n");
      if (end < 0) return;
      const length = Number(/Content-Length: *(\d+)/i.exec(buffer.subarray(0, end).toString())?.[1] ?? NaN);
      if (Number.isNaN(length)) return fail(new Error("Copilot's server sent a frame without its length."));
      if (buffer.length < end + 4 + length) return;
      const message = JSON.parse(buffer.subarray(end + 4, end + 4 + length).toString("utf8"));
      buffer = buffer.subarray(end + 4 + length);
      const request = pending.get(message.id);
      if (!request || message.method !== undefined) continue;
      pending.delete(message.id);
      if (message.error) request.reject(new Error(message.error.message));
      else request.resolve(message.result ?? {});
    }
  });
  const timer = setTimeout(() => fail(new Error("Copilot's server didn't answer in 15 seconds.")), 15_000);
  return {
    request(method: string, params: object = {}): Promise<any> {
      const id = nextId++;
      const body = JSON.stringify({ jsonrpc: "2.0", id, method, params });
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        child.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
      });
    },
    close() {
      clearTimeout(timer);
      child.stdin.end();
      child.kill("SIGTERM");
    },
  };
}

export const copilot = acpProvider({
  id: "copilot",
  args: ["--acp", "--no-auto-update"],
  // Its modes are URIs; Autopilot turns its allow-all on, and leaving it turns it off.
  permissions: (mode) => ({ mode: `https://agentclientprotocol.com/protocol/session-modes#${modes[mode] ?? "agent"}` }),
  textErrors: true,
  resume: true,
  images: true,
  modeLive: true,
  handoff: "copilot --resume {session}",
  levels: ["low", "medium", "high"],
  modes: ["default", "plan", "bypassPermissions"],
});
