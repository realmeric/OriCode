import { getSessionMessages, listSessions } from "@anthropic-ai/claude-agent-sdk";

/// Claude Code's own sessions for a folder, the ones started with `claude` in Terminal, which the
/// SDK reads from where the CLI keeps its transcripts. The engine's own aren't among them: a
/// thread's session is already a thread.
export async function sessionsIn(cwd: string, list: typeof listSessions = listSessions): Promise<{ id: string; title: string; modified: number; branch: string | null }[]> {
  const found = await list({ dir: cwd, limit: 40, includeWorktrees: false, includeProgrammatic: false });
  return found.map((session) => ({
    id: session.sessionId,
    title: (session.customTitle || session.summary || session.firstPrompt || "").trim() || "Untitled session",
    modified: session.lastModified,
    branch: (session as { gitBranch?: string }).gitBranch ?? null,
  }));
}

type Block = { type?: string; text?: string; thinking?: string; id?: string; name?: string; input?: unknown; tool_use_id?: string; content?: unknown; is_error?: boolean };

/// What Claude Code writes into a user's turn that the user never typed: a command's echo, its
/// output, a reminder, a caveat.
const machine = /^\s*<(command-name|command-message|command-args|local-command-stdout|local-command-stderr|local-command-caveat|system-reminder|task-notification|bash-input|bash-stdout|bash-stderr)\b/;

/// A session's transcript as the events a thread stores, so it opens as a thread with its
/// transcript: your messages, the replies, the thinking, and the tool calls with their results.
/// A subagent's own messages are left out, as they are from a live thread.
export async function sessionEvents(cwd: string, sessionId: string, read: typeof getSessionMessages = getSessionMessages): Promise<Record<string, unknown>[]> {
  const messages = await read(sessionId, { dir: cwd });
  const events: Record<string, unknown>[] = [];
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
