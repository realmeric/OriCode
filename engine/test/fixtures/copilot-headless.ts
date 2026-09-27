// A stand-in for `copilot --headless --stdio`: JSON-RPC in Content-Length frames, answering only
// what OriCode asks of it, as Copilot CLI 1.0.86 answered. COPILOT_ACCOUNT picks the account:
// signedOut, noPlan (Meriç's today), plan, or token for a login from the environment. Every method
// it's asked goes to COPILOT_LOG.
import { appendFileSync } from "node:fs";

const account = process.env.COPILOT_ACCOUNT ?? "plan";
const user = { type: "user", host: "https://github.com", login: "someone" };
const copilotUser =
  account === "noPlan"
    ? { access_type_sku: "no_access", chat_enabled: false, copilot_plan: "individual", can_signup_for_limited: true }
    : { access_type_sku: "free_limited_copilot", chat_enabled: true, copilot_plan: "individual" };

function answer(method: string): unknown {
  switch (method) {
    case "connect":
      return { ok: true, protocolVersion: 3, version: "1.0.86", taskKinds: ["agent", "shell"] };
    case "auth.getStatus":
      if (account === "signedOut") return { isAuthenticated: false, statusMessage: "Not signed in" };
      return { isAuthenticated: true, authType: account === "token" ? "env" : "user", host: "https://github.com", login: "someone" };
    case "account.getCurrentAuth":
      return { authInfo: { ...user, copilotUser } };
  }
  throw new Error(`No ${method} here`);
}

function write(message: object): void {
  const body = JSON.stringify({ jsonrpc: "2.0", ...message });
  process.stdout.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);
}

let buffer = Buffer.alloc(0);
process.stdin.on("data", (chunk: Buffer) => {
  buffer = Buffer.concat([buffer, chunk]);
  while (true) {
    const end = buffer.indexOf("\r\n\r\n");
    if (end < 0) return;
    const length = Number(/Content-Length: (\d+)/.exec(buffer.subarray(0, end).toString())![1]);
    if (buffer.length < end + 4 + length) return;
    const { id, method } = JSON.parse(buffer.subarray(end + 4, end + 4 + length).toString());
    buffer = buffer.subarray(end + 4 + length);
    if (process.env.COPILOT_LOG) appendFileSync(process.env.COPILOT_LOG, method + "\n");
    try {
      write({ id, result: answer(method) });
    } catch (error) {
      write({ id, error: { code: -32601, message: (error as Error).message } });
    }
  }
});
