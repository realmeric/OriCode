# Changelog

Until the first public release, which will be 0.1.0, a version is 0.0.N, where N is the number of its release card on KANBAN.md.

## v0.0.83 "Heat" - 2026-09-23

- Max and Ultracode run hot. At Max, slugs of light glide along the rail and sink into the thumb as its glow breathes in, embers lift off the fill, and sparks fly off the thumb, born white-hot and cooling to Claude's orange. Arriving throws embers out of the thumb and draws them back in.
- At Ultracode a wheel of six jets of sparks turns with the rays, embers rise along the whole rail and the glow round the thumb is wider. When the motion ends the rays coast to rest upright instead of stopping wherever they were.
- Moving the pointer along the rail at Max or Ultracode keeps it going, and arriving there with the arrow keys gets the same entrance as a drag.

## v0.0.81 "Orange" - 2026-09-23

- The effort rail is Claude's orange instead of white: it deepens as effort rises, and its motes, streaks and halo glow warm.

## v0.0.79 "Feel" - 2026-09-23

- A new thread or ⌘W no longer drops the composer and the mark over the old conversation. The old transcript fades first, the composer glides up to the middle, and the mark settles in last; switching threads never shows two conversations at once.
- Default effort says where it lands. The model button names the level Claude Code will use, which is your own effortLevel when your Claude Code settings set one, and Settings › New threads can fix the model, effort, fast mode and permissions a new thread starts with, or keep following your last pick.
- The model picker is built around an effort rail. The thumb sticks to each level, settles with the speed of the drag, and writes the thread when you let go; the ringed stop is Default, and Back to Defaults shows what it will change before you press it. The models are a second page, opened from the model's name, and ⌘⇧M opens the picker.
- Ultracode, Claude Code's mode that runs multi-agent workflows on every task, is a stop past Max on the models that can run it, behind a gate so it isn't reached by accident. It stays with the thread it was picked in.
- Max and Ultracode get drifting motes and a halo, fast mode gets streaks, and the cost of the top two shows in your session's usage colour. It all runs in Core Animation, and only while the picker is open.
- The trackpad taps under a dragging finger: at each effort level, harder at Max and Ultracode, when something you drag can drop into the composer, and when Tint or Transparency passes its default.
- Send turns into Stop in place, a message you send rises out of the composer, and a permission card folds into its one line when you answer it.

## v0.0.74 "Lighter" - 2026-09-23

- OriCode is 7.4MB instead of 65MB. The engine carries only the Agent SDK file it runs, and the app is built for Apple silicon without its symbols.
- It only works as hard as Claude does. The turning rays, the waiting pulse and the usage circle's arc run in Core Animation, so a turn no longer costs a tenth of a core just to animate. App Nap is held off only while a turn runs, and a thread's Claude Code process closes after five idle minutes or when you close the thread, then resumes with its next message.
- ⌘W closes the open thread first and the window after that.
- Tint and Transparency each have a Default button.
- The model picker has more life in it: an effort meter, a Fast chip, tiles for the permission modes, and highlights that glide between choices.
- The repository is ready to go public, with an MIT license, a README and third-party notices.
- Versions stay under 0.1.0 until the first public release, so the releases so far are now 0.0.12 to 0.0.61.

## v0.0.61 "Projects" - 2026-09-23

- Threads from every project share the drawer's list, each starting with its project's badge: the first and last letters of the name on a colour the project gets at random. An Add project button sits at the top of the list.
- A double-click on the top row zooms the window the way a title bar does, and clicking the title pill opens Go to.
- Settings has Transparency beside Tint. Tint makes the glass lighter or darker; Transparency lets the desktop through sharp instead of frosted. AltTab and other window captures now show the glass dark, and name the window OriCode.
- The model button opens a picker of the app's own: the models, effort, the permission modes, and fast mode for the models that have it, with the reason when Claude Code can't serve it.
- The composer stands further out from the glass, and the drawer opens from a wider strip at the window's left edge.

## v0.0.49 - 2026-09-23

- The paperclip and the model menu light up under the pointer, like the app's other buttons.
- The model menu and the usage card show Claude's own logo, in Claude's orange.

## v0.0.46 - 2026-09-23

- The traffic lights come down to the title pill's line, with the sidebar button beside them, and sit inside the thread list's first row with room around them instead of in its corner.

## v0.0.44 "Settings" - 2026-09-23

- Settings is a glass window like the rest of the app: a sidebar of panes with the traffic lights in it and a search field that narrows the panes to what you type, and each pane's settings in cards under headings.
- General gains a New threads card that sets the permission mode a new thread starts in; Shortcuts lists every shortcut.
- The title pill sits a little lower, under the traffic lights rather than level with them.

## v0.0.41 "Rays" - 2026-09-23

- The mark is a dot inside six arcs, and the app icon is the same drawing. Each lit arc is a head at work in the thread: the main loop, then each subagent, in the foreground or the background, up to six. The drawer's rows show them.
- A sidebar button sits right of the traffic lights. Hovering it opens the thread list the way the left edge does, clicking it pins the list, and so does cmd-B. The list runs the window's full height with the traffic lights inside it, and while it's pinned the conversation moves over for it. Its foot has New thread and a Settings gear.
- The composer sits in the middle of an empty thread and slides down with the first message. It reads left to right as text, attach, the model and its effort, the usage circle, send, and it sits higher off the bottom edge.
- The usage circle shows how much of your Claude plan's session window is gone, in green, amber or red, with a thin arc turning inside it while the thread works. Hovering it lists every window with when it resets, and this thread's context. It asks your own claude, so the app still never reads a token.
- Turns no longer show how long they took or what they cost unless Settings › Transcript asks for it; what they changed still shows.
- Settings sits on the same glass as the window, in cards, and the system's blue is gone from the app.

## v0.0.31 "Hands" - 2026-09-22

- cmd-K opens Go to: threads from every project, the projects and the app's actions, fuzzy-matched; arrows move and Return opens.
- Paste an image, drop one on the composer, or open one onto the app, and it goes out with the next message. The transcript keeps a small preview of what you sent.
- cmd-P finds a file in the project and opens it read-only with muted syntax colours, and a path in a tool line or a diff card opens the same view.
- Typing / at the start of a message lists the project's and your own commands and skills; Tab or Return completes one.
- Code blocks in the transcript are coloured the same muted way: keywords, strings, numbers, comments and names, nothing else.
- The engine's replies no longer wait in the pipe until it next writes a log line, which was behind the turns that seemed to stall at random, and a turn's cost after a relaunch is its own cost, not the session's running total.

## v0.0.25 "Git" - 2026-09-22

- A capsule at the top of the window, level with the traffic lights, shows the project, the branch and the thread, with ↑ and a count when there are commits to push.
- cmd-shift-D opens Changes over the transcript: the changed files with a checkbox each, a message box, Write message (a small Haiku call over the diff), Commit and Push. Git runs in the engine, never in the app.
- cmd-shift-N starts a thread on a new branch in its own worktree under .worktrees/, so two threads can edit the same file without seeing each other. Deleting one offers to remove the worktree, and says what would be lost when there is something to lose.
- Long transcripts show their latest 200 items with a button for the rest, and no longer come up blank at launch; replies that arrived as one piece are no longer lost from the store.

## v0.0.21 "See what it did" - 2026-09-22

- Edits, multi-edits and writes show as a card per file with its added and deleted counts, opening onto the diff Claude applied, and each turn's footer adds up the files and lines.
- A thin ring around the send button shows how full the thread's context is, the drawer row's tooltip shows what the thread has cost, and Thread › Compact compacts it.
- When a thread finishes or waits on you while you're elsewhere, you get one notification, and clicking it opens that thread. The Dock icon counts threads waiting on you.
- A thread is titled by its first message until you rename it: double-click its row, or cmd-R. The window's title is the thread's.
- Threads pick up their Claude session after a relaunch, and one whose session is gone says so and carries on in a new one.
- Thinking shows as one folded line with Claude's summary inside, and the Effort picker offers each model's own levels.
- A dropped network, a crashed engine, a missing claude or a moved project folder each get one quiet line, never an alert; a thread whose folder is gone is greyed in the drawer.
- Everything works from the keyboard: model and permission pickers in the Thread menu, delete with cmd-delete, Esc closes whatever is on top, and cmd-/ lists the shortcuts.

## v0.0.12 "One window" - 2026-09-22

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
