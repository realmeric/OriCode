import { randomUUID } from "node:crypto";
import { emit } from "./wire.ts";

// The tools an agent has for the user's threads, served beside a head's worker tools from the
// same MCP server (rays.ts). The app keeps the threads, so a call that makes one goes to it as an
// event carrying a request id and waits for its `app.reply`; a suggestion makes nothing, and is an
// event alone. Nothing here keeps a thread or polls one.

/// Threads one turn may open, so a thread can't fan out without end.
export const mostOpened = 3;

export const openThread = {
  name: "open_thread",
  description:
    "Open another thread in OriCode and send it its first message. Call it only when the user asked for another thread in their own words, " +
    '"open another thread", "send this to a new thread", and never because a task looks big enough for one. ' +
    "It is an ordinary thread of the user's, in their list, on your agent and model unless you name others and in a permission mode no looser than yours. " +
    "It works in this project's folder on its own while you go on, and its result doesn't come back to you. " +
    `Returns its name, which you tell the user. A thread opened this way can't open another, and one turn opens ${mostOpened} at most.`,
  inputSchema: {
    type: "object",
    properties: {
      title: { type: "string", description: "A short name for the thread, as the user will see it in their list." },
      message: { type: "string", description: "The thread's first message, written for someone who hasn't seen this conversation: what to do, where, and what the user said about it." },
      agent: { type: "string", description: "Another agent to run it on, by its id, such as claude or codex, when the user asked for one. Yours when left out." },
      model: { type: "string", description: "A model of that agent's, by its id, when the user asked for one. Yours when left out, or on another agent its first." },
      folder: { type: "string", description: "The folder of another of the user's projects, by its full path. This thread's project when left out." },
      worktree: { type: "boolean", description: "Work on a new branch in a git worktree of its own, so its edits can't run into yours." },
    },
    required: ["title", "message"],
  },
};

/// Threads one turn may suggest: the tool is the agent's to offer unasked, and a reply with a row
/// of chips under it is one nobody reads.
export const mostSuggested = 2;

export const suggestThread = {
  name: "suggest_thread",
  description:
    "Offer the user a thread for something you came across that is worth doing and is outside what they asked for: a bug seen in passing, a doc that has gone stale, a test that was already failing. " +
    "Nothing starts. The user sees your title on a button under your reply, and a click opens a new thread in this project with your prompt in its message field, unsent, theirs to edit or ignore. " +
    "Most replies suggest nothing. Suggest only what is real, that you saw yourself in the files or the output, and never a part of the task you were given, a next step in it, or a general improvement. " +
    `One turn suggests ${mostSuggested} at most. Say in a few words of your reply what you noticed; the button carries the rest.`,
  inputSchema: {
    type: "object",
    properties: {
      title: { type: "string", description: "A few words for the button, naming the work: Fix the off-by-one in paginate()." },
      prompt: { type: "string", description: "The thread's first message, written for someone who hasn't seen this conversation: what you saw, in which file and line, and what to do about it." },
    },
    required: ["title", "prompt"],
  },
};

/// What every session with the tools is told of suggest_thread, where its agent has somewhere to
/// hear it. The description alone wasn't enough: an agent said in its reply what it had seen and
/// left the tool uncalled, so this ties the call to that sentence.
export const suggesting =
  "When your reply is about to tell the user of a problem you saw and left alone because it is outside what they asked for, a bug seen in passing, a doc gone stale, a test that was already failing, call suggest_thread for it before you end the turn, one of the oricode MCP server's tools. " +
  "It starts nothing: it puts a button under your reply that opens a new thread with the prompt you wrote, unsent. Never call it for a part of the task, a next step in it or a general improvement. Most replies call for none.";

/// What a session that may open threads is told, where its agent has somewhere to hear it.
export const opening =
  "You can open another thread in OriCode with open_thread, one of the oricode MCP server's tools: an ordinary thread of the user's that starts on the message you give it and goes on without you. " +
  "Open one only when the user asked for another thread in their own words, and tell them its name. Its result doesn't come back to you.";

/// What a thread another thread opened is told, since it has no open_thread to find.
export const openedByAnother = "Another thread opened this one for the user, so it can't open threads of its own.";

/// The app has this long to answer, which for a thread in a new worktree takes in git's work.
const longestAsk = 30_000;

/// The app didn't answer in time. What was asked of it may still happen.
export class Unanswered extends Error {}

const asked = new Map<string, { done: (result: unknown) => void; fail: (error: Error) => void; timer: NodeJS.Timeout }>();

/// Asks the app for something only it can do for a thread, and waits for its `app.reply`.
export function askApp(name: string, fields: Record<string, unknown>): Promise<unknown> {
  const requestId = randomUUID();
  return new Promise((done, fail) => {
    const timer = setTimeout(() => {
      asked.delete(requestId);
      fail(new Unanswered("OriCode hasn't answered yet. What you asked for may still happen, so don't ask again: tell the user to look for it."));
    }, longestAsk);
    asked.set(requestId, { done, fail, timer });
    emit({ event: name, requestId, ...fields });
  });
}

export function appReplied({ requestId, result, error }: { requestId: string; result?: unknown; error?: string }): void {
  const waiting = asked.get(requestId);
  if (!waiting) throw new Error("Nothing is waiting on that reply.");
  asked.delete(requestId);
  clearTimeout(waiting.timer);
  if (error) waiting.fail(new Error(error));
  else waiting.done(result ?? {});
}
