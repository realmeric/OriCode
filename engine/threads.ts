import { randomUUID } from "node:crypto";
import { asks } from "./provider.ts";
import { emit, event } from "./wire.ts";

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
      mode: { type: "string", description: "A permission mode for it tighter than yours, by its id: plan, default (Ask), acceptEdits or auto. Yours when left out." },
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
    "While your turn runs, an ask of a thread you set going comes to you before the user: the wait answers at once with it in `asks`, whichever thread you wait on, and you answer it with answer_ask before you wait again. Keep waiting while threads you set going work: an ask you haven't read in a wait within 30 seconds, or answered within two minutes of reading it, goes on up without you. " +
    "When its turn edited a file another working thread of the project edited too, the answer names each in `sameFiles`: merging both will meet it.",
  inputSchema: {
    type: "object",
    properties: { thread },
    required: ["thread"],
  },
};

export const answerAsk = {
  name: "answer_ask",
  description:
    "Answer an ask of a thread you set going with open_thread or message_thread, which wait_thread gives you in `asks`. OriCode sends it to you before the user while your turn runs. " +
    "`allow` lets the call run, and takes only what your own permission mode would have done without asking the user: on Accept edits or Auto an edit to a file in your folder or the thread's, on Don't ask anything, on Ask or Plan nothing; `youMayAllow` says which. `deny` refuses it, and the thread is told your reason. `answer` answers its question from what you know of the task, with `answers`. " +
    "`pass` sends it up, to the thread that set yours going while its turn runs and otherwise to the user, with your reason: pass what your mode can't allow, and what you aren't sure the user would want. " +
    "Each answer is a line in both threads' transcripts, so the user reads what was allowed on their behalf and by whom. An ask still with you when your turn ends goes up by itself.",
  inputSchema: {
    type: "object",
    properties: {
      ask: { type: "string", description: "The ask's id, from wait_thread's `asks`." },
      answer: { type: "string", enum: ["allow", "deny", "answer", "pass"], description: "What you do with it." },
      answers: {
        type: "object",
        additionalProperties: { type: "string" },
        description: "For a question: each question's text to its answer, one of its options' labels or your own words.",
      },
      reason,
    },
    required: ["ask", "answer", "reason"],
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
    "One call lists forty; when there are more, the answer says how many in `more`, and `skip` gives the next forty. To find a thread by its name, pass `named`. " +
    "A row with `kind` is an agent under the thread that opened it, a workflow's agent, a subagent or a worker, not a thread of the user's. " +
    "It reads and starts nothing. Use it to find a thread to read, message, wait on or stop, or when the user asks about their other threads.",
  inputSchema: {
    type: "object",
    properties: {
      edited: { type: "string", description: "A file's name or path, Drawer.swift or App/Drawer.swift. Only threads that edited it are listed, each with the matching files." },
      named: { type: "string", description: "Words of a thread's name, in any case. Only threads whose name holds them are listed." },
      skip: { type: "number", description: "How many of the threads, latest first, to pass over: 40 for the second forty." },
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
  "In OriCode you work as a lead, not alone. When what you're asked has two or more parts that don't depend on each other, don't start on them yourself: first open a thread for each part with open_thread, then wait for each with wait_thread and bring their replies together, however small the parts are. The user watches each thread work on its own, which is why they use OriCode. Two scripts that don't use each other are two parts, and so are a fix and an unrelated change to the docs. A thread that edits files while another does gets a worktree of its own with open_thread's `worktree`, and once its turn is done you bring its work into your folder with merge_thread. Only a task that is one part, or a question, you do yourself. When parts wait on others, don't open their threads yourself: write every part as a task of the project's plan with add_tasks and `run`, each with what it waits on, its first message and a worktree when it edits files while another does. OriCode starts each as a thread under you once what it waits on is done and merged; wait for them with wait_plan, bring each one's work into your folder with merge_thread as it comes back, and once wait_plan says planDone, bring their results together. ";

/// The second half: what the tools do to the user's threads, which every session with them hears.
export const reach =
  "Those tools are the oricode MCP server's, and with them you do to the user's other threads what the user can: open_thread starts one, message_thread sends one a message, wait_thread waits for one's turn to end and gives you its last reply, answer_ask answers what one you set going asks, stop_thread stops one, merge_thread brings the work of one you opened with a worktree into your folder, and list_threads and read_thread show what there is. read_plan shows the project's plan, every thread working in any project and every ask waiting on the user, add_tasks, claim_task and update_task keep the plan, and add_tasks with `run` runs its tasks as threads under you, which wait_plan waits on. You decide when to use them. " +
  "Each open, message and stop takes a one-line reason, which both threads show the user. While your turn runs, what a thread you set going asks comes to you before the user, in wait_thread's answer: allow what your own mode would allow, answer its questions from what you know, deny what shouldn't happen, and pass up what your mode can't allow or you aren't sure of, each with answer_ask and a reason. Ask the user first only where you aren't sure they'd want it. What the user doesn't want you to do with threads is written in the project's CLAUDE.md or AGENTS.md: keep to it. A thread you open runs in a permission mode no looser than yours, and OriCode refuses a call that would set more threads working than the user allows at once, and tells you why. " +
  "Beyond threads, you do in OriCode what the user does from its menus, ⌘K and Settings, with tools named as those name them: rename_thread, archive_thread, restore_thread, delete_thread, pin_thread, open_beside, close_other_side, show, change_thread, change_setting, add_project, run_command and read_oricode, each with a one-line reason the user reads in this thread. To have the user look at something, point at it: show the review on the file, show the file, or open_beside the thread. What loosens what guards the user is theirs to allow, and OriCode asks them; tightening is yours.";

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
export function choosingLead(model: string | undefined, level: string | undefined, budget = false): string {
  const fan = budget
    ? "Parts of this message that don't depend on each other each go to a worker of their own, started with start_worker on whichever ready agent's model suits that part and at the level it needs, before you start on any of them."
    : "When this message has parts, each goes to a thread of its own before you start on any of them: write every part as a task of the plan with add_tasks and `run`, with what it waits on, on whichever ready agent's model suits it at the level it needs, then wait_plan and merge_thread as each comes back.";
  return `[OriCode] You choose who works on this and how hard; you're on ${model ?? "the default model"} at ${level ?? "its default level"}. ${fan} Before a part you do yourself that needs judgment, a review, a design or a hard fix, first call change_my_model to move up to high or above unless you're there, and move back down once it's done.`;
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

// What the user does from OriCode's menus, ⌘K and Settings, as tools named the way those name it
// (K-303). Each goes to the app as one `oricode.act` event with the tool's name and arguments, and
// the app does it as the menu would, with a quiet line in the asking thread. What would loosen what
// guards the user, a looser permission mode, a higher budget or ceiling, a command run where the
// thread's mode would ask, the app answers with the change instead, for the user to allow: the
// engine asks them in the thread, and only their Allow sends the act again with `allowed`.
// Tightening is the agent's own call. No tool reads or sets a login or an API key.

const optionalThread = { type: "string", description: "The thread's id, from list_threads. This thread when left out." };

export const menuTools = [
  {
    name: "rename_thread",
    description: "Rename a thread, as Rename Thread… does. The name is what the user sees in their list.",
    inputSchema: { type: "object", properties: { thread: optionalThread, title: { type: "string", description: "The new name, a few words." }, reason }, required: ["title", "reason"] },
  },
  {
    name: "archive_thread",
    description:
      "Archive a thread, as Archive Thread does: it leaves the list and keeps everything, its transcript, its session and its worktree, and the threads it opened go with it. A thread at work, or with threads under it at work, is stopped first with stop_thread. restore_thread brings it back.",
    inputSchema: { type: "object", properties: { thread, reason }, required: ["thread", "reason"] },
  },
  {
    name: "restore_thread",
    description: "Bring an archived thread back into the list, as Restore Thread does, with the threads archived with it.",
    inputSchema: { type: "object", properties: { thread, reason }, required: ["thread", "reason"] },
  },
  {
    name: "delete_thread",
    description:
      "Ask the user to delete a thread, as Delete Thread… does: OriCode puts its own confirmation in front of them, with what removing its worktree would lose, and the thread goes only if they confirm. The answer says they were asked, not that it's gone.",
    inputSchema: { type: "object", properties: { thread, reason }, required: ["thread", "reason"] },
  },
  {
    name: "pin_thread",
    description: "Pin a thread at the top of the list, or unpin it, as Pin Thread and Unpin Thread do.",
    inputSchema: { type: "object", properties: { thread: optionalThread, pinned: { type: "boolean", description: "true pins it, false unpins it." }, reason }, required: ["pinned", "reason"] },
  },
  {
    name: "open_beside",
    description:
      "Put a thread beside the one the user has open, as Open Beside… does, so they watch it while they write in theirs. The keyboard stays where it is. It's how to show the user a thread.",
    inputSchema: { type: "object", properties: { thread, reason }, required: ["thread", "reason"] },
  },
  {
    name: "close_other_side",
    description: "Take the thread beside the open one out of the window, as Close Other Side does. It goes on with whatever it was doing.",
    inputSchema: { type: "object", properties: { reason }, required: ["reason"] },
  },
  {
    name: "show",
    description:
      "Bring something up in front of the user, as its menu item would, so \"look at this\" points at the thing itself. `review`: Review Changes, landing on `path` at `line` when given; it shows the changes of the thread the user has open, so this thread must be that one. `file`: a file in the viewer, from this thread's folder, at `line`. `everything_running`: Show Everything Running (⌘⇧I), every thread and plan at work. `heads`: Show Heads, the open thread's head and workers. `threads`: Show Threads, the list. `settings`: Settings, on `pane`. `shortcuts`: Keyboard Shortcuts.",
    inputSchema: {
      type: "object",
      properties: {
        what: { type: "string", enum: ["review", "file", "everything_running", "heads", "threads", "settings", "shortcuts"] },
        path: { type: "string", description: "For review or file: the file, relative to this thread's folder or in full." },
        line: { type: "number", description: "For review or file: the line to land on." },
        pane: { type: "string", enum: ["general", "agents", "mcp", "conversation", "sourceControl", "archive", "activity", "notifications", "actions", "shortcuts", "about"], description: "For settings: which pane." },
        reason,
      },
      required: ["what", "reason"],
    },
  },
  {
    name: "change_thread",
    description:
      "Change what the Thread menu sets for a thread: its model, effort, fast mode, Workflows and permission mode, each held from its next message. A model is one of the thread's own agent's; a thread on another agent is open_thread's. " +
      "A tighter permission mode is yours to set. A looser one, on this thread or another, is the user's: OriCode asks them in this thread and the call waits for their answer. If they say no, don't ask again this turn.",
    inputSchema: {
      type: "object",
      properties: {
        thread: optionalThread,
        model: { type: "string", description: "A model of the thread's agent, by its id." },
        effort: { type: "string", description: "One of the model's levels, or default." },
        fast_mode: { type: "boolean" },
        workflows: { type: "boolean" },
        permission_mode: { type: "string", description: "plan, default (Ask), acceptEdits, auto or bypassPermissions (Don't ask), among the agent's own." },
        reason,
      },
      required: ["reason"],
    },
  },
  {
    name: "change_setting",
    description:
      "Change one of OriCode's Settings, by the name read_oricode lists it under. One that loosens what guards the user, a higher Spend per thread or none, more Threads working at once, Threads answer first on, a looser permission mode for new threads, is theirs: OriCode asks them in this thread and the call waits for their answer. Tightening one is yours. " +
      "Logins, API keys, an agent's CLI, MCP servers, shortcuts, actions and seeing and using the Mac aren't here: those the user changes in Settings.",
    inputSchema: {
      type: "object",
      properties: {
        setting: { type: "string", description: "The setting's name from read_oricode's `settings`, such as threads_working_at_once." },
        value: { description: "Its new value, of the kind read_oricode shows: true or false, a number or a word. For keep_heads_off, {\"model\": \"codex/gpt-5.5\", \"off\": true}; for agent_on, {\"agent\": \"codex\", \"on\": false}." },
        reason,
      },
      required: ["setting", "value", "reason"],
    },
  },
  {
    name: "add_project",
    description: "Add a folder on this Mac to the user's projects, as Add Project… does, without moving the user off the thread they have open. A folder that's already one stays as it is.",
    inputSchema: { type: "object", properties: { folder: { type: "string", description: "The folder's full path." }, reason }, required: ["folder", "reason"] },
  },
  {
    name: "run_command",
    description:
      "Run a command in a terminal block in this thread, as ⌘K's Run a command… does, for something the user should watch run: a dev server, a log, a long build. It runs in this thread's folder on its own, and its output reaches you with the user's next message; your own shell is still the way for output you need now. " +
      "Where this thread's permission mode would ask before a command, OriCode asks the user in this thread first and the call waits for them.",
    inputSchema: { type: "object", properties: { command: { type: "string", description: "One shell line." }, reason }, required: ["command", "reason"] },
  },
  {
    name: "read_oricode",
    description:
      "Read what OriCode shows and how it's set: the thread open and the one beside it, whether the list, the review, a file, Everything Running or Heads is up, and every setting change_setting takes, with its value. It reads and changes nothing.",
    inputSchema: { type: "object", properties: {} },
    annotations: { readOnlyHint: true },
  },
];

export const menuToolNames = new Set(menuTools.map((tool) => tool.name));

/// A menu tool's act the user allows first: the app answers with `change`, the engine asks the user
/// in the thread with an Allow and a Deny, as a Mac ask is, and an Allow sends the act again.
export class UserAsks {
  private waiting = new Map<string, (allow: boolean) => void>();
  private threadId: string;

  constructor(threadId: string) {
    this.threadId = threadId;
  }

  async act(name: string, args: Record<string, unknown>): Promise<unknown> {
    const reason = String(args.reason ?? "").trim();
    if (!reason) throw new Error("Say why in `reason`, one line the user reads.");
    const first = (await this.send(name, args, false)) as { change?: string };
    if (typeof first?.change !== "string") return first;
    if (!(await this.ask(first.change, reason))) throw new Error(`The user didn't allow it: ${first.change}. Don't ask again in this turn unless they tell you to.`);
    return await this.send(name, args, true);
  }

  /// The turn ended with an ask still waiting: the call is gone, so the card is too.
  turnEnded(): void {
    for (const [requestId, settle] of this.waiting) {
      if (!asks.delete(requestId)) continue;
      event("ask.cancelled", { threadId: this.threadId, requestId });
      settle(false);
    }
  }

  private async send(tool: string, args: Record<string, unknown>, allowed: boolean): Promise<unknown> {
    try {
      return await askApp("oricode.act", { threadId: this.threadId, tool, args, ...(allowed ? { allowed: true } : {}) });
    } catch (error) {
      if (error instanceof Unanswered) throw new Error("OriCode took too long to answer. It may have done it, so read_oricode or list_threads before you try again.");
      throw error;
    }
  }

  private ask(change: string, reason: string): Promise<boolean> {
    const requestId = randomUUID();
    return new Promise((done) => {
      const settle = (allow: boolean) => {
        this.waiting.delete(requestId);
        done(allow);
      };
      this.waiting.set(requestId, settle);
      asks.set(requestId, { threadId: this.threadId, answer: ({ allow }) => settle(allow), stop: () => settle(false) });
      event("ask", {
        threadId: this.threadId,
        requestId,
        kind: "permission",
        tool: "OriCode",
        input: { change, reason },
        choices: [
          { id: "deny", name: "Deny", kind: "reject_once" },
          { id: "allow", name: "Allow", kind: "allow_once" },
        ],
      });
    });
  }
}
