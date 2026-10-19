import { randomUUID } from "node:crypto";
import { emit } from "./wire.ts";

// The tools an agent has for the user's threads, served beside a head's worker tools from the
// same MCP server (rays.ts). The app keeps the threads, so a call that makes, sends to, waits on
// or stops one goes to it as an event carrying a request id and waits for its `app.reply`; a
// suggestion makes nothing, and is an event alone. What a thread may know of the others it reads:
// the app answers a listing or a transcript from the events it has stored. An agent does to
// threads what the user can, and the app keeps a ceiling on how many work at once. Nothing here
// keeps a thread or polls one: a wait is answered by the app when the thread's turn ends.

const reason = { type: "string", description: "Why, in one line the user reads in both threads' transcripts." };
const thread = { type: "string", description: "The thread's id, from list_threads or open_thread's answer." };

export const openThread = {
  name: "open_thread",
  description:
    "Open another thread in OriCode and send it its first message. Open one when you judge the work wants it: when a task has two or more parts that don't depend on each other, open one for each part as your first step, however small, and collect them with wait_thread; or for work in another of the user's projects, or something to look into while you carry on. " +
    "It is an ordinary thread of the user's, in their list, on your agent and model unless you name others and in a permission mode no looser than yours, and it can open threads of its own. " +
    "It works on its own while you go on: wait_thread gives you its reply when its turn ends, message_thread sends it more, stop_thread stops it. " +
    "Returns its name, which you tell the user, and its id. OriCode refuses it when as many threads are working as the user allows at once, and says so.",
  inputSchema: {
    type: "object",
    properties: {
      title: { type: "string", description: "A few words saying what the thread does, as the user will see it in their list under this thread: Write primes.py and run it." },
      message: { type: "string", description: "The thread's first message, written for someone who hasn't seen this conversation: what to do, where, and what to say when it's done." },
      reason,
      agent: { type: "string", description: "Another agent to run it on, by its id, such as claude or codex. Yours when left out." },
      model: { type: "string", description: "A model of that agent's, by its id. Yours when left out, or on another agent its first." },
      folder: { type: "string", description: "The folder of another of the user's projects, by its full path. This thread's project when left out." },
      worktree: { type: "boolean", description: "Work on a new branch in a git worktree of its own, so its edits can't run into yours." },
      task: { type: "string", description: "A task of the plan the thread is for, by its id, T2: the thread takes it as it opens, and is told it ahead of its messages. Only a task that waits on nothing left undone." },
    },
    required: ["title", "message", "reason"],
  },
};

export const messageThread = {
  name: "message_thread",
  description:
    "Send a message to another of the user's threads, one you opened or not, as the user would from its composer. An idle thread starts a turn on it; a working one takes it in at its next step. A working thread on an agent that can't take a message mid-turn refuses it: wait for it with wait_thread, then send again. " +
    "The thread is told the message came from you, with your id, and answers in its own transcript: wait_thread gives you that answer. " +
    "OriCode refuses one to a thread in a looser permission mode than yours, and one that would start a turn when as many threads are working as the user allows at once, and says why.",
  inputSchema: {
    type: "object",
    properties: {
      thread,
      text: { type: "string", description: "The message, written for a reader who hasn't seen your conversation." },
      reason,
    },
    required: ["thread", "text", "reason"],
  },
};

export const waitThread = {
  name: "wait_thread",
  description:
    "Wait for another thread's turn to end, and get its last reply. A thread that isn't working answers at once with the reply it last gave. " +
    "Waits up to five minutes; a thread still working then comes back with its state and no reply, and you can call again. A thread waiting on the user to answer a question waits on them, and says so. " +
    "When its turn edited a file another working thread of the project edited too, the answer names each in `sameFiles`: merging both will meet it.",
  inputSchema: {
    type: "object",
    properties: { thread },
    required: ["thread"],
  },
};

export const stopThread = {
  name: "stop_thread",
  description:
    "Stop another thread's turn, as the user's Stop button would: what it was doing ends and what it had waiting goes back to its composer. The thread stays, and a message starts it again. Only a working thread can be stopped.",
  inputSchema: {
    type: "object",
    properties: { thread, reason },
    required: ["thread", "reason"],
  },
};

export const mergeThread = {
  name: "merge_thread",
  description:
    "Bring the work of a thread you opened with a worktree into your own folder, once its turn has ended: what's uncommitted in its worktree is committed to its branch, and git merges the branch into your folder as it is, so the files arrive uncommitted beside your own edits for the user to review. Returns what came in. " +
    "When nothing in its worktree is left unmerged, OriCode removes the worktree and its branch, and the thread works in your folder from then on. " +
    "When git meets a conflict, the merge stays open: you get each conflicting file with its hunks, marked in the file as git marks them. Settle each in the file, or ask the user which side to keep where you can't tell, then call finish_merge; or finish_merge with undo, which puts every file the merge wrote back as it was. A merge still open when your turn ends is undone.",
  inputSchema: {
    type: "object",
    properties: { thread },
    required: ["thread"],
  },
};

export const finishMerge = {
  name: "finish_merge",
  description:
    "Finish the merge merge_thread or merge_worker left open on a conflict, once no conflict's markers are left in its files and a side is kept for each conflict git couldn't mark; or with undo, take it back, every file it wrote put back as it was before the merge.",
  inputSchema: {
    type: "object",
    properties: {
      undo: { type: "boolean", description: "Take the merge back instead of finishing it." },
      keep: {
        type: "object",
        additionalProperties: { type: "string", enum: ["folder", "branch"] },
        description: "For each conflict git couldn't mark, a file one side deleted or a binary one, by its path: \"folder\" keeps your folder's side as it was before the merge, \"branch\" the merged thread's, the file removed where that side has none.",
      },
    },
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

export const listThreads = {
  name: "list_threads",
  description:
    "List the user's threads in this project as OriCode has them stored: each one's id, name, agent, whether it is working, waiting on the user or idle, when it was last active, and the files it edited most recently, latest first. " +
    'To find which thread changed a file, pass `edited`: only the threads whose own edits touched that file come back, from their whole history. An edit is a file the thread\'s agent or one of its workers wrote with an edit tool; what a shell command changed isn\'t known. ' +
    "It reads and starts nothing. Use it to find a thread to read, message, wait on or stop, or when the user asks about their other threads.",
  inputSchema: {
    type: "object",
    properties: {
      edited: { type: "string", description: "A file's name or path, Drawer.swift or App/Drawer.swift. Only threads that edited it are listed, each with the matching files." },
    },
  },
};

export const readThread = {
  name: "read_thread",
  description:
    "Read another thread's transcript as OriCode stored it: what the user said, what the agent answered, and each tool call as one line. " +
    "One call returns the latest part, oldest line first, up to about 12,000 characters, with long messages cut. When there is more, the answer carries `before`: pass it back to read the part before that. " +
    "Reading wakes nothing: the thread isn't told and nothing is sent to it. Read only what the user's question needs.",
  inputSchema: {
    type: "object",
    properties: {
      thread: { type: "string", description: "The thread's id, from list_threads or from open_thread's answer." },
      before: { type: "number", description: "The `before` of an earlier answer, for the part of the transcript ahead of it." },
    },
    required: ["thread"],
  },
};

/// What every session with the tools is told of suggest_thread, where its agent has somewhere to
/// hear it. The description alone wasn't enough: an agent said in its reply what it had seen and
/// left the tool uncalled, so this ties the call to that sentence.
export const suggesting =
  "When your reply is about to tell the user of a problem you saw and left alone because it is outside what they asked for, a bug seen in passing, a doc gone stale, a test that was already failing, call suggest_thread for it before you end the turn, one of the oricode MCP server's tools. " +
  "It starts nothing: it puts a button under your reply that opens a new thread with the prompt you wrote, unsent. Never call it for a part of the task, a next step in it or a general improvement. Most replies call for none.";

/// The first half of `opening`: parts that don't depend on each other go to threads. A head that
/// chooses its models is told to give them to workers instead (rays.ts's `choosing`).
export const parts =
  "In OriCode you work as a lead, not alone. When what you're asked has two or more parts that don't depend on each other, don't start on them yourself: first open a thread for each part with open_thread, then wait for each with wait_thread and bring their replies together, however small the parts are. The user watches each thread work on its own, which is why they use OriCode. Two scripts that don't use each other are two parts, and so are a fix and an unrelated change to the docs. A thread that edits files while another does gets a worktree of its own with open_thread's `worktree`, and once its turn is done you bring its work into your folder with merge_thread. Only a task that is one part, or a question, you do yourself. When parts wait on others, write every part first as a task of the project's plan with add_tasks, with what each waits on, then open a thread for each task that waits on nothing with open_thread's `task`, and one for each of the rest once what it waits on is done. ";

/// The second half: what the tools do to the user's threads, which every session with them hears.
export const reach =
  "Those tools are the oricode MCP server's, and with them you do to the user's other threads what the user can: open_thread starts one, message_thread sends one a message, wait_thread waits for one's turn to end and gives you its last reply, stop_thread stops one, merge_thread brings the work of one you opened with a worktree into your folder, and list_threads and read_thread show what there is. read_plan shows the project's plan, every thread working in any project and every ask waiting on the user, and add_tasks, claim_task and update_task keep the plan. You decide when to use them. " +
  "Each open, message and stop takes a one-line reason, which both threads show the user. Ask the user first only where you aren't sure they'd want it. What the user doesn't want you to do with threads is written in the project's CLAUDE.md or AGENTS.md: keep to it. A thread you open runs in a permission mode no looser than yours, and OriCode refuses a call that would set more threads working than the user allows at once, and tells you why.";

/// What every session with the tools is told of them, where its agent has somewhere to hear it:
/// that it decides, asks where it isn't sure, and keeps to the project's instruction file.
export const opening = `${parts}${reach}`;

/// What goes ahead of each message to a thread on an agent other than Claude Code, since Codex
/// weighed `opening` below its own habit of doing every part itself: told only in its developer
/// instructions it gave a two-part task threads in 6 runs of 21, and with this line in 3 of 3.
export const leading = "[OriCode] Parts of this message that don't depend on each other each go to a thread of their own, opened with open_thread, before you start on any of them.";

/// `leading` for a head that chooses its models, whose parts go to workers, and which moves its own
/// level, with where it stands. Claude Code hears it too: told only in its system prompt, Sonnet at
/// low did a three-part task alone and never moved.
export function choosingLead(model: string | undefined, level: string | undefined): string {
  return `[OriCode] You choose who works on this and how hard; you're on ${model ?? "the default model"} at ${level ?? "its default level"}. Parts of this message that don't depend on each other each go to a worker of their own, started with start_worker on whichever ready agent's model suits that part and at the level it needs, before you start on any of them. Before a part you do yourself that needs judgment, a review, a design or a hard fix, first call change_my_model to move up to high or above unless you're there, and move back down once it's done.`;
}

/// A message one thread sends another goes ahead of the text with who sent it, so the thread can
/// answer it, and the transcript shows the text alone.
export function fromThread({ id, title }: { id: string; title: string }): string {
  return `[From another thread] The thread "${title}" (id ${id}) sent you this through OriCode. Answer it here as you would the user: it reads your reply with wait_thread, and can message you again.`;
}

/// How long a wait_thread waits for a turn to end before it answers that the thread still works.
export const longestTurnWait = 300_000;

/// The app has this long to answer, which for a thread in a new worktree takes in git's work.
const longestAsk = 30_000;

/// The app didn't answer in time. What was asked of it may still happen.
export class Unanswered extends Error {}

const asked = new Map<string, { done: (result: unknown) => void; fail: (error: Error) => void; timer: NodeJS.Timeout }>();

/// Asks the app for something only it can do for a thread, and waits for its `app.reply`.
export function askApp(name: string, fields: Record<string, unknown>, within = longestAsk): Promise<unknown> {
  const requestId = randomUUID();
  return new Promise((done, fail) => {
    const timer = setTimeout(() => {
      asked.delete(requestId);
      fail(new Unanswered("OriCode hasn't answered yet. What you asked for may still happen, so don't ask again: tell the user to look for it."));
    }, within);
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
