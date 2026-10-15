import { readdir, readFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { agentEnvironment } from "./acp.ts";
import { acpProvider } from "./acp-provider.ts";
import { run } from "./child.ts";
import type { Model } from "./models.ts";
import { called, perSource, readOnly, replied, type Found, type Folder, type Source, type Transcript } from "./sessions.ts";
import { log } from "./wire.ts";

// Cursor through `cursor-agent acp`. Each folder it works in gets a worker-server that outlives
// it, which ends with the last of the folder's sessions. Effort, thinking and fast mode are part
// of its model ids, `gpt-5.5[context=272k,reasoning=medium,fast=false]`, so its models carry no
// levels of OriCode's. On the Free plan only Auto runs, though the list shows every model.

/// Auto's id, the one model the Free plan runs.
export const auto = "default[]";

/// A model as Cursor names it: its name, and the settings its id carries as its description.
export function named(model: Model): Model {
  const settings = /\[(.+)\]$/.exec(model.id)?.[1];
  return settings ? { ...model, description: settings.split(",").join(", ") } : model;
}

/// Only Auto on the Free plan, which `cursor-agent about` names; every model on any other plan, or
/// when it can't say.
export function onPlan(tier: string | null | undefined): (models: Model[]) => Model[] {
  return (models) => (tier === "Free" ? models.filter((model) => model.id === auto) : models).map(named);
}

async function plan(cli: string): Promise<(models: Model[]) => Model[]> {
  try {
    const { stdout } = await run(cli, ["about", "--format", "json"], { env: agentEnvironment(), timeout: 10_000 });
    return onPlan(JSON.parse(stdout).subscriptionTier);
  } catch (error) {
    log(`Cursor didn't say its plan: ${(error as Error).message.split("\n")[0]}`);
    return onPlan(null);
  }
}

/// Where Cursor keeps a session it opened over ACP, which listing its models shouldn't leave behind.
export function sessionFolder(sessionId: string, home = homedir()): string {
  if (!/^[\w-]+$/.test(sessionId)) throw new Error(`${sessionId} isn't a session id.`);
  return join(home, ".cursor", "acp-sessions", sessionId);
}

/// The chats `cursor-agent` keeps in Terminal, each in a folder of its own under one for its
/// workspace, with a meta.json saying where it ran and a store.db holding it.
async function chatFolders(home: string): Promise<string[]> {
  const root = join(home, ".cursor", "chats");
  const workspaces = await readdir(root).catch(() => []);
  const chats = await Promise.all(workspaces.map(async (workspace) => (await readdir(join(root, workspace)).catch(() => [])).map((chat) => join(root, workspace, chat))));
  return chats.flat();
}

type ChatMeta = { cwd?: string; title?: string; hasConversation?: boolean; updatedAtMs?: number };

export async function chatsIn(folder: Folder, home = homedir()): Promise<Found[]> {
  const found: Found[] = [];
  for (const chat of await chatFolders(home)) {
    const meta: ChatMeta | undefined = await readFile(join(chat, "meta.json"), "utf8").then(JSON.parse, () => undefined);
    if (!meta?.hasConversation || !(await folder.holds(meta.cwd))) continue;
    found.push({ id: basename(chat), agent: "cursor", sessionId: null, title: meta.title?.trim() || "Untitled chat", modified: meta.updatedAtMs ?? 0, branch: null });
  }
  return found.sort((a, b) => b.modified - a.modified).slice(0, perSource);
}

export async function chatEvents(id: string, home = homedir()): Promise<Transcript> {
  const chat = (await chatFolders(home)).find((folder) => basename(folder) === id);
  if (!chat) throw new Error("Cursor no longer has that chat.");
  return storeEvents(chat);
}

/// Cursor's tools by name, as the kinds the app draws.
const kinds: Record<string, string> = {
  Shell: "run",
  Read: "read",
  Glob: "search",
  Grep: "search",
  LS: "list",
  Edit: "edit",
  StrReplace: "edit",
  MultiEdit: "edit",
  Write: "write",
  Delete: "delete",
  WebSearch: "web",
  WebFetch: "fetch",
  TodoWrite: "plan",
  Task: "agent",
};

type StoredPart = { type: string; text?: string; toolCallId?: string; toolName?: string; args?: unknown; result?: unknown; experimental_content?: { type: string; text?: string }[]; isError?: boolean };

/// A conversation from the store Cursor keeps a chat or an ACP session in: blobs by their hash,
/// each message one as JSON in the AI SDK's shape, and a root blob that lists the conversation's
/// messages in order. Cursor puts what it tells the model of the Mac and the repository into the
/// user's turn too, in tags of its own, and what the user typed in <user_query>.
export function storeEvents(folder: string): Transcript {
  const db = readOnly(join(folder, "store.db"));
  try {
    const meta = db.prepare("select value from meta where key = '0'").get() as { value: string } | undefined;
    if (!meta) return [];
    const blob = db.prepare("select data from blobs where id = ?");
    const data = (id: string) => (blob.get(id) as { data: Uint8Array } | undefined)?.data;
    const root = data(JSON.parse(Buffer.from(meta.value, "hex").toString("utf8")).latestRootBlobId);
    const events: Transcript = [];
    for (const id of root ? listed(root) : []) {
      const bytes = data(id);
      // The root lists more than messages; only a message is JSON.
      if (bytes?.[0] !== 0x7b) continue;
      const message: { role: string; content: string | StoredPart[] } = JSON.parse(Buffer.from(bytes).toString("utf8"));
      const parts: StoredPart[] = typeof message.content === "string" ? [{ type: "text", text: message.content }] : message.content;
      for (const part of parts) {
        if (message.role === "user" && part.type === "text" && part.text) {
          const typed = /<user_query>\s*([\s\S]*?)\s*<\/user_query>/.exec(part.text)?.[1] ?? (part.text.trimStart().startsWith("<") ? undefined : part.text);
          if (typed?.trim()) events.push({ event: "user", text: typed });
        } else if (message.role === "assistant") {
          if (part.type === "text") replied(events, part.text);
          if (part.type === "reasoning" && part.text?.trim()) events.push({ event: "thinking", delta: part.text });
          if (part.type === "tool-call" && part.toolCallId) events.push(called(part.toolCallId, part.toolName ?? "Tool", part.args, kinds[part.toolName ?? ""] ?? "other"));
        } else if (message.role === "tool" && part.type === "tool-result" && part.toolCallId) {
          const content = typeof part.result === "string" ? part.result : (part.experimental_content ?? []).flatMap((item) => (item.type === "text" && item.text ? [item.text] : [])).join("\n");
          events.push({ event: "tool.result", toolUseId: part.toolCallId, content, isError: part.isError === true });
        }
      }
    }
    return events;
  } finally {
    db.close();
  }
}

/// The hashes a root blob lists, its field 1 in protobuf's wire format, in order.
function listed(root: Uint8Array): string[] {
  const ids: string[] = [];
  let at = 0;
  const varint = () => {
    let value = 0;
    for (let shift = 0; at < root.length; shift += 7) {
      const byte = root[at++];
      value += (byte & 0x7f) * 2 ** shift;
      if (byte < 0x80) break;
    }
    return value;
  };
  while (at < root.length) {
    const key = varint();
    const wire = key % 8;
    if (wire === 0) varint();
    else if (wire === 1) at += 8;
    else if (wire === 5) at += 4;
    else if (wire === 2) {
      const length = varint();
      if (Math.floor(key / 8) === 1) ids.push(Buffer.from(root.subarray(at, at + length)).toString("hex"));
      at += length;
    } else break;
  }
  return ids;
}

/// Cursor's chats from `cursor-agent` in Terminal. ACP can't open them, so each comes in with its
/// transcript, handed over.
export const cursorChats: Source = {
  id: "cursor",
  name: "Cursor",
  list: (folder) => chatsIn(folder),
  read: (id) => chatEvents(id),
};

export const cursor = acpProvider({
  id: "cursor",
  args: ["acp"],
  // Cursor's Agent asks before a command and applies edits; Plan reads and changes nothing.
  permissions: (mode) => ({ mode: mode === "plan" ? "plan" : "agent" }),
  allowAlways: "Cursor adds this to its own allowlist, which every Cursor session on this Mac follows.",
  strays: true,
  resume: true,
  images: true,
  modeLive: true,
  // Its ACP sessions live apart from the chats `cursor-agent --resume` opens.
  handoff: null,
  modes: ["acceptEdits", "plan"],
  forget: (_cli, sessionId) => rm(sessionFolder(sessionId), { recursive: true, force: true }),
  runs: plan,
});
