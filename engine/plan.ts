// A project's plan, kept by agents through these tools and by the user on ⌘⇧I's screen. The app
// stores it beside the project's threads, so every call goes to it as an event and waits on its
// `app.reply` (threads.ts's askApp); the engine keeps none of it. A task is named T1, T2 and on,
// in its project, for as long as it's there.

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
    "Write a plan when the work has parts, above all parts that wait on others: every part as a task, with what done means and what it waits on. Returns each task with its id.",
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
          },
          required: ["title", "done"],
        },
      },
    },
    required: ["tasks"],
  },
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

export const planTools = [readPlan, addTasks, claimTask, updateTask];

/// The task a thread works, ahead of each message that starts one of its turns while the task
/// isn't done, so a thread opened for a task knows it from its first word.
export function taskLead({ id, title, done }: { id: string; title: string; done?: string }): string {
  return `[OriCode] This thread works ${id} of the project's plan, "${title}".${done ? ` Done means: ${done}` : ""} Keep it with update_task as you go: a short note at each step that matters, and the state done once it's done, or stuck, with why, when you can't go on. read_plan shows the plan.`;
}
