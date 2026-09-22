# OriCode

A native macOS window for Claude Code. Swift and SwiftUI, one pane of glass, nothing on it but the conversation.

This file is the whole plan. There is no tracker, no roadmap doc and no design doc beside it. When something changes, it changes here.

## What this is

Claude Code's work with Codex's quiet. You open the app, the desktop shows through the window, you type, Claude answers, you approve what it wants to do, you read the diff. That's the product.

It is a personal client and a Swift learning project with a real spec. It is not trying to beat the official Claude Code desktop app on features; that app already has every panel a person could want. This one has almost none, on purpose.

## What this is not

Not an ADE, not an orchestrator, not a board of cards that run themselves. Not a web app, not cross-platform, not a phone app. Not a terminal, a browser or an IDE. When one of those seems necessary, open the official app for that task and come back.

## Rules that don't move

1. **Never hand-roll a control the platform already has.** `Picker`, `Toggle`, `Slider`, `Menu`, `List`, `TextField`, the `Settings` scene, `NSOpenPanel`, `UserNotifications`, native materials, the native window. The previous version of this app was a web view, and over a thousand lines went into redrawing dropdowns, toggles and window chrome that AppKit gives away. It still looked wrong. If a card starts to read as "build a custom X", the card is wrong; fix the card.
2. **No persistent panels.** The only things always on screen are the transcript and the composer. Threads, changes, files, settings: each slides over the same glass when called and leaves when done. Keyboard summons it, a click elsewhere or Esc dismisses it.
3. **The app never touches an Anthropic credential.** No API-key field, no token, no login screen. The engine runs the Claude Agent SDK, which uses the `claude` the user already logged into in Terminal. If that login is missing, the app says "run `claude` in Terminal and log in" and nothing more. The previous version settled on this as the line that keeps a personal client inside Anthropic's terms; keep it.
4. **One window, dark glass.** No light mode. The desktop's colour coming through the blur is the app's colour. Nothing in the interface has a border; surfaces come apart by tint and by space.
5. **Every card leaves a working build.** A card that ends with the app not launching is not done.

## How to work this board

Take the first card under **Todo**. Move it under **In progress** by editing this file. Build it. Check the *Done when* line by building and running the app (`make run`), not by reading the code. Move the card under **Done** with the commit hash. Commit as `K-NN: <card title>`, one card per commit. Do not start the next card while the build is red.

If a card turns out to be two, split it here before starting. If you learn something that changes a later card, edit that card now and say so in the commit message. If a *Done when* needs a human eye (K-10 does), build it, stop, and tell Meriç exactly what to look at.

Every time rule 1 is broken on purpose, add a line under **Exceptions** at the bottom with the reason. Two exceptions is a smell. Three means stop and re-read the rules.

## Design brief

The reference is the empty Codex window: a rounded pane of glass with the wallpaper's orange and violet visible through it, traffic lights top-left, a single mark in the middle, and no chrome at all. The test is whether the window still feels like that once a conversation is in it.

**Window.** Hidden title bar, full-size content, `titlebarAppearsTransparent`, `isMovableByWindowBackground` so any empty glass drags the window. Traffic lights stay where macOS puts them; nothing sits near them. Behind-window blur for the material, then one tint layer: black at 30% by default, the Settings slider moves it between 15% and 60%. Corner radius is the system's. Minimum size 720×480, default 1180×760.

**Surfaces.** Composer: white at 8% with a 1pt inset highlight of white at 12% along its top edge, which is what makes it read as raised glass rather than a different material. User message: white at 7%, radius 18, right-aligned, max width 560. Card (diff, ask): white at 5%, radius 14. Drawer: white at 6%, radius 14. Hover on a row: white at 7%. Selected row: white at 10%. That is the entire palette of surfaces.

**Ink.** System font. Body 14pt, secondary 12.5pt, monospace SF Mono 12.5pt. White at 92% for text, 55% for secondary, 30% for faint. Two colours carry meaning and nothing else does: a soft green for added lines and a soft red for deleted ones. No accent colour. A running thread shows a small spinning ring in the drawer, in white.

**Layout.** Transcript is a centred column, max 760pt wide, with 20pt side padding at narrower widths. The composer is a capsule at the bottom of that column, 16pt from the window's bottom edge, minimum height 48pt, radius 24pt, and it grows with the text up to 40% of the window. The send button is a 36pt circle at the capsule's right end; it becomes Stop while a turn runs. The model and mode picker is a small `Menu` at the capsule's left end showing the model's short name.

**The drawer.** The thread list is a drawer, not a sidebar. Closed, the window is only the conversation. Bring the mouse to the left edge and it slides in over the glass; move away and it slides back. Press ⌘1–9 and it slides in just long enough to show the thread you picked: that row lit and nudged 6pt to the right, the way one card stands proud of a drawer of index cards, then it slides back on its own. ⌘\ pins it open for people who want a list.

Numbers: 260pt wide, inset 12pt from the left, 40pt from the top (clear of the traffic lights), 12pt from the bottom. Hot zone 8pt at the window's left edge, 120ms before it reacts. Slide in 220ms ease-out, slide out 180ms ease-in, and it waits 400ms after the mouse leaves before going. The ⌘digit peek lasts 700ms after the keypress, or as long as the mouse is over it. Rows 34pt: state ring, title (single line, truncated), and the ⌘digit for the first nine. At its top, a `Menu` for the project with "Add project…" at the end; at its bottom, a New thread button.

**Motion.** `.spring(duration: 0.28, bounce: 0.12)` for anything that moves, `.easeOut(duration: 0.18)` for anything that appears or fades. Nothing bounces more than that. Nothing animates that the user didn't cause.

**Empty state.** A monochrome mark, 44pt, centred, at 55% white, and under it one line: "Where do we pick up?" for a project, "Add a project to start." with none. The mark is one Meriç supplies; a plain ring until then.

## Architecture

**App.** Swift 6, SwiftUI, macOS 26 deployment target (Liquid Glass materials). If the Mac turns out to be on macOS 15, drop the target to 15 and use `.ultraThinMaterial`; K-01 records the real numbers. The Xcode project is generated from `project.yml` with XcodeGen so the whole thing builds from the command line; `OriCode.xcodeproj` is gitignored and regenerated. A `Makefile` fronts everything: `make run`, `make engine`, `make test`, `make app`.

**Engine.** A TypeScript sidecar in `engine/`, built on `@anthropic-ai/claude-agent-sdk`. Node 24 runs TypeScript directly, so there is no build step: the app spawns `node engine/main.ts` and talks newline-delimited JSON over stdin/stdout. It ships inside the app bundle under `Contents/Resources/engine/` with its `node_modules` (`npm ci --omit=dev` at build time). The app finds `node` by asking a login shell (`zsh -lc 'command -v node'`), then `/opt/homebrew/bin`, `/usr/local/bin`, `~/.nvm/versions/node/*/bin`, and insists on 24 or newer; Settings can override the path. Read the SDK reference before writing a line of it; the shapes below are the app's protocol, not the SDK's.

**Data.** SwiftData. `Project { id, name, path, createdAt }`. `Chat { id, project, title, sessionId?, model?, effort?, permissionMode, cwd, createdAt, updatedAt }`, named `Chat` in code only because `Thread` is Foundation's; the interface says thread everywhere. `Event { id, chat, turn, seq, kind, payload: Data, createdAt }`, with `seq` ordering events that share a timestamp, where payload is the JSON of the wire event. Streaming text deltas are coalesced into one `text` event per assistant message, updated in place; never one row per token. If SwiftData fights back on something basic, GRDB is the fallback, decided in the card that hits it.

### Wire protocol

Requests from the app: `{"id": 7, "method": "...", "params": {...}}`. The engine answers `{"id": 7, "result": {...}}` or `{"id": 7, "error": "why"}`. Events from the engine carry no id: `{"event": "...", ...}`.

Methods:

- `hello` → `{ version, models: [{ id, name, description, efforts: [...] }], claude, loggedIn }`. `claude` is the path of the CLI the engine found (null when there is none) and `loggedIn` comes from `claude auth status`, so the app can tell the three failures apart without touching a credential. Models come from the SDK's supported-models call; if that isn't available, a list in `engine/models.ts` marked as a fallback.
- `send { threadId, sessionId?, cwd, text, model?, effort?, permissionMode, attachments? }` → `{ ok }`. Starts a turn; `sessionId` resumes an earlier one.
- `interrupt { threadId }` → `{ ok }`.
- `setMode { threadId, permissionMode }` → `{ applied }`. `applied` is false when the running turn can't take it and it will hold from the next one.
- `answer { requestId, allow, updatedInput?, answers?, message? }` → `{ ok }`. Resolves a pending `ask`.
- `close { threadId }` → `{ ok }`. Ends the thread's CLI process; the app calls it when a thread is deleted.

Events, each with `threadId`:

- `turn.started { sessionId }`
- `text { delta }`, `thinking { delta }`
- `tool.use { toolUseId, name, input }`
- `tool.result { toolUseId, content, isError }`
- `ask { requestId, kind: "permission" | "question", tool, input, options? }`. Permission asks come from the SDK's `canUseTool`; `AskUserQuestion` arrives the same way and is answered through `updatedInput`.
- `ask.cancelled { requestId }` when a pending ask stops waiting (interrupt, or the SDK gave up on it).
- `turn.done { sessionId, stopReason, durationMs, costUSD, usage: { input, output, cacheRead, cacheWrite }, context: { used, window } }`. `context.used` is the last request's prompt plus output, the number the meter in K-14 draws.
- `compacted` when Claude Code compacted the conversation.
- `error { message }`, and without a threadId when the engine itself is in trouble.

Permission modes are the SDK's: `default`, `acceptEdits`, `plan`, `auto`, `bypassPermissions`. The app names them Ask, Accept edits, Plan, Auto, Don't ask.

## Board

### In progress

(nothing yet)

### Todo: v0.1 "One window"

The version you can use as your daily Claude window. About a week and a half of evenings. If a card isn't needed to hold a real conversation with Claude in a glass window on your Mac, it isn't here.

#### K-06 · Composer
The glass capsule from the brief. `TextField` with `axis: .vertical`, placeholder "Ask for a change", Return sends, ⇧Return inserts a newline, the round button sends and turns into Stop (⌘.) while a turn runs. Sending writes the user event and calls `send` with the thread's cwd, model, effort and mode.
Done when: typing and pressing Return starts a turn, the button shows Stop while it runs, and Stop interrupts.

#### K-07 · Model and mode
The `Menu` at the capsule's left end: its label is the model's short name (and effort when set). Inside, native `Picker`s for Model (from `hello`), Effort (when the model has any), and Permission mode with a one-line description each: Ask "Edits and commands wait for you", Accept edits "Edits go through, commands ask", Auto "Claude decides what is safe", Plan "Reads and thinks, changes nothing", Don't ask "Everything goes through". Changing the mode mid-turn calls `setMode`; if it returns `applied: false`, a small "from the next reply" note under the capsule for two seconds.
Done when: switching model and mode changes what the next turn does, checked by watching the engine's stderr.

#### K-08 · Transcript
The 760pt column. User messages as bubbles on the right. Assistant text through MarkdownUI (the `swift-markdown-ui` package), themed to the brief: no coloured links, code blocks on a white-5% card. Streaming updates the last block in place. Tool calls as one quiet line each ("Read App/Engine.swift", "Edit engine/main.ts", "Bash: swift build"), 12.5pt at 55% white; click toggles the result underneath on a card, collapsed by default. Turn footer at 12.5pt: "Worked for 14s · $0.04". The transcript fades under the top edge and above the composer instead of ending at a line. Auto-scroll stays pinned to the bottom unless the user scrolled up.
Done when: a real turn that reads three files and edits one reads as prose with four quiet lines under it, and the window is as calm with a conversation in it as it was empty.

#### K-09 · Asks
An `ask` event renders an inline card at the bottom of the transcript: the tool, a short summary of its input (file path for edits, the command for Bash, the whole diff for edits behind a disclosure), and two buttons, Allow and Deny. Return allows, Esc denies, and only the topmost pending card listens. A `question` ask renders its options as buttons and a text field for "Other". Answers go back through `answer`; a deny includes a message so Claude knows.
Done when: in Ask mode, an edit waits on the card, Allow lets it through, Deny makes Claude say so and stop.

#### K-10 · The drawer
Exactly the drawer in the brief: hot zone, delay, slide in and out with those durations, the 400ms grace, ⌘\ to pin, and the ⌘1–9 peek with the row lit and nudged. Rows: state ring (idle, running, waiting on you), title, ⌘digit. Delete with a confirmation sheet. Project `Menu` at the top with "Add project…" (opens K-05's panel). New thread button at the bottom (⌘N).
Done when: this one is judged by eye. Build it, then stop and ask Meriç to move the mouse to the edge and press ⌘2, and to say what feels off. Iterate on the numbers, not the structure.

#### K-11 · Menu bar and Settings
Native `.commands` (K-05 already added File › New Thread ⌘N and Add Project… ⌘O, and a Threads menu with ⌘1–9, a Project submenu and Delete Thread; this card finishes the set): File › New Thread ⌘N; View › Threads ⌘\; Threads › 1–9 as ⌘1–9; Thread › Stop ⌘.; and the standard App › Settings… ⌘,. A native `Settings` scene with three tabs: General (Glass slider, Node path with Automatic / Choose…), Notifications (one toggle, wired in K-15; until then it says "Coming in 0.2"), About (version, a link to the repo).
Done when: every item in the menu bar works from the keyboard, and Settings opens as a real macOS settings window with the slider changing the glass live.

#### K-12 · Release v0.1
`make app`: Release build, ad-hoc code signature, copy to `/Applications`. `CHANGELOG.md` with a v0.1.0 entry written from the Done column. Tag `v0.1.0`.
Done when: OriCode is in the Dock, opened from there with Terminal closed, and holds a conversation with an approval in it.

### Backlog: v0.2 "See what it did"

#### K-13 · Diff cards
`Edit`, `MultiEdit` and `Write` render as a card per file: path, `+12 −3` in the two colours, and a unified diff in monospace with added and deleted lines tinted, collapsed to the header by default. The turn footer sums them: "3 files · +41 −9".
Done when: an edit turn shows exactly what changed without opening anything else.

#### K-14 · Meter
Usage from `turn.done` feeds a thin ring around the send button showing context used, and the footer's cost accumulates per thread in the drawer row's tooltip. If the SDK exposes compaction, a Compact item in the Thread menu; if it doesn't, the auto-compaction notice is shown as a quiet line and the card says so.
Done when: the ring grows across a long thread and the numbers match the engine's usage.

#### K-15 · Notifications and badge
`UserNotifications`: when a turn ends or asks while the window isn't key, one notification with the thread's title; clicking it opens that thread. Dock badge counts threads waiting on you. The Settings toggle from K-11 goes live.
Done when: start a long turn, switch to another app, and the notification arrives and lands you on the right thread.

#### K-16 · Titles
A thread's title is its first message, trimmed to 60 characters, until renamed. Double-click a drawer row to rename inline with a native `TextField`. The window's title is the thread's title.
Done when: ⌘-Tab shows which thread you're going back to.

#### K-17 · Resume
`turn.started` and `turn.done` carry a `sessionId`; the thread stores it, and the next `send` passes it. If the engine reports the session is gone, the thread continues fresh with a one-line note.
Done when: quit mid-conversation, relaunch, ask "what were we doing", and Claude knows.

#### K-18 · Thinking and effort
Optional "Thinking…" lines, collapsed, showing the delta stream when expanded. The Effort picker from K-07 gains the values the model supports and sends them.
Done when: `xhigh` visibly changes how long Claude thinks on a hard question.

#### K-19 · Edges
Engine crash mid-turn, `claude` not found, network gone, a project folder that moved: each a one-line note in the transcript in 55% white, never an alert or a modal. A thread whose folder is gone is greyed in the drawer with "folder missing" under the title.
Done when: pulling the network cable during a turn produces one calm line and the next turn works when it's back.

#### K-20 · Keyboard pass
An escape stack: Esc closes the topmost thing (drawer, ask, menu), and nothing else hears it. Everything in v0.1 and v0.2 reachable without the mouse; ⌘/ shows the shortcuts in a sheet.
Done when: a full session (add project, new thread, send, approve, switch thread, rename) is done with the trackpad unplugged.

#### K-21 · Release v0.2
As K-12. Tag `v0.2.0`.

### Backlog: v0.3 "Git"

#### K-22 · Capsule
A small glass capsule centred at the top of the window: project · branch · thread title, 12.5pt, the branch in monospace. It is the window's title made visible, and the only thing besides the traffic lights on the top row. Branch comes from `git rev-parse --abbrev-ref HEAD` in the thread's cwd, refreshed after every turn.
Done when: the capsule sits level with the traffic lights and never wraps.

#### K-23 · Changes
⌘⇧D slides a glass sheet over the transcript: changed files as a native `List` with `Toggle`s, a commit message box, Commit, Push. "Write message" asks the engine for one through a small Haiku query with the diff. Git runs through the engine so the app has no shell of its own.
Done when: a turn's edits are committed and pushed from the sheet, and the capsule's branch shows ↑1 until the push.

#### K-24 · A thread on its own branch
⌘⇧N: new thread on a new branch in a worktree under `.worktrees/<slug>/`; the thread's cwd is the worktree. Deleting the thread offers to remove the worktree when nothing on it is unpushed, and says what would be lost otherwise.
Done when: two threads edit the same file in parallel and neither sees the other's change until merged.

#### K-25 · Release v0.3
Tag `v0.3.0`.

### Backlog: v0.4 "Hands"

#### K-26 · Go to
⌘K: a glass sheet with a search field listing threads, actions and projects, fuzzy-matched, Return opens. Native `List`, keyboard-driven.
Done when: any thread is two keystrokes and a few letters away.

#### K-27 · Attachments
Paste or drop images into the composer; they show as small thumbnails in the capsule and go out as image content blocks.
Done when: a screenshot pasted into the composer is described by Claude.

#### K-28 · Files
⌘P: find a file in the project with fuzzy matching; open it read-only in a glass sheet with syntax colours from Highlightr, kept muted to the brief. A path in a tool line opens the same sheet.
Done when: clicking "Edit App/Engine.swift" in the transcript shows the file.

#### K-29 · Slash commands and skills
Typing `/` at the start of the composer lists the commands and skills the project and `~/.claude` define; picking one inserts it. Sent as text; the engine already understands them.
Done when: `/compact` from the composer compacts.

#### K-30 · Code colours
Syntax colours in the transcript's code blocks, muted: keyword, string, number, comment, name, and nothing else.
Done when: a Swift block reads as code and not as a rainbow.

#### K-31 · Release v0.4
Tag `v0.4.0`.

### Parking lot

Things that were once on the roadmap and are out on purpose. Each one stays out until there is a reason the official app can't serve.

- Remote control and a phone client: the official app does this.
- Linear or any tracker integration: this file is the tracker.
- Parallel heads and orchestration: Claude Code has subagents and worktrees; see K-24.
- Windows and Linux: the app is the Mac window.
- Light mode: the desktop is the theme.
- Terminal, browser and simulator panes: open the official app.
- Custom themes: the glass slider is the theme.

### Done

#### K-01 · Repo, skeleton, and the build that runs from a Makefile
`git init`, a three-line README, this file, `docs/reference.png` (the Codex screenshot; Meriç supplies it, and every design card looks at it first), and `CLAUDE.md` holding the five rules verbatim plus the four `make` targets and where things live (`App/`, `engine/`, `project.yml`). XcodeGen comes from `brew install xcodegen`. `project.yml` for XcodeGen with one app target, bundle id `com.realmeric.oricode`, and a pre-build script that runs `make engine`. An empty SwiftUI app. Record `sw_vers` and `xcodebuild -version` in the README and set the deployment target to what the Mac actually runs.
Done when: `make run` builds and opens an empty window with "OriCode" in the title, on a clean clone.
Notes: Builds go to ~/Library/Developer/OriCode, not build/: Documents is iCloud-synced and its FinderInfo xattrs make codesign refuse the bundle. Deployment target is macOS 26.0 on a Mac running 27.0. The engine skips the SDK's optional 208 MB bundled CLI and runs the user's own claude (see K-03).
Commit: 9c7de76

#### K-02 · The glass window
Hidden title bar, full-size content view, transparent title bar, `isMovableByWindowBackground`. Behind-window material as the window background and the tint layer over it, bound to an `@AppStorage("glass")` value defaulting to 0.30. Start with SwiftUI's `containerBackground(_:for: .window)`; if the desktop doesn't come through strongly enough, drop to an `NSVisualEffectView` with `.hudWindow` material and `.behindWindow` blending, and note which one won in the card. Centred mark and the empty-state line.
Done when: over a colourful wallpaper the window looks like the Codex reference: the wallpaper visible through it, the traffic lights alone at the top-left, no other chrome, and the window drags from any empty glass.
Notes: NSVisualEffectView won (.hudWindow, .behindWindow, state .active): SwiftUI's containerBackground material goes flat grey whenever the window isn't key. The default size uses defaultWindowPlacement; a stale saved window state had been hiding it. Needs Meriç's eye: screen capture of other apps isn't available to the agent, so the wallpaper through the glass and dragging from empty glass were not seen.
Commit: 5d14bef

#### K-03 · Engine: the sidecar
`engine/` with `main.ts`, the SDK, and a `tsconfig` used for checking only. Implements the wire protocol above end to end: `hello`, `send` with streaming (`includePartialMessages`), `interrupt`, `setMode`, `answer`, and every event. Tool calls, permission asks and `AskUserQuestion` go through `canUseTool`. `make engine` runs `tsc --noEmit` and `npm ci --omit=dev`.
Done when: from Terminal, `printf '{"id":1,"method":"hello"}\n' | node engine/main.ts` answers with the models, and a `send` for "say hi" against any git repo streams `text` events followed by `turn.done` with a cost. No app involved yet.
Notes: One long-lived SDK query per thread, fed from an open input queue, which is what lets setMode and interrupt reach a running turn. The engine runs the user's own claude (pathToClaudeCodeExecutable) and stages without the SDK's optional 208 MB bundled CLI, so the engine is 47 MB. The wire protocol gained hello's claude and loggedIn, a close method, ask.cancelled, compacted and turn.done's context; the Architecture section says so. make test covers the protocol without starting Claude.
Commit: 32d33e8

#### K-04 · Engine in the app
`Engine` actor: finds `node`, spawns the bundled engine, reads stdout line by line into `Codable` events on an `AsyncStream`, matches replies to requests by id, restarts on exit with a one-line note in the window ("Engine stopped. Retry."). Distinguishes three failures and says each plainly: no `node`, no `claude` login, engine crashed.
Done when: the app logs the `hello` reply at launch, and `kill`ing the node process from Terminal shows the note and Retry brings it back.
Notes: The engine strips inherited CLAUDE* variables before spawning the CLI: opened from inside a Claude Code session, the app inherited that session's environment and the child claude hung waiting for a host. The engine's stderr goes to ~/Library/Logs/OriCode/engine.log and the hello reply to the unified log (subsystem com.realmeric.oricode). Checked: kill shows "Engine stopped. Retry", Retry relaunches, and a v22 node override shows the no-node line.
Commit: 4327a6b

#### K-05 · Projects and threads
SwiftData models from the Architecture section. Add project through the native open panel, folders only; refuse anything without a `.git` and say why in the window, not in an alert. Create and delete threads; the current project and thread survive relaunch. No UI for the list yet beyond what K-02 shows; a temporary `Menu` in the empty state is fine for this card and K-10 replaces it.
Done when: add two projects, make a thread in each, quit, relaunch, and both are there with the last one selected.
Notes: A folder opened onto the app (Dock drop, or open -a OriCode <folder>) is added the same way as through the panel, which is also how the agent tests it. The menu bar got File › New Thread, Add Project… and a Threads menu early, because background tools can't open the in-window Menu; K-11 says so. Event gained a seq field.
Commit: pending


## Exceptions

Times rule 1 was broken, with the reason. Keep this short.

(none)
