// A thread that changes agent. The new agent's session has none of the old one's history, so the
// app hands over what the thread has said, and the engine puts it ahead of the first message in its
// own words. What the user sees in the transcript is only what they typed.

/// The most of a handover the engine passes on, a guard on the app's own cap; the oldest goes first.
export const handoverMax = 200_000;

/// The thread so far, as the app wrote it, in the words that tell the new agent what it is.
export function handed(thread: string): string {
  const kept = thread.length > handoverMax ? `[The start of the thread is left out.]\n${thread.slice(-handoverMax)}` : thread;
  return [
    "[Handover] This thread was on another agent until now, and you're picking it up. Below is what it said, copied by OriCode:",
    "what the user asked, what was answered, and each tool call as one line. You don't have that session's files or",
    "results open, so read a file again if you need its contents. Carry on from it. Don't repeat it back or mention this note.",
    "",
    "<thread>",
    kept,
    "</thread>",
    "",
    "The user's message follows.",
  ].join("\n");
}
