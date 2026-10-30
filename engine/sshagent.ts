import { statSync } from "node:fs";

/// What an agent is told while it can sign. The same advice as OriPass's own skill, for an agent
/// with no such plugin.
export const signing =
  "ssh, scp and git over ssh go through OriPass here, so use them plainly. A finger may be asked for on the Mac: say so and wait. If signing is refused, stop and tell the user. Never look for a private key on disk and never ask for one.";

let socket: string | undefined;

/// The socket Settings › Agents points at, or nothing while its switch is off. The app says it in
/// `hello` and `sshAgent.set`.
export function useSshAgent(path?: string | null): void {
  socket = path ?? undefined;
}

/// What a process the engine starts takes from the SSH agent: SSH_AUTH_SOCK, while the switch is
/// on and the socket is there, and nothing otherwise, so the variable stays as the engine was
/// given it. Asked at each start and never watched, so the agent can come and go at no cost. It
/// looks at the path and no more: signing is between the process and the agent.
export function sshAgent(): { SSH_AUTH_SOCK?: string } {
  if (!socket) return {};
  try {
    return statSync(socket).isSocket() ? { SSH_AUTH_SOCK: socket } : {};
  } catch {
    return {};
  }
}

/// `signing`, while a process started now would have the socket.
export function signingNow(): string | undefined {
  return sshAgent().SSH_AUTH_SOCK ? signing : undefined;
}
