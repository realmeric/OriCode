import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { codexThreads } from "./codex-provider.ts";
import { sessionFolder, storeEvents } from "./cursor.ts";
import { claudeEvents, claudeKeeps, claudeResumes, readOnly, replied, type Folder, type Found, type Source, type Transcript } from "./sessions.ts";
import { describe } from "./thread.ts";
import { log } from "./wire.ts";

// T3 Code's threads, from the SQLite store its server keeps in ~/.t3/userdata. Each runs on an
// agent underneath, Claude Code through its SDK, Codex through its app-server, Cursor over ACP,
// and the store keeps that agent's id for its session as the thread's resume cursor: so a thread
// comes in on that agent, picking its session up, with the transcript the agent keeps, and T3
// Code's own copy of its messages stands in where the agent's session is gone.

/// The agents underneath T3 Code that OriCode runs too, by T3 Code's name for each, and the field
/// of its resume cursor that holds the agent's session id.
const underneath: Record<string, { agent: string; field: string }> = {
  claudeAgent: { agent: "claude", field: "resume" },
  codex: { agent: "codex", field: "threadId" },
  cursor: { agent: "cursor", field: "sessionId" },
};

function store(home: string): string {
  return join(home, ".t3", "userdata", "state.sqlite");
}

type Row = { id: string; title: string; branch: string | null; updated: string; cwd: string; ran: string | null; provider: string | null; cursor: string | null };

/// A thread that isn't deleted, where it runs, and the session under it.
const threads = `
  select t.thread_id as id, t.title, t.branch, t.updated_at as updated, coalesce(t.worktree_path, p.workspace_root) as cwd,
    json_extract(r.runtime_payload_json, '$.cwd') as ran, r.provider_name as provider, r.resume_cursor_json as cursor
  from projection_threads t
  join projection_projects p on p.project_id = t.project_id
  left join provider_session_runtime r on r.thread_id = t.thread_id
  where t.deleted_at is null and p.deleted_at is null`;

function rows(home: string, where = "", ...values: string[]): Row[] {
  if (!existsSync(store(home))) return [];
  const db = readOnly(store(home));
  try {
    return db.prepare(`${threads}${where} order by t.updated_at desc`).all(...values) as Row[];
  } finally {
    db.close();
  }
}

/// The agent a thread runs on underneath and its id for the session, when OriCode runs that agent.
function sessionUnder(row: Row): { agent: string; id: string } | undefined {
  const known = row.provider ? underneath[row.provider] : undefined;
  const id = known && row.cursor ? JSON.parse(row.cursor)[known.field] : undefined;
  return known && typeof id === "string" ? { agent: known.agent, id } : undefined;
}

/// Whether the agent underneath still has the session, and can pick it up from the folder.
async function resumable(under: { agent: string; id: string }, row: Row, folder: Folder, home: string): Promise<boolean> {
  switch (under.agent) {
    case "claude":
      return claudeResumes(under.id, row.ran ?? row.cwd, folder) !== null && (await claudeKeeps(under.id));
    case "cursor":
      return existsSync(join(sessionFolder(under.id, home), "store.db"));
    default:
      return true;
  }
}

export async function t3ThreadsIn(folder: Folder, home = homedir()): Promise<Found[]> {
  const found: Found[] = [];
  for (const row of rows(home)) {
    if (!(await folder.holds(row.cwd))) continue;
    const under = sessionUnder(row);
    const picksUp = under !== undefined && (await resumable(under, row, folder, home));
    found.push({ id: row.id, agent: under?.agent ?? null, sessionId: picksUp ? under.id : null, title: row.title.trim() || "Untitled thread", modified: Date.parse(row.updated), branch: row.branch });
  }
  return found;
}

/// A thread's transcript from the agent underneath, tool calls and all, or else the messages T3
/// Code kept of it.
export async function t3ThreadEvents(id: string, home = homedir()): Promise<Transcript> {
  const row = rows(home, " and t.thread_id = ?", id)[0];
  if (!row) throw new Error("T3 Code no longer has that thread.");
  const under = sessionUnder(row);
  const fromAgent = await (async () => {
    if (under?.agent === "claude") return claudeEvents(under.id);
    if (under?.agent === "codex") return codexThreads.read(under.id);
    if (under?.agent === "cursor" && existsSync(join(sessionFolder(under.id, home), "store.db"))) return storeEvents(sessionFolder(under.id, home));
    return [];
  })().catch((error) => {
    log(`T3 Code's thread ${id} read from what it kept, not from ${under?.agent}: ${describe(error)}`);
    return [];
  });
  if (fromAgent.some((event) => event.event === "user")) return fromAgent;
  const db = readOnly(store(home));
  try {
    const events: Transcript = [];
    for (const message of db.prepare("select role, text from projection_thread_messages where thread_id = ? order by created_at").all(id) as { role: string; text: string }[]) {
      if (message.role === "user" && message.text.trim()) events.push({ event: "user", text: message.text });
      if (message.role === "assistant") replied(events, message.text);
    }
    return events;
  } finally {
    db.close();
  }
}

export const t3Code: Source = {
  id: "t3code",
  name: "T3 Code",
  list: (folder) => t3ThreadsIn(folder),
  read: (id) => t3ThreadEvents(id),
};
