# Changelog

## v0.4.0 "Hands" - 2026-09-22

- cmd-K opens Go to: threads from every project, the projects and the app's actions, fuzzy-matched; arrows move and Return opens.
- Paste an image, drop one on the composer, or open one onto the app, and it goes out with the next message. The transcript keeps a small preview of what you sent.
- cmd-P finds a file in the project and opens it read-only with muted syntax colours, and a path in a tool line or a diff card opens the same view.
- Typing / at the start of a message lists the project's and your own commands and skills; Tab or Return completes one.
- Code blocks in the transcript are coloured the same muted way: keywords, strings, numbers, comments and names, nothing else.
- The engine's replies no longer wait in the pipe until it next writes a log line, which was behind the turns that seemed to stall at random, and a turn's cost after a relaunch is its own cost, not the session's running total.

## v0.3.0 "Git" - 2026-09-22

- A capsule at the top of the window, level with the traffic lights, shows the project, the branch and the thread, with ↑ and a count when there are commits to push.
- cmd-shift-D opens Changes over the transcript: the changed files with a checkbox each, a message box, Write message (a small Haiku call over the diff), Commit and Push. Git runs in the engine, never in the app.
- cmd-shift-N starts a thread on a new branch in its own worktree under .worktrees/, so two threads can edit the same file without seeing each other. Deleting one offers to remove the worktree, and says what would be lost when there is something to lose.
- Long transcripts show their latest 200 items with a button for the rest, and no longer come up blank at launch; replies that arrived as one piece are no longer lost from the store.

## v0.2.0 "See what it did" - 2026-09-22

- Edits, multi-edits and writes show as a card per file with its added and deleted counts, opening onto the diff Claude applied, and each turn's footer adds up the files and lines.
- A thin ring around the send button shows how full the thread's context is, the drawer row's tooltip shows what the thread has cost, and Thread › Compact compacts it.
- When a thread finishes or waits on you while you're elsewhere, you get one notification, and clicking it opens that thread. The Dock icon counts threads waiting on you.
- A thread is titled by its first message until you rename it: double-click its row, or cmd-R. The window's title is the thread's.
- Threads pick up their Claude session after a relaunch, and one whose session is gone says so and carries on in a new one.
- Thinking shows as one folded line with Claude's summary inside, and the Effort picker offers each model's own levels.
- A dropped network, a crashed engine, a missing claude or a moved project folder each get one quiet line, never an alert; a thread whose folder is gone is greyed in the drawer.
- Everything works from the keyboard: model and permission pickers in the Thread menu, delete with cmd-delete, Esc closes whatever is on top, and cmd-/ lists the shortcuts.

## v0.1.0 "One window" - 2026-09-22

The first version you can use as a daily Claude window.

- One pane of dark glass: hidden title bar, the desktop blurred through a tint you set in Settings, and the window drags from any empty glass.
- The engine is a node sidecar on the Claude Agent SDK. It runs the `claude` you already logged into in Terminal and never sees a credential. When node, the CLI or the login is missing, the window says which in one line, and a crashed engine comes back with Retry.
- Projects are git folders added through the open panel or dropped on the Dock icon. Threads keep their transcript, model, effort and permission mode across relaunches.
- The composer is a glass capsule: Return sends, shift-Return breaks the line, and the send button turns into Stop (cmd-period) while a turn runs.
- A menu at the capsule's left end picks the model, the effort and the permission mode: Ask, Accept edits, Auto, Plan or Don't ask.
- The transcript is a centred column of Markdown with each tool call as one quiet line that opens onto its result, and a footer with the time and cost of each turn.
- Claude waiting on you is a card in the transcript: Allow or Deny for tools, with the diff behind a disclosure for edits, and buttons plus an Other field for questions. Return allows and Esc denies.
- Threads live in a drawer that slides in from the left edge, peeks on cmd-1 to cmd-9 and pins with View › Show Threads.
- A native menu bar and a native Settings window with General, Notifications and About.
