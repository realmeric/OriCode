# Changelog

Before 0.1.0, the first public release, a version was 0.0.N, where N was the number of its release card on KANBAN.md.

## v0.5.0 "Watching over" - 2026-10-20

### Threads that run threads

- An agent does to your threads what you can. It opens a thread when it judges the work wants one, without being asked and with no limit of three a turn, and a thread it opened can open its own. It can send any thread a message, wait for a thread's turn to end and get its last reply, and stop one. So a thread handed a task in two parts that don't depend on each other gives each part a thread, waits on both and brings back what they did. Every open, message and stop takes a one-line reason, which is a line in both threads' transcripts, and a click on that line opens the other thread beside. A thread takes no message from one in a tighter permission mode than its own, so a thread on Plan can't have one on Don't ask make the edits it may not; it can open one in a tighter mode than its own, on Ask under a thread on Accept edits, say. What you don't want an agent to do with threads goes in the project's CLAUDE.md or AGENTS.md, which it reads. Agents besides Claude Code are reminded ahead of each message that starts a turn to give independent parts threads of their own, since told once in their instructions they mostly didn't. Pi, Command Code and Antigravity take no MCP tools, so their threads can be opened, messaged and stopped but do none of it themselves.
- Threads working at once, in Settings › Agents, caps how many threads can be working before an agent can't set another going: six unless you change it, from 1 to 20. Your own threads count toward it, and what you send yourself always goes.
- The drawer is a tree. A thread another opened sits folded under the thread that opened it, a shade quieter, and the opener says under its title how many below it are working. Only top rows can be dragged; a thread under another has no ⌘ digit and no pin, and keeps the order it was opened in. Archiving a thread takes every thread under it, and is refused while any of them works; Restore brings back the ones that went with it. Opening a thread from ⌘K, from a line in another thread or from a notification unfolds every thread above it. An agent is asked to title a thread it opens with what the thread does, "Write and run primes.py" where it used to write "primes.py".
- A thread another opened tells it when its first turn ends, "Tests finished its first turn". When a usage limit ended that turn and the thread goes on by itself at the reset, the line says it waits, "Tests is waiting on the session limit, which resets at 14:00", and the turn after the reset gives the ordinary line. A first message the engine refused, or a wait called off, by Continue in, by Go on when it resets switched off, or by a reset the thread can't go on from, tells the opener at once that it stopped.
- A thread whose turn is over while something it started still runs, a workflow, an agent, a background command or a task thread of a plan it runs, says so in one quiet line in its drawer row, on ⌘⇧I and at the top of its composer: "review · 1 of 3 done · about 20 min left · goes on when it ends". A workflow's line counts its agents done and gives the time left, worked out from how long this run's agents took; a plan's counts its tasks done and gives no time. On Claude Code, the turn that work's end wakes opens with a note saying what woke it, "The workflow review finished, so the thread goes on." A plan task's thread stopped by a usage limit it will wait out stays working, its task waiting on the limit, instead of turning stuck, and when it goes on at the reset the thread running the plan hears it. Nobody has seen the line in a window, on a real workflow, or a real limit and reset; only the tests checked it.
- A Claude Code workflow's agents, a Claude thread's Task subagents and a head's workers are threads under the thread that started them, read-only. Opened, one shows its transcript live: a workflow agent's and a subagent's read from the file Claude Code writes, only while the thread is on screen, and a worker's from what the engine already hears. When one ends it stays folded under its thread with the first line of what it returned, or Failed or Stopped, and it goes when that thread is archived. A subagent or a worker can be stopped alone. A workflow's agent can't: Claude Code has no way to stop one agent of a workflow, so the Stop in an agent's thread is Stop workflow, which stops all of them, and the thread says so. Archiving or deleting one is refused while it works. One at work when OriCode quits reads Stopped, and a worker's thread is never picked up again after a quit.

### What you do, an agent does

- An agent does in OriCode what you do from its menus, ⌘K and Settings, with tools named as those name them. It renames, archives, restores and pins a thread, puts one beside the open thread or takes it away, and brings up the review at a file and line, a file, ⌘⇧I, ⌘I's heads, the drawer, a Settings pane or the keyboard shortcuts, so "look at this" points at the thing itself. It changes a thread's model, effort, fast mode, Workflows and permission mode, changes a setting by the name read_oricode lists it under, adds a folder as a project, runs a command in a terminal block in its thread for you to watch, and reads which thread is open, what's beside it, what's up and how every setting it can change is set. Each act is a quiet line in the thread that asked, with its reason.
- Tightening is the agent's call and loosening is yours. A looser permission mode, a higher Spend per thread or none, more Threads working at once, Threads answer first turned on, a looser mode for new threads, or a command where the thread's mode would ask, comes to you as an ask in the thread, "Set this thread's permission mode to Auto, from Ask?", with the agent's reason under it, and no thread can answer it for you. Deleting a thread puts OriCode's own confirmation in front of you, and the thread goes only if you confirm. No tool reads or changes a login, an API key, an agent's CLI, MCP servers, shortcuts, actions or the switch for seeing and using the Mac. Pi, Command Code and Antigravity take no MCP tools, so they don't get these. No real agent has called them yet, and nobody has watched one act in a window; only the tests checked them.

### A plan the agents keep

- Each project has a plan, kept by the agents. A thread handed work whose parts wait on each other writes every part as a task, with what done means, what it waits on and the first message its thread is sent, and the plan runs itself. Each task starts as a full thread under the thread that wrote it, in a worktree of its own when it asks for one, as soon as every task it waits on is done and, from a worktree, merged into its folder, and never past Threads working at once. The thread running the plan waits on it, merges each task's work as it comes back and brings the results together; when it isn't working it's sent what ended. The line in its transcript says why each task opened: "Opened Write WORDS.md · T4 of the plan, now that T2 is done".
- A task's thread is an ordinary thread you can write into and stop. When its turn ends by itself the task is done and its last reply is the result. Stopped or failed, the task is stuck, and the thread running the plan gets a line naming what won't start because of it. Writing into a stuck task's thread takes the task up again, so what waits on it goes on once it finishes; Reopen starts it over in a new thread. Stop on the thread running the plan holds the rest of it, across a relaunch too, until that thread works again.
- A thread working a task is told so ahead of each message until it's done, and keeps a short note on it as it goes. Any thread reads the plan in one call, with every other project's, every thread working in any project and every ask waiting on you. The plan is stored with the project's threads and is there after a relaunch.
- On ⌘⇧I each project's plan stands above its threads while a task of it isn't done or has changed since OriCode opened: each task with its state, its thread and its note as they change, "Waits on T2 (stuck)" or "Starts once T1 is merged" where it waits, and past six done tasks only the latest three. A click opens a task's thread, and under the pointer a task can be stopped, reopened or deleted, as VoiceOver's actions on the row and ⌘K's Stop, reopen or delete a task can.
- A worktree opened for a thread, by a plan or by open_thread, starts from its opener's folder as it is, uncommitted edits and work merged before included, so a task that waits on another starts with what that one made. Those files are uncommitted in the worktree, so a push of its branch carries none of them unless someone commits them there.

### Work comes back together

- A thread that edits files while another does works in a worktree, and once its turn is over the thread that opened it merges it back. What's uncommitted in the worktree goes onto its branch, git merges the branch into the opener's folder as it stands, and the files arrive uncommitted beside the opener's own edits, for the review; nothing in the opener's folder is committed or staged. A conflict leaves the merge open with git's markers in the files and gives the agent each conflict's two sides, and it settles them, asks you which to keep, or takes the merge back, which writes every file the merge touched back as it was. A file one side deleted, or a binary one, has no markers, so the merge waits until the agent names the side it keeps. A merge still open when the turn ends, or when OriCode quits, is taken back. A thread on Plan merges nothing, and a thread in a looser mode than its opener's isn't merged into it.
- Both transcripts say what came in, "Merged Rename sum to plus · 1 file, +2 −2". The worktree and its branch then go, and the merged thread works in its opener's folder from then on, unless the worktree holds a file git ignores that the opener's folder lacks or has otherwise, in which case it stays and the agent is told which.
- When two threads at work edit the same file, each gets a line naming the other, "sum.py: Docs is editing it too", and so does the thread that opened them. Only an edit made with an agent's edit tool is seen; a file a command changes isn't.
- A head's merge of a worker is the same merge, so a worker's changes arrive uncommitted where they used to arrive staged. Committing what's left in a worktree no longer runs the repository's hooks or signing, so a failing pre-commit hook doesn't stop a merge.

### A thread answers for the threads it opened

- What a thread asks goes first to the thread that set its turn going, while that thread's own turn runs, instead of to you. It allows only what its own permission mode would have done without asking you: on Don't ask anything; on Accept edits or Auto an edit whose every file is inside its own folder or the asking thread's, in the same project, links followed; on Ask or Plan nothing. It answers a question from what it knows, denies with a reason the asking agent hears, or passes the ask up with a one-line reason, to the thread above it and from the top to you, where that reason sits over the ask. Each answer is a line in both threads, "Allowed for Rename: Edit sum.py · reason".
- Until an ask reaches you it isn't in ⌘⇧I's queue, the drawer's count, the Dock badge or a notification, but the asking thread's card says who has it and you can answer it there yourself. It comes up by itself when the holder's turn ends, when the holder hasn't read it within 30 seconds, or when it hasn't answered within two minutes of reading it. Seeing and using the Mac, the plan a thread on Plan asks you to start on, and what a worker, subagent or workflow agent asks are always yours, as are asks from before a quit.
- Threads answer first, in Settings › Agents, is on unless you turn it off; off, every ask comes straight to you.

### Everything running, on one screen

- ⌘⇧I, also in the View menu and as ⌘K's Show everything running, puts every thread that works, waits or has had a turn since OriCode opened on one screen, in every project, in the drawer's tree, with workflow agents, subagents and workers under their threads. Each row says whether it's working, waiting, done, stopped or failed, and what it's on now: a thread's current step, or a workflow agent's last tool, which moves when Claude Code's report does, about every ten seconds. A row whose turn has ended shows the first line that turn wrote, its Markdown read as words. A click opens the thread and puts the screen away, ⌥-click opens it beside, and Stop is on a working row under the pointer. The composer under the screen still writes to the open thread, and with none open starts a new one. Esc, a click on the glass or another surface puts it away. A thread nothing touched since OriCode opened isn't on it; the drawer lists those. Closed, the screen costs nothing.
- At its top is every question and permission waiting on you, oldest first, each under the thread that asks, a worker's or a subagent's own included, and answered right there without opening it. The notification for an ask names the asking thread, and its click opens the screen on that ask. In the drawer a row says how many asks wait at it and under it, the Waiting on you filter lists the thread that asks rather than the head waiting for it, and the Dock badge counts asks, not threads.

### Heads that choose

- With Heads choose on, in Settings › Agents, which it is unless you turn it off, a thread's head picks who does the work itself. It's told every model the model menu shows on each ready agent, with their levels and the plan windows its CLI reports, and it writes the parts as a plan that runs, each task on a model at a level it names, with a reason, and each started as a full thread under it. It moves its own model and level too, up before a hard part and back down after, each move a line in the transcript: "Now at high effort · Cross-file review needs careful judgment". On Claude Code the move takes in the running turn, on other agents from the next one. Rays you pick go to it as the ones to lean to. With Heads choose off, or with workflows on, a head works on the rays picked for it and stays where you put it.
- While it chooses, the model button says Choosing where the level and the rays' marks were, and its help says where the head is now. ⌘I lists what it chose under what's at work: each task's or worker's model, level and title with its reason, and each move of its own with why, the latest eight with a count of the earlier ones.
- Spend per thread, from $0.50 to $20, stops a thread's head and its workers once the thread has spent that much since its first message under the limit, as the agents report it, which on a plan is Claude Code's estimate at list price. The thread then takes no messages until you raise or lift the limit. It can end a little past the line, by the requests already on their way when it got there, since an agent says what a request cost only once it's made; a Claude Code worker's first request is about $0.004 on Haiku. Codex doesn't say what it spends, so with a limit set no worker starts on it. Under a limit a head can't open, message or run other threads, whose spending its own count doesn't take in, so it gives its parts to workers. Models heads keep off, in the same place, are never picked, for a worker, a task or the head itself.
- Stop on a thread stops every thread it set going with open_thread or message_thread that's still on that turn, and theirs, with a line in each saying so. A turn you started in one of them is yours and goes on. Once the head's own turn is over, the Stop command, ⌘I's main row, its row in ⌘⇧I and another thread's stop_thread still stop what it left working.

### Seeing and using the Mac

- An agent can see and use the apps on your Mac, if you let it. OriCode asks once, in a sheet at the first launch of 0.5.0, a new install's or an update's: Turn On or Not now, and either answer stays. Settings › Agents › The Mac has the switch from then on. It needs Screen Recording and Accessibility given to OriCode in System Settings › Privacy & Security, since the agents run as OriCode's children; the sheet and Settings each have a button that opens the pane for each, and OriCode has to be reopened after Screen Recording is turned on. With it on, an agent gets list_apps, screenshot, click, type_text, press_key and scroll: a picture of an app's window, at most 1568 pixels on its long side, and clicks, keys and scrolls in it, the app brought to the front first and the pointer moving. Its first call on an app asks you in the thread, and that thread keeps the app until OriCode quits; nothing either permission covers is read before you answer. OriCode's own windows are never seen or used. With it off, no agent is offered the tools, and turning it off takes back every app a thread was let use. Pi, Command Code and Antigravity take no MCP tools, so they don't get these either. When these notes were written no OriCode on the Mac it was built on had Screen Recording or Accessibility, so a thread was seen asking for an app and being told the permission was missing, but not yet taking a picture and clicking.

### Smaller

- A message more than twice its model's window in characters, about 2,000,000 on a model that reads a million tokens, isn't sent: a line under the composer says so and the text stays there. A session the model won't go on in, too long for it or one it stopped answering in, no longer makes every later message fail and be paid for again. The next message starts a new session handed what the thread has said, with a line saying so, and a thread that already held such a message sends its last one again at once in the new session. A million characters of one line repeated still gets garble from Haiku 5.5 first, since nothing before sending tells it apart from a million characters Haiku reads well; the thread goes on after it.
- A 200,000-character paste on one line holds the composer about 60 ms where it held it 90: past 20,000 characters the field's text is set without kerning, a hair wider. A long message folded in the transcript lays out only the lines it shows.
- Two threads streaming side by side hold their frames. Every thread's new text is shown on the display's own frame by one clock, which runs only while there is text to show, so the first words of a block can wait a frame or two. In the bench two streams went from 10 frames over 16.7 ms to 3, and a key typed while a reply streams waits about half as long.
- After long replies stream side by side, a column no longer ends blank until the window is resized. When the end goes missing the column finds it again, and for a moment it may show the reply two screens up before it lands.
- The line under a finished agent's or worker's title reads its reply's Markdown as words: a list's dash, a heading's hashes and a quote's mark go, a link reads as its words and a bold as its letters, while `__init__.py` and `2*3*4` keep their marks. A failed one's error keeps its first line as it came.
- Show earlier, at the top of a thread past 200 items, keeps the row under it where it stood and lays the earlier items out above, where it used to put the thread's first message in its place. It was seen in OriCode's test host with a 520-item thread, the button pressed through its accessibility element, not by hand.
- An edit card no longer cuts a long line at its right edge. A line wider than the card wraps under itself at the code's column, each row after the first marked ⤷ where its number would be, and the edge beside a changed line runs down all its rows. A card wraps rather than scrolling sideways, so the wheel still scrolls the transcript over it. It sets up to 2,000 characters of a line, where it set 240, and ends a longer one in an ellipsis. Nobody has looked at a wrapped card in a window; only the tests checked it.
- make perf and make perf-quick say after each step how many are done and the time left, from how long this run's steps took, and "can't tell yet" before the first has ended. The line has been seen from a shell, not inside a real run.

### One card, built in OriCode

- One card of this release, the first-turn line above, was built by one OriCode thread. Given "Build REA-226 from the board, as a card is built" and nothing set by hand, a thread on Claude Code's defaults in Auto read the board and the issue, wrote the card, and put a plan of two in one call: the build on Opus at high, and a review on Codex GPT-5.6-Terra at high that waited on it. The build passed the tests in 15 minutes. The review read the change for 8 and found nothing; its own run of the tests was refused by Codex's sandbox in Auto, which won't let the engine's tests start their local servers, so the lead ran them itself and committed. 29 minutes, $3.75, and no ask reached anyone. A review outside the run then found two ways the line could still mislead an opener, both fixed before it came here.
- What it didn't show. The run was in OriCode's test host, the real app and engine in a window, on a clone of the repository and sent its one message by a script, not in OriCode on its own checkout with someone watching. The build worked in the lead's own folder, so nothing was merged, and the review gave nothing to fix. An earlier run merged a thread's worktree and fixed two things its review found, but its lead's tests went to the background past Claude Code's ten minutes and the script took the waiting lead for finished, so that run never reached a commit. Merging, fixing, testing and committing in one run is still to be seen, and so is the new line itself in a window, with a real limit and its reset.

## v0.4.2 "Side by side" - 2026-10-16

- The Anthropic API is an agent of its own in Settings › Agents, on a key from the Claude Console, billed to that key's organization and never to your Claude subscription. It runs in Claude Code with the key as `ANTHROPIC_API_KEY`, which outranks your Claude login, and no other Anthropic credential reaches it. Its threads have Claude Code's models, levels and fast mode where your organization has it, and show what each turn cost, but no plan usage or limits and no Continue in Terminal, where `claude` would run on your subscription. Its models are drawn under Anthropic's mark; Claude Code's keep Claude's.
- ⌘K's Open a Claude Code session is Import sessions…: the project's sessions from Claude Code, Codex, T3 Code, OpenCode, Copilot and Cursor, each with its tool's name and its agent's mark, and Import all for every one that isn't a thread yet. A session comes in on the agent that ran it and goes on in the same session where that agent is on and can pick one up by its id, a T3 Code thread in the Claude, Codex or Cursor session under it. Cursor's chats, and a Claude Code session begun under another path to the folder, through a symlink, come in with their transcript, which your next message hands over to the agent a new thread starts on. Codex's and OpenCode's are listed only while those agents are on. Nothing is written into the other tools' files.
- Auto and Don't ask do what they say on the agents besides Claude Code. On Codex, Auto has Codex's own reviewer judge each request's risk instead of asking you, and a project added through a symlink no longer fails every command in Codex's sandbox and asks to run it outside. On every agent that asks, Don't ask answers its asks for you, those already waiting included, and switching to it mid-turn works from that moment. Cursor and Antigravity have Don't ask now. OpenCode no longer offers Auto, which there was only your own OpenCode settings.
- A pasted megabyte no longer freezes the window, as it was pasted, as it was sent, or every time its thread opened after. A message longer than 20,000 characters shows its first twelve lines, its size, Show more and Copy, which copies all of it; the agent still gets all of it. Codex takes up to 1,048,576 characters, and a longer message says so and stays in the message bar instead of going out to Codex's error.
- Water, in Settings › Conversation, turns the usage glass left of Send into a glass of water on Claude Code's threads, and says nothing of the plan there. It fills with today's water against a usual day, the average of the 30 days before today, and brims past one. Its card is the water of the thread, today, this week and this month, every Claude Code session on this Mac counted once, and the rate and its source are under the pointer on "estimated". The thread's figure still ends its latest turn's footer.
- The thread beside has a capsule of its own over its column, in the title capsule's glass, its cross at the right end where a tab's is, away from its working mark. A click there no longer looks like stopping it: the capsule draws itself into a drop, runs up to the window's capsule and flows into its end, and the thread you leave buds out of the other end as a drop, pinches off and falls into the other column's capsule. With Reduce Motion the titles only fade.

## v0.4.1 "Side by side" - 2026-10-15

- A thread can say how much water it is estimated to have used. Settings › Conversation › Water turns it on; until you do, nothing is shown and nothing is counted. The footer under the thread's latest turn ends with "≈ 0.3484 L of water so far, estimated", on a line of its own when the column is too narrow for both, and the card over the usage glass says it again with the rate, 112.5 ml per thousand output tokens, the glasses of 250 ml once there is a tenth of one, and where the rate comes from. That is Mistral's published figure for its own model, 45 mL of water for a 400-token reply, from its life-cycle analysis of Mistral Large 2. Claude is taken to cost the same, which is why the number is an estimate, and input and cached tokens count nothing.
- Only Claude Code threads have a figure, since it is counted from the transcript Claude Code keeps of the session. A turn made on that session in Terminal counts, a subagent's tokens don't, a thread on any other agent shows nothing, and a thread moved to another agent loses its figure at once. It moves a moment after each tool the agent runs as well as when a turn ends, not with each word of a reply, and only in a thread you can see; one out of view is counted when it comes back. Two threads side by side have one each.
- ori-water, a mod for Claude Code, shows the same figure under the prompt of a Claude Code session. Both count from one definition, so a session reads the same in the window and in the terminal.
- The review's page comes to rest on the change the keyboard is on. J then K, K then J, or a held J let go, pressed before the page had finished gliding, could leave it where the first key was taking it, with the selected change out of view and the caption under the page naming something not on it; in Witness, Tab then ⇧Tab could leave it far down the page. The page is now asked for the selected change again once the glide is over, so when keys come fast it may finish the first glide and come back.
- The dots in a turn's footer are spaced alike. The one before its files stood wider than the rest.

## v0.4.0 "Side by side" - 2026-10-13

### Two threads

- Two threads fit in the window at once. ⌥⌘1 to 9 puts that thread of the drawer beside the open one, and so do ⌥-click on its row, Open Beside in the row's menu and in the Thread menu, and ⌘K's Open beside…. Each has its own message bar, with its own model button, queue and Stop, so you can write to both and both can work at the same time. The keyboard is in one of them: a click anywhere in a column puts you there, ⌥⌘← and ⌥⌘→ do it from the keys, and the title, the review and ⌘K follow it. ⌥⌘W, Close Other Side, or the cross on the other thread's title puts that side away and stops nothing. There is never a third, and ⌘N with two in view gives the new thread the whole window until its first message, after which the one beside is back. Where the window hasn't about 440 points for each, the pair folds to the thread you're writing in, either arrow shows the other, and a thread asked for beside says "Widen the window to see both". Quit, and the same two come back on the same sides. The arrows and ⌥⌘W can be given other keys in Settings › Shortcuts; if one of them, or ⌥⌘ with a digit, was already a key of yours for something else, it stays yours.
- What you type stays with its thread. Open another thread and the field shows that one's own draft; come back and yours is there, with its pictures and its `$` prompt. The text of a draft outlasts a quit, in every thread that has had its first message. Its pictures, its queue and a `$` prompt don't, and neither does text in a thread you never sent anything to.
- In a pair the model button gives up its level's word and then its model's name as its column narrows, so the field keeps its room. The keyboard is in the message bar when the app opens.

### Witness, the review

- Witness is the review now, and ⌘⇧D opens it. It starts with one sentence about the checks, "make test last ran before RootView.swift last changed. It was piped through tail, so its result is not known.", then Read first, the changes to read before any other, each with its reason in words: changed after a check last ran, words taken out of a line, changes what a test expects, deleted. Under that each check's last run has a row saying exited 0, failed, or result not known and why, then the rest in the order the thread touched the files, then Spacing, moves and lockfiles, a line each. No model is called for any of it, and nothing on the page says a check passed. The review as it was is one setting away: Settings › Source control › Review, Legacy.
- In Witness a change reads as code. One column of numbers, a green edge beside an added line, the old line in red above a replaced one with the words that went washed, and a removal of more than six lines as one row that → opens. J and K walk by change, Space marks a change reviewed and goes to the next, as a click in the number column marks it, ⇧Space marks the file, N leaves a note, ⌫ takes a change back, O opens the file at its line. T shows the edit in the thread, lit for a moment, and A writes a note asking for the check again, unpiped, which goes only when you send it. What can be done to a change is also in a right-click on it and in the header's "…". → on a run's row shows the last twelve lines it printed. Under the page a caption says of the change the keyboard is on which message asked for it, how often its file was edited and with which runs between, and what the agent said before the edit. The commit button says what it takes, "Commit 9 Files" or "Commit 4 Reviewed". Code in Witness has no syntax colours and can't be selected; the change's menu has Copy.
- Three keys do something else than they did. Tab and ⇧Tab walk by file, and reach the commit message only past the last one, where Tab used to go straight to it. ← and → open and close a long removal where they folded a file. O opens the file at the change's line, not at its top.
- Witness knows more runs than the main agent's own. A command you run at the shell prompt counts as a check, so does one a Claude Code subagent ran, and one sent to the background says how it ended once it has. Settings › Source control › This project's check names a command of your project's own, ./ci.sh say, to be read as make test is. A result is known where the agent's word is the command's own ending, which is Claude Code, Codex and your shell prompt, or where the call carries an exit code, looked for in Cursor's and OpenCode's. Pi, Antigravity and Command Code send none, and none has been seen from Copilot, Grok Build or Devin, so a run of theirs stays "result not known". So does any run with something after the check other than &&: a pipe, a `;`, an `||`.
- What Witness doesn't see. Only checks run since the last commit are on the page. Agents pipe most test runs through something, so expect "result not known" on most rows until a check is run bare, which is what A asks for. A thread brought in from a Terminal session has no times, so all of it is Read first until a check runs in OriCode. A subagent given a worktree of its own isn't read.
- An edit in the transcript is drawn as the review draws it: its first twelve lines open, with their numbers, the green edge and the old line in red, and a line at the foot counting the rest. A click on the card's header opens the review on that file's change; the path in it no longer opens the file, which O in the review does. The card doesn't fold any more, so a thread of many edits is a good deal taller than it was. A line longer than the card is cut at its edge and whole in the review. With Legacy chosen the card is the folded one it was, its path a link.

### Threads that open and read each other

- Ask a thread for another, "open another thread and have it fix that in the other repo", and it opens one. It is an ordinary thread, in the drawer from its first message, on the agent, model and permissions of the one that opened it unless you named others, in the same folder, in another project you've added, or on a branch of its own. The first thread carries on, and when the other's first turn ends it gets one line, "… finished its first turn" or "… stopped before its first turn finished", which a click opens beside. A thread opened this way can't open another, and one turn opens three at most. This and the two below need an agent that takes OriCode's tools, which Pi, Command Code, Antigravity and Grok Build don't.
- A thread can suggest one too. When the agent comes across something outside what you asked, a bug in passing or a test that was already failing, a button with its title sits under the reply; a click opens a new thread in the same project with the prompt written in the message bar, unsent. Nothing starts until you send it, and a turn offers two at most. So far it has been seen from Claude Code only, and not from every model: Sonnet and Opus offered one unasked where Haiku didn't.
- Threads can read each other. Ask one "which thread changed Drawer.swift?" and it lists the project's threads with the files each edited, and it can read another's transcript, the one it opened included. An edit here is one an agent made with its edit tool; a file changed by a shell command, sed or a script, has no thread to its name, and the answer says so. Reading is all it can do to a thread that exists: it can't message, steer or stop one.

### Smaller

- The drawer's project menu has No folder, after your projects, so a thread tied to no project is one pick away from inside any of them. ⌘K's Reveal in Finder is Open project folder in Finder, which opens the folder the thread works in, its worktree for a thread on its own branch, and answers to "open", "folder" and "path" as well as "reveal".
- A thread that came up as empty glass, its title and its message bar there and no messages until you sent one, now finds its own end.
- J or K pressed in the first moment of the review opening no longer quits the app. In Legacy, a file opened after the page was made shows its changes.
- Words no longer run into each other, or get squeezed to dots, in a narrow window. The review's header stays on one line, its branch and file name giving way in the middle; the commit message takes a row of its own over the buttons when there's no room beside them; a pinned drawer stands aside while the review is up in a window too narrow for both; an open file ends above a tall message bar; and what git said of a refused push runs on as one line under the composer, as far as the line has room, and whole under the pointer.
- A streaming reply does about an eighth less work for each piece of text that arrives, and ⌘K's search does less for each letter. For the first, the paragraph still being written can't be selected, and a link in it doesn't click, until it ends or half a second passes with no new word.

## v0.3.3 "Hands on" - 2026-10-06

- A thread no longer needs a folder. With no project, type and send: the thread starts in No folder, which sits after your projects with a laptop for its badge. ⌘K has New thread without a folder, and the File menu has it too. Its working folder is an empty one the app keeps, so nothing walks your disk, and an agent reaches the rest of the Mac by full path, as far as the thread's permissions let it; Claude Code and Codex are told so. A file an agent writes without a path lands in that folder, which ⌘K's Reveal the scratch folder in Finder opens. It has no repository, so ⌘K leaves out the git, branch and pull request commands there, and the review says the folder isn't a git repository.
- A code block has Copy at its top right. In a block longer than the window it follows the top edge down as you scroll, so it's in reach wherever you're reading.
- A click on a picture you sent opens it in Quick Look, with the arrows stepping through that message's others. It opens at the size it went to the agent, up to 1568 pixels on its long edge. Pictures are kept at that size from this version on, in OriCode's own folder, and go when their thread is deleted; one sent before it opens as the small preview it was stored with.
- Over a link in a reply the pointer shows it can be clicked, and a right-click on it offers Open Link and Copy Link. A selection can run across a link but no longer starts on its words.
- Away from a thread's end, a small arrow sits above the composer and a click on it goes there; it says New when something arrived while you were reading further up. ⌘K has Jump to the end of the thread.
- A message you send brings the thread to its end when you were near it, and leaves it alone when you were reading further back.
- A queued message doesn't have to wait for the turn to end: the arrow on its line, Send now, puts it into the turn that's running. It's there for the agents that take a message mid-turn.

## v0.3.2 "Hands on" - 2026-10-05

- The pull request is drawn now. The line under the composer is a bead for each check, lit while it runs and red if it failed, then the number and the one thing worth knowing: "2 checks running", "test failed", "conflicts with main", "ready to merge". Click it and it opens out of the title: every check with how long it took, Log and Send to the thread on the row under the pointer, Open on GitHub, and Merge, which asks first and squashes.
- Settings › Activity shows the tokens that went through OriCode's threads over the last 26 weeks: a grid of days, the same by week, or adding up.
- Archived threads are within reach. The thread list's filter has Archived, whose rows restore from their menu, ⌘K has Archived threads…, and a message sent in an archived thread brings it back.
- ⌘K gained what it was missing: Filter threads…, Restore thread, Ask for a review of the changes, Edit and Save for an open file, Show or Hide thinking, and Concise replies on or off.
- Actions of your own can do more than run a shell line. In Settings › Actions an action can be one of OriCode's own commands, picked by name, and any action can have a key of its own. So a command you wish had a shortcut, or a second name, is something you add yourself; actions.json can still be edited by hand.
- Settings › Source control › Write message with lets the review's Write Message use the thread's own model instead of the small one.
- The keyboard shortcuts sheet is ⌘⇧K. ⌘/ is a Shift away on a Turkish keyboard, as ⌘; was.
- Delete in Settings › Archive asks in Settings, not in the main window behind it.

## v0.3.1 "Hands on" - 2026-10-04

- ⌘S saves in the file editor. The editor takes the key itself now; in 0.3.0 the menu's Save was still off when the key arrived, so it did nothing.
- The side question is ⌘⇧A. ⌘; isn't a key of its own on every keyboard: on a Turkish one the semicolon is a Shift away, so it never fired. If you gave it another key in Settings › Shortcuts, yours stays.

## v0.3.0 "Hands on" - 2026-10-04

### In the conversation

- Diagrams and charts are drawn. An agent that answers with a fenced `svg` block gets it drawn in place of its code, on a card, clear so the glass shows through; while it streams the thread says "Drawing…", and a right click copies the image or the SVG. Claude Code and Codex are told the window draws, so asking for a diagram is enough.
- ⌘⇧A (⌘; in 0.3.0) asks a side question. The answer comes from everything the thread knows and neither the question nor the answer joins it: the engine asks a copy of the thread's session that it never saves. It works while the thread is busy. Claude Code only, for now.
- Typing `@` lists the project's files as you go, ranked as ⌘P ranks them. Return or Tab puts the path in the message.
- The paperclip and a drop take any file now, on every agent. A picture still goes among the thumbnails; anything else, a PDF, a source file, a folder, is named in the message for the agent to open with its own tools.
- Settings › Conversation has Show thinking, which leaves the thinking lines out when it's off, and Concise replies, which asks Claude Code and Codex for shorter answers, fewer comments and changes kept to what you asked.

### Files, review and pull requests

- The file viewer edits. Edit puts the file in a native text view, ⌘S saves it, and a file an agent changed since you opened it is refused rather than overwritten. Closing with edits unsaved asks first.
- Ask for a Review, in the review's header, has the thread's agent read the diff and puts its comments on the lines they name. Keep one and it's a note of yours to send back; dismiss the rest. It joins no turn.
- Pull requests, through GitHub's own `gh` and the login you made for it. ⌘K's Open a pull request pushes the thread's branch and opens one from its commits. The line under the composer says where its checks have got, Send to the thread hands a failing check's log to the agent as the next message, and a notification says when the checks finish.

### Threads

- Archive, from a thread's row or ⌘K, takes a thread out of the list and keeps everything of it. Settings › Archive restores it or deletes it for good.
- The thread list has a filter at its head: one project's threads, the ones at work, or the ones waiting on you.
- ⌘K's Open a Claude Code session lists the sessions you started with `claude` in Terminal in the project's folder, and opens one as a thread with its transcript that carries on from where it stopped.
- Settings › General › New threads has Workspace: ⌘N can start every thread on a branch of its own, with ⌘⇧N making one in the project's folder instead. Settings › Source control names the prefix those branches take.
- A thread on its own branch gets the ignored files `.worktreeinclude` names, an `.env` say, copied into its worktree, as the Claude Code app does.

### Settings

- Settings › MCP lists the servers Claude Code loads for a project, each with where it has got, a switch, and Remove, and adds one by its URL or its command. It all goes through your own `claude`, which keeps its own configuration; a server that wants a sign-in gets it in Terminal with `/mcp`.

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
