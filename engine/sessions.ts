import { existsSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";
import { getSessionInfo, getSessionMessages, listSessions } from "@anthropic-ai/claude-agent-sdk";
import { todosIn, toolView } from "./acp-map.ts";
import { describe } from "./thread.ts";
import { log } from "./wire.ts";

// The sessions the user had in other tools for a project's folder, each to come in as a thread:
// on the agent that made it, picking its session up, where that agent can be given a session by
// its id; otherwise with its transcript, which the thread's own agent is handed over. Each source
// lists and reads its own, from where its tool keeps them, through the tool's own API where it
// has one, and reads only.

/// A session as the events a thread stores: what the user typed, the replies, the thinking, and
/// the tool calls with their results.
export type Transcript = Record<string, unknown>[];

/// A session as its source lists it. `agent` is the agent of OriCode's that ran it, whose mark it
/// shows, and `sessionId` that agent's id for it, which the thread's next message resumes; null
/// when no agent of OriCode's can pick it up, and it comes in with its transcript alone.
export type Found = { id: string; agent: string | null; sessionId: string | null; title: string; modified: number; branch: string | null };

/// A tool whose sessions can come in, and how to read one of them.
export type Source = {
  id: string;
  /// What the list calls it.
  name: string;
  list(folder: Folder): Promise<Found[]>;
  read(id: string): Promise<Transcript>;
};

/// The project's folder, as a tool may have written it down: by the path the project was added
/// by, which can run through a symlink, by the real one, or by another symlink to it.
export type Folder = { path: string; real: string; holds(path: string | null | undefined): Promise<boolean> };

/// The most of one source's sessions listed, latest first.
export const perSource = 40;

export async function folderAt(path: string): Promise<Folder> {
  const real = await resolved(path);
  const seen = new Map<string, Promise<string>>();
  return {
    path,
    real,
    async holds(other) {
      if (!other) return false;
      if (other === path || other === real) return true;
      if (!seen.has(other)) seen.set(other, resolved(other));
      return (await seen.get(other)) === real;
    },
  };
}

/// A path with its symlinks followed; one that's gone, as it was written.
function resolved(path: string): Promise<string> {
  return realpath(path).catch(() => path);
}

export type Listed = Found & { source: string; sourceName: string };

/// Every source's sessions for the folder, latest first. A session two sources list, an app's
/// thread whose agent keeps the session too, is listed once, by the source that comes first. One
/// source that can't be read leaves the rest listed, and the log says why.
export async function sessionsIn(cwd: string, sources: Source[]): Promise<Listed[]> {
  const folder = await folderAt(cwd);
  const lists = await Promise.allSettled(sources.map((source) => source.list(folder)));
  const seen = new Set<string>();
  const found: Listed[] = [];
  lists.forEach((list, index) => {
    const source = sources[index];
    if (list.status === "rejected") return log(`${source.name}'s sessions weren't listed: ${describe(list.reason)}`);
    for (const session of list.value) {
      const key = session.sessionId && `${session.agent}/${session.sessionId}`;
      if (key && seen.has(key)) continue;
      if (key) seen.add(key);
      found.push({ ...session, source: source.id, sourceName: source.name });
    }
  });
  return found.sort((a, b) => b.modified - a.modified);
}

export async function sessionEvents(sources: Source[], source: string, id: string): Promise<Transcript> {
  const found = sources.find((candidate) => candidate.id === source);
  if (!found) throw new Error(`OriCode reads no sessions from ${source}.`);
  return found.read(id);
}

/// A reply's part, after another with nothing between them read as a paragraph of its own, as a
/// live thread's are, rather than run into one sentence.
export function replied(events: Transcript, text: string | null | undefined): void {
  if (!text?.trim()) return;
  events.push({ event: "text", delta: (events.at(-1)?.event === "text" ? "\n\n" : "") + text });
}

/// A tool call another agent made, of the kind its name for the tool says, with the arguments
/// the app shows; a plan written with a tool is told as TodoWrite, as a live thread's is.
export function called(toolUseId: string, name: string, input: unknown, kind: string): Record<string, unknown> {
  const list = todosIn(input);
  if (list) return { event: "tool.use", toolUseId, name: "TodoWrite", input: { todos: list }, kind: "plan", view: { todos: list } };
  return { event: "tool.use", toolUseId, name, input: input ?? {}, kind, view: toolView(input, null, null) };
}

/// Another tool's SQLite store, opened to read and nothing else. SQLite opens a store in WAL mode,
/// even only to read it, by making its log and shared memory beside it where they aren't, which
/// would be writing into the tool's folder; a store with no log has nothing outside its file, so
/// it's read as it is on disk and nothing is made.
export function readOnly(path: string): DatabaseSync {
  if (existsSync(`${path}-wal`)) return new DatabaseSync(path, { readOnly: true });
  const url = pathToFileURL(path);
  url.searchParams.set("immutable", "1");
  return new DatabaseSync(url.href, { readOnly: true });
}

/// Claude Code keeps a session under its folder's path as it was given, symlink and all, and picks
/// it up only from that path: one written down under another path to the folder comes in with its
/// transcript instead.
export function claudeResumes(sessionId: string, recorded: string | null | undefined, folder: Folder): string | null {
  return recorded === folder.path ? sessionId : null;
}

/// Claude Code's own sessions for a folder, the ones started with `claude` in Terminal or in
/// Claude's app, which the SDK reads from where the CLI keeps its transcripts. The engine's own
/// aren't among them, nor any other app's run through the SDK: a thread's session is already a
/// thread, and another app's is that app's to list. The SDK lists a folder's by its real path
/// alone, so it lists every folder's, and the folder's are taken from them by the path each was
/// started in.
export async function claudeSessionsIn(folder: Folder, list: typeof listSessions = listSessions): Promise<Found[]> {
  const found: Found[] = [];
  for (const session of await list({ includeProgrammatic: false })) {
    if (found.length === perSource) break;
    if (!(await folder.holds(session.cwd))) continue;
    found.push({
      id: session.sessionId,
      agent: "claude",
      sessionId: claudeResumes(session.sessionId, session.cwd, folder),
      title: (session.customTitle || session.summary || session.firstPrompt || "").trim() || "Untitled session",
      modified: session.lastModified,
      branch: session.gitBranch ?? null,
    });
  }
  return found;
}

/// Whether Claude Code still keeps a session, which another app's thread may name after it's gone.
export async function claudeKeeps(sessionId: string): Promise<boolean> {
  return (await getSessionInfo(sessionId)) !== undefined;
}

export const claudeCode: Source = {
  id: "claude",
  name: "Claude Code",
  list: (folder) => claudeSessionsIn(folder),
  read: (id) => claudeEvents(id),
};

type Block = { type?: string; text?: string; thinking?: string; id?: string; name?: string; input?: unknown; tool_use_id?: string; content?: unknown; is_error?: boolean };

/// What Claude Code writes into a user's turn that the user never typed: a command's echo, its
/// output, a reminder, a caveat.
const machine = /^\s*<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat|system-reminder|task-notification|bash-input|bash-stdout|bash-stderr)\b/;

/// A Claude Code session's transcript, wherever the CLI keeps it. A subagent's own messages are
/// left out, as they are from a live thread.
export async function claudeEvents(sessionId: string, read: typeof getSessionMessages = getSessionMessages): Promise<Transcript> {
  const messages = await read(sessionId);
  const events: Transcript = [];
  for (const message of messages) {
    if (message.parent_tool_use_id) continue;
    const content = (message.message as { content?: unknown } | null)?.content;
    const blocks: Block[] = typeof content === "string" ? [{ type: "text", text: content }] : Array.isArray(content) ? (content as Block[]) : [];
    for (const block of blocks) {
      if (message.type === "user") {
        if (block.type === "text" && block.text?.trim() && !machine.test(block.text)) events.push({ event: "user", text: block.text });
        if (block.type === "tool_result") events.push({ event: "tool.result", toolUseId: block.tool_use_id ?? "", content: resultText(block.content), isError: block.is_error === true });
      } else if (message.type === "assistant") {
        if (block.type === "text" && block.text?.trim()) events.push({ event: "text", delta: block.text });
        if (block.type === "thinking" && block.thinking?.trim()) events.push({ event: "thinking", delta: block.thinking });
        if (block.type === "tool_use") events.push({ event: "tool.use", toolUseId: block.id ?? "", name: block.name ?? "", input: block.input ?? {} });
      }
    }
  }
  return events;
}

function resultText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return (content as Block[]).map((part) => (part.type === "text" ? (part.text ?? "") : part.type === "image" ? "[image]" : "")).join("\n");
}
