// A project's plan, kept by agents through these tools and by the user on ⌘⇧I's screen. The app
// stores it beside the project's threads, so every call goes to it as an event and waits on its
// `app.reply` (threads.ts's askApp); the engine keeps none of it. A task is named T1, T2 and on,
// in its project, for as long as it's there.

import { progressLine } from "./progress.ts";

const task = { type: "string", description: "The task, by its id in the plan, T3, or by its title." };
const waitsOn = {
  type: "array",
  items: { type: "string" },
  description: "The tasks it can't start before, by id, T1, or by title; a task added in the same call by its title.",
};

export const readPlan = {
  name: "read_plan",
  description:
    "Read the plan of the project this thread is in, its latest done tasks and every one not done, and what the user sees on OriCode's screen of everything running: each other project's tasks not done, every thread working or waiting now in any project with what it's on, and every ask waiting on the user. " +
    "A task has an id, its title, what done means, the tasks it waits on, the thread working it, its state and its note. Its state is waiting (on tasks not done yet), ready, working, done or stuck. " +
    "It reads and changes nothing.",
  inputSchema: { type: "object", properties: {} },
};

export const addTasks = {
  name: "add_tasks",
  description:
    "Add tasks to this project's plan, which the user watches on OriCode's screen of everything running and every thread can read with read_plan. " +
    "Write a plan when the work has parts, above all parts that wait on others: every part as a task, with what done means and what it waits on. Returns each task with its id. " +
    "With `run`, OriCode runs them for you: each task starts as a thread under this one, sent its `message`, as soon as every task it waits on is done and that task's worktree, if it had one, is merged into your folder; a thread whose turn ends has its task done and its last reply as the result, and one that's stopped or stuck stops what waits on it. " +
    "No more threads work at once than the user allows; the rest start as others end. Wait for them with wait_plan, and bring each worktree's work in with merge_thread as it comes back.",
  inputSchema: {
    type: "object",
    properties: {
      tasks: {
        type: "array",
        items: {
          type: "object",
          properties: {
            title: { type: "string", description: "A few words saying what the task is: Write primes.py." },
            done: { type: "string", description: "What done means for it, one line someone can check: primes.py prints the first twenty primes." },
            waitsOn,
            message: { type: "string", description: "With `run`: its thread's first message, written for someone who hasn't seen this conversation: what to do and what to say when it's done. Name files by their path inside the project, never your folder's full path: a task with a worktree works in its own copy of your folder, and an edit by your folder's path would land in yours, outside its branch." },
            agent: { type: "string", description: "With `run`: the agent its thread runs on, by its id, such as claude or codex. Yours when left out." },
            model: { type: "string", description: "With `run`: a model of that agent's, by its id. Yours when left out, or on another agent its first." },
            effort: { type: "string", description: "With `run`: the model's effort level, such as low or high. Yours when left out and the model has it." },
            worktree: { type: "boolean", description: "With `run`: its thread works on a branch in a worktree of its own, started from your folder as it is then, so its edits can't run into another's. Give one to each task that edits files while another does." },
            reason: { type: "string", description: "With `run`, when you choose the models: why this model at this level for this task, one line the user reads." },
          },
          required: ["title", "done"],
        },
      },
      run: { type: "boolean", description: "Run these tasks as threads under this one, each once what it waits on is done." },
    },
    required: ["tasks"],
  },
};

export const waitPlan = {
  name: "wait_plan",
  description:
    "Wait for a task of the plan you run with add_tasks' `run` to end, and get each that ended since you last asked: done with its thread's last reply, or stuck with why and the tasks that won't start because of it. " +
    "A done task whose thread worked in a worktree says `merge`: bring its work in with merge_thread, since the tasks waiting on it start only once it's in. " +
    "Answers at once when a task has ended unheard, and otherwise waits up to five minutes. As wait_thread does, it answers at once with `asks` when a thread you set going asks you something. `planDone` says every task you run is done.",
  inputSchema: { type: "object", properties: {} },
};

export const claimTask = {
  name: "claim_task",
  description:
    "Take a task of the plan for this thread: it becomes the task's thread and the task is working. A task that waits on tasks not done yet, or that another thread is working, can't be taken. " +
    "A thread opened with open_thread's `task` has its task already.",
  inputSchema: { type: "object", properties: { task }, required: ["task"] },
};

export const updateTask = {
  name: "update_task",
  description:
    "Change a task of the plan. The thread working a task keeps it as it goes: a short note at each step that matters, then the state done once what done means holds, or stuck, with why in the note, when it can't go on. " +
    "Any thread may change any task: ready reopens a done or stuck one, taking it from its thread. Leave `task` out for the one this thread is working.",
  inputSchema: {
    type: "object",
    properties: {
      task,
      state: { type: "string", enum: ["working", "done", "stuck", "ready"], description: "working takes it for this thread, as claim_task does." },
      note: { type: "string", description: "Where it stands, one or two lines the user reads under the task: Tests written, two of five pass." },
      waitsOn: { ...waitsOn, description: "The tasks it waits on now, in place of the ones it did." },
      title: { type: "string" },
      done: { type: "string", description: "What done means for it." },
    },
  },
};

export const planTools = [readPlan, addTasks, claimTask, updateTask, waitPlan];

/// The task a thread works, ahead of each message that starts one of its turns while the task
/// isn't done, so a thread opened for a task knows it from its first word.
/// A task the plan runs is done when its thread's turn ends, so its thread is told to end it with
/// what it did.
export function taskLead({ id, title, done, run }: { id: string; title: string; done?: string; run?: boolean }): string {
  return `[OriCode] This thread works ${id} of the project's plan, "${title}".${done ? ` Done means: ${done}` : ""} Keep it with update_task as you go: a short note at each step that matters, and the state done once it's done, or stuck, with why, when you can't go on. read_plan shows the plan.${run ? " The plan runs by itself: when your turn ends the task is done, and your last reply is its result, which the thread running the plan reads, so end with what you did and how it went." : ""}`;
}

/// How far a plan that runs is, in progress.ts's words for the line its owner shows: "2 of 5
/// done · about 12 min left". The app keeps the plan and asks with `plan.progress`: `kinds` is each
/// task's agent, the done ones first in the order they ended, `ended` when each of those ended, in
/// seconds. Tasks run side by side, so the time between two endings stands for a step, as a
/// workflow's agents' does.
export function planProgress(kinds: string[], began: number, ended: number[], now: number): string {
  return progressLine(kinds.map((kind) => ({ kind, guess: 1 })), began, ended, now);
}
