# Changelog

Before 0.1.0, the first public release, a version was 0.0.N, where N was the number of its release card on KANBAN.md.

## v0.2.1 "Any folder" - 2026-09-29

- Any folder is a project now, git or not. Add Project used to refuse a folder without a `.git` and say so; it takes it, and the threads there run as anywhere else. The review, branches and worktree threads need git, so in a plain folder they answer "This folder isn't a git repository." in place of git's own error.
- Opening a new thread while the pointer rests on a reply's text no longer leaves the I-beam over the whole window until you go back to that thread.

## v0.2.0 "In company" - 2026-09-29

### Agents

- OriCode runs more than Claude Code now. Codex, Cursor, GitHub Copilot, OpenCode, Grok Build, Devin, Pi and Antigravity come in through their own CLIs and the logins you made for them in Terminal, which OriCode never reads. Z.ai, DeepSeek, OpenRouter and Meta run inside Claude Code on a key you keep in the Keychain, and Command Code runs its own `cmd` on a key or on `cmd login`.
- Settings › Agents lists every agent. Turn one on and its CLI is found the way Node is, or you choose the binary, and its row says it's signed in or gives the one Terminal line that would sign it in. A key goes from a secure field into your login Keychain and is handed only to the process that calls that API.
- Logins a maker keeps to its own apps, Antigravity with a Google account and Pi signed into claude.ai, xAI or Meta, are off until you turn them on under the maker's own sentence.
- Each agent shows its maker's own logo in its maker's own colour: Claude's orange, Copilot's purple, DeepSeek's blue, and white for the makers whose marks are black or white, like OpenAI and Cursor.
- The model menu folds each agent into one row that opens on a click, the agent you're on open. It shows only the models you've turned on in Settings › Agents, which has a search field and a switch for each model, and out of the box each agent's default and a few more, so OpenCode's and OpenRouter's hundreds wait there until you pick them.
- The model menu lists each agent's models under its name and mark, with favourites from all of them first. A new thread moves to another agent when you pick one of its models, and once it has begun it stays on its agent. Settings › New threads picks the agent new threads start on.
- Every agent whose CLI takes a reasoning level gets the effort rail with the levels it really has, OpenCode's variants among them.
- A thread can change agent whenever it isn't working: pick another agent's model and the thread moves, the new agent picking up with the conversation so far handed over, and a faint line in the transcript saying where it changed.
- A thread offers only what its agent can do. The effort rail, the permission tiles, fast mode, the usage glass and sending mid-turn go where the agent has no such thing, and Pi and Command Code say they run unsupervised.
- Codex's 30-day window fills the usage glass and the limit card. Continue in opens a thread's session in its own CLI in a block, for every agent that has a resume line, and the thread waits while it runs.
- A signed-out Claude Code no longer turns off the review, branches or ⌘K's git rows, and Retry after a login in Terminal doesn't restart the engine.
- Codex, Cursor and OpenCode have run real threads. The other agents and the model APIs are built to their makers' protocols and tested against stand-ins, and haven't had a real turn yet.

### Writing while it works, and the queue

- Return while a thread works sends what you typed into the running turn. It shows at once as your bubble, dimmed, with "Waiting for the next step" under it, and brightens when the agent takes it up after the step it's on. On an agent that can't take a message mid-turn, Return queues it instead.
- ⌥Return puts a message in the thread's queue for after the turn. Queued messages sit inside the composer above the field, a line each; a click or ↑ takes one back to edit, and its cross removes it. When a turn ends by itself the first goes out, and the rest follow a turn at a time.
- Stop sends nothing more. What was sent into the turn and what was queued come back into the field, oldest first, ahead of what's typed.

### Heads and Rays

- While a thread works, its mark sits at the title's left end. A click on it, or ⌘I, opens the heads: the main loop and what it's on, each agent with its step, time, tokens and tool calls, each workflow, and each background command with its last line, and Stop on the row under the pointer. A ray lights for each agent at work, never for a command.
- Each head is drawn in its agent's colour on the mark, the dot for the thread's own agent and a ray for each worker. Colour stays off everything else.
- Rays: a thread's head can send out workers on other agents, through tools OriCode serves it over MCP. Tap the mark in the picker, or press ↑ from the effort rail, and pick the models the head may hand work to, Opus as the head with GPT-6-Luna as its ray, say; each lights a ray on the mark in its agent's colour, and the head is told to use them without a word in your message. A worker that edits works in a worktree of its own, and the head merges what it keeps, which arrives staged in the review, credited to that worker's ray. Stop on the head stops them. Claude Code, Codex and the ACP agents that take MCP can be heads; Pi, Command Code, Antigravity and Grok Build can only be workers.
- Workflows are a switch of their own beside Fast, so any model runs them at any level: Sonnet at Medium fans a task out to agents that all run at Medium. On Claude Code, Extra high with workflows is its Ultracode; other agents fan out through Rays. Ultracode is no longer a stop on the rail, and a thread left at Ultracode comes back at Extra high with workflows on.
- A workflow a thread starts gets a card of its own: its phases, a bead for each agent, lit while it runs and red if it failed, and a click lists the agents.

### The plan card, and limits

- A plan the agent writes is a checklist card where it was first written: "3 of 7 done", the item in progress lit and saying what it's doing, done ones ticked and faint. Each update changes the card in place and leaves no line of its own.
- A thread a usage limit stopped shows a card with the limit's name, when it resets and a countdown, and a Go on when it resets switch. With it on, the thread goes on by itself after the reset. Settings › Conversation sets the default, on for the session limit.
- Near a limit, one faint line says so: "90% of the session used · resets in 1 hr 10 min". The usage glass follows the turn as it runs instead of waiting for it to end.
- A thread still working when OriCode quits picks up by itself at the next launch, with a line in the transcript saying why. One that was waiting on your answer comes back still waiting.

### The shell prompt and terminal blocks

- `!` at the start of the composer, or ⌘J, turns it into a shell prompt for the thread's folder: the `$` grows out of the composer's left end and the text turns to SF Mono. Return runs the command in a terminal of its own, and its block lands in the transcript in the terminal's colours, following the output, with Stop.
- The agent reads what your blocks printed since it last read them with your next message, so an error reaches it without pasting.
- A command still running once the transcript has scrolled past it is named under the composer, with Show and Stop.
- vim, less or anything else that takes the whole screen opens its block into a full terminal over the conversation and gives it back when it quits, and Open does the same for any running block. The old ⌘J terminal is gone.
- Tab completes what your own zsh would, `git che` and `npm run` included, listing several matches above the composer; with bash or fish it completes commands and paths. ↑ and ↓ bring back earlier commands.

### Search, links and the review

- ⌘K, ⌘P, the review and the heads grow out of the title capsule and fold back into it.
- ⌘K finds what was said. With two characters typed, a Messages section lists the messages and replies that hold every word, and Return opens the thread at that message.
- A file link in a reply opens the file in the viewer, at its line when the link names one.
- In the review an open file is one card with its hunks inside, and a click on its header folds it. The first look opens only the first file to review. Marking a hunk moves on to the next, opening the next file and folding the finished one, and a file's own circle marks all its hunks at once. ← and → fold and open, and ⌥-click on a chevron does it to every file.

### Shortcuts

- Settings › Shortcuts lists every shortcut and gives each another key, the menus' and the composer's Return, ⌥Return and ⇧Return included. A key that's taken is refused with what holds it, macOS keeps its own, and ⌘/ and the menus show your keys.

### Speed and size

- A long thread is as quick as an empty one. With 100 turns behind, a streaming reply costs 4.6ms a delta where it cost 26 and dropped most frames, switching to it takes 75 to 99ms instead of a quarter of a second, and it holds 77MB instead of 171.
- A key in the composer costs about 3ms whatever it holds, where 4,000 characters made it 20ms: the field is AppKit's own text view now.
- The engine is ready about 390ms after launch instead of 550.
- The picker, the rays' page, ⌘K, the drawer, the review and Settings open without skipping frames at the start, and Settings appears in about 60ms instead of 115.
- OpenCode lists its models with 5 processes and about 430MB instead of 17 and 1.75GB, model lists are kept, a git or probe that hangs is killed at a deadline instead of outliving the app, and a thread you only looked at lets go of its memory three minutes after you leave it.

- Launch starts one CLI where it started five, peaking under 125MB instead of over 900MB, and the engine is ready in 0.5 to 1.1 seconds where it took 1.1 to 1.5. A thread's CLI is let go 90 seconds after its turn instead of five or six minutes, and at once for a thread that isn't open while the window is hidden.
- In a folder with changes the app starts at 37MB instead of 57MB. The review is coloured only while it's shown and reads git with three processes instead of six.
- A running block with 10,000 lines redraws in 3ms instead of 19ms, and a finished block lets go of its terminal: twenty long commands cost 81MB instead of 660MB.
- The Release app is 11.0MB instead of 13.8MB, without the parts of Sparkle and Highlightr it never used.
- A streaming reply reaches the screen at most once a frame, about 5ms a delta where it was about 15 by the end of a long reply. ⌘K over 10,000 messages answers a key in 14ms instead of 1.5 seconds, and opening a long thread no longer holds up the window.
- The model page draws only the rows in view, so OpenCode's 397 models open in about 30ms instead of 0.9 seconds.

### Fixes

- On a question, the picked option is lit with a checkmark, the card's buttons light under the pointer, and Other is a field on the glass instead of a black box.
- Tab never takes the keyboard out of the composer, the next command can be typed straight after Return, and ⌫ in an empty prompt turns it back into the composer.
- A command that prints and exits at once keeps its last lines, on screen and in what the agent reads.
- An open block stays with its thread, and Return answers a waiting card after ⌘K or ⌘P.
- A block that ends while it's open puts itself back in the thread, and Close, ⌘J, a click on the transcript or one Esc each put an open block away.
- Settings' selected pane, dialogs' default buttons and switches that are on read with white words, and the review's buttons light under the pointer.
- Continue in can't open a second copy of a session already open in a block, and ⌘K and ⌘P draw over an open file.
- ⇧Return puts its new line where the cursor is.

## v0.1.0 "In the open" - 2026-09-24

- The first public release, and the first you can download. OriCode is a native macOS app for coding agents, and the agent it runs is Claude Code, the one you're already logged into; it never sees a key or a token.
- Review (⌘⇧D) shows every change in the project since the last commit, grouped by the turn that made it, with changes none of the thread's edits explain set apart. Mark hunks as you read them, take one back with ⌫ and bring it back with ⌘Z, leave Claude a note on a hunk, and commit only what you've reviewed.
- A terminal (⌘J) slides down over the glass in the thread's folder. ⌘K's Run in terminal… types a command into it, and Continue in Claude Code hands the thread to `claude` there.
- ⌘K is the command center: threads, projects, branches, models and efforts, and actions of your own, each a named command that runs in the terminal or quietly.
- The model picker is OriCode's mark over an effort rail. It lists every model Claude Code offers, older ones included, by version and with your favourites first, and knows each model's own default level, Ultracode, and fast mode, which shows as bubbles swirling in the mark.
- Threads live in a drawer that slides in from the window's left edge. ⌘B pins it, ⌘1–9 picks a thread, pinned threads stay in the order you put them, and ⌘⇧N starts a thread on its own branch.
- Usage is a glass beside the composer that fills as your plan's session window goes; hover it for every window and the thread's context.
- Claude's tool calls fold into one line per run, like "Ran 3 commands, read 2 files", which opens to the full list.
- The window is Liquid Glass, darkened as far as you like in Settings.
- OriCode updates itself. It checks GitHub once a day, and when there's a newer release, a circle beside the title fills as it downloads and then restarts OriCode into it.
- It's signed with OriCode's own certificate but not notarized by Apple, so macOS stops the first launch of a download; the README has the one command that opens it.

## v0.0.94 "Fast, the same every time" - 2026-09-23

- Fast mode says the same thing every time. OriCode keeps Claude Code's answer about fast mode for each model and asks as soon as the picker opens, so the bolt and its effects light only when Claude Code will run fast, and otherwise the bolt is struck through with the reason straight away, in every thread and before any thread starts.

## v0.0.92 "Fast you can see" - 2026-09-23

- The picker is the mark over the slider; the other two designs are gone.
- The Fast button lights up white on a lit circle once it's on, and fast mode shows in the picker: streaks run along the slider and through the mark, and the mark's head trails speed lines and darts forward as it comes on. When Claude Code turns fast mode down, the bolt is struck through and the line under the level says why.

## v0.0.90 "Mark and slider" - 2026-09-23

- B · Mark now has the slider under the mark: the mark shows how hard Claude is thinking, the dot growing and heating and the rays lighting at Ultracode, and the slider underneath sets it. Fast mode's button is always at the top left, dimmed on a model that can't go fast. A and C are still in Thread › Picker Design.

## v0.0.88 "Three pickers" - 2026-09-23

- The model button's picker is a card of the composer's own glass that rises out of the composer, instead of a system popover. It comes in three designs to try, switched in Thread › Picker Design: A · Slider, the level over the model with one slider; B · Mark, OriCode's mark, whose dot grows and heats as Claude thinks harder and whose rays light at Ultracode; and C · Columns, model, effort and permissions as three columns of words. One of them stays.

## v0.0.86 "Lit" - 2026-09-23

- Every effort level is lit. The rail is Claude's orange at full strength all the way down, so Low and Medium no longer look brown against the glass, and a little of the fill always shows beside the thumb at Low. Stops the fill has passed glow as lamps, the thumb is a warm bead that pales toward white as the level rises, and the level's name takes its colour.
- Every level arrives. Moving up sends light along the rail into the thumb, flaring each lamp it passes: a slug at Medium, a brighter one with embers at High, a sweep at Extra high. Moving down drains the heat back into the thumb. A held arrow key plays it once, for the level it stops on.
- Auto's icon is a shield; the sparkles belong to the rail now.

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
