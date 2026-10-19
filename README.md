# OriCode

A native macOS window for coding agents: Swift and SwiftUI, one pane of glass with the conversation on it. It runs the agents you already have, Claude Code, Codex, Cursor, Copilot, OpenCode and others, each through its own CLI and the login you made for it in Terminal, and a few model APIs by a key kept in your Keychain.

OriCode isn't made or endorsed by Anthropic or by any other agent's maker. Claude, Claude Code and the Claude logo are Anthropic's trademarks, and every other agent's name and logo belong to its maker.
<img width="3410" height="2166" alt="image" src="https://github.com/user-attachments/assets/f015cde4-ba20-439d-8db5-bbebeff3f0d9" />

## What it needs

- macOS 26 or newer on Apple silicon
- Claude Code, installed and logged in: run `claude` in Terminal once. Every other agent is optional and turned on in Settings › Agents.
- Node 24 or newer, which runs the app's engine
- For pull requests, GitHub's CLI, signed in: `brew install gh`, then `gh auth login`. Everything else works without it.
- For agents to see and use your Mac, Screen Recording and Accessibility given to OriCode, which it asks about once. Everything else works without them.
- To build it: Xcode 26 or newer with its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), and XcodeGen (`brew install xcodegen`)

## Installing

Download OriCode's zip from the [latest release](https://github.com/realmeric/OriCode/releases/latest), unzip it, and drag OriCode into Applications. From then on it updates itself.

## Opening it the first time

OriCode is signed but not notarized by Apple, so the first time you open a copy you downloaded, macOS stops it and says Apple couldn't check it for malicious software. Once it's in Applications, clear the flag the download put on it, in Terminal, and open it as usual:

```sh
xattr -dr com.apple.quarantine /Applications/OriCode.app
```

Some versions of macOS also offer Open Anyway in System Settings › Privacy & Security after that first try. Updates come through OriCode itself and shouldn't ask again.

## Updates

OriCode checks GitHub for a newer release once a day, or when you choose OriCode › Check for Updates…. When there is one, a circle with an arrow appears beside the title at the top of the window. Click it to download the update, and again to restart into it.

## Agents

Settings › Agents lists them all. Turn one on and OriCode looks for its CLI the way it looks for Node, or you choose the binary yourself, and its row says whether it's signed in or gives the one Terminal line that would sign it in. An agent that's off is never looked for.

These come in through their own binary and keep their own login, which OriCode never reads:

- Claude Code, through Anthropic's Claude Agent SDK and the `claude` on your Mac
- Codex, through `codex app-server`, logged in with `codex login`
- Cursor, through `cursor-agent acp`, logged in with `cursor-agent login`. On Cursor's Free plan the model menu offers only Auto, the one model Free runs.
- GitHub Copilot, through `copilot --acp`, logged in with `copilot login`. A GitHub account without a Copilot plan says so, with GitHub's line for getting Copilot Free.
- OpenCode, through `opencode acp`. Its free models need no login, and the keys you gave `opencode auth login` stay OpenCode's.
- Grok Build, through `grok agent stdio`, logged in with `grok login`
- Devin, through `devin acp`, logged in with `devin auth login`
- Pi, through `pi --mode rpc`, logged in with `pi` and then /login. Pi never asks before it runs a tool, so its threads say they run unsupervised.
- Antigravity, through `agy`, on a Gemini API key from Google AI Studio that you keep under Antigravity in Settings › Agents, with `"modelProvider": "gemini"` in `~/.gemini/antigravity-cli/settings.json`. Its Google account login is off, as below.

These run by an API key you type into Settings › Agents. It's kept in your login Keychain and handed only to the process that calls that API:

- The Anthropic API runs inside Claude Code, on a key from the Claude Console, billed to that key's organization rather than your Claude subscription. Claude Code takes the key as `ANTHROPIC_API_KEY`, which outranks your Claude login, and OriCode hands it no other Anthropic credential, so the subscription is never used on those threads. They offer the models, levels and fast mode Claude Code lists, and show what each turn cost, but no plan usage or limits, since a key has none, and no Continue in Terminal, where `claude` would run on your subscription. They need Claude Code installed, not logged in; logged out, the model menu offers Default, Opus, Sonnet and Haiku.
- Z.ai, DeepSeek, OpenRouter and Meta run inside Claude Code, pointed at each maker's Anthropic-compatible endpoint. The key takes the place of your Claude login in that thread's process, so your Claude subscription is never sent to them, and Claude's plan usage, limits and fast mode don't show on those threads. They need Claude Code installed, not logged in.
- Command Code runs its own `cmd`, headless, with your Command Code key, or with the login `cmd login` made.

A thread offers only what its agent can do: no effort rail on an agent without levels, no permission tiles on one that never asks, no usage glass where the agent reports none.

Claude Code is what OriCode was built on. Codex, Cursor and OpenCode have run real threads in it. Copilot's check has run against the real CLI, on an account without a plan. Grok Build, Devin, Pi, Command Code, Antigravity and the five model APIs are built to their makers' protocols and tested against stand-ins, and haven't had a real turn yet, so expect rough edges there.

## Logins that stay off

Some agents can sign in with an account whose maker keeps that login to its own apps. OriCode offers each of those off, under the maker's own sentence and a link to its terms, and you can turn one on in Settings › Agents. Until you do, the models behind it show dimmed in the model menu.

- Antigravity with a Google account. Google's terms call reaching Antigravity through third-party software with its Google login a breach that can get the account suspended, and Google suggests an API key for third-party agents instead.
- Pi signed into claude.ai. Anthropic doesn't let third-party apps offer claude.ai login or route requests through Free, Pro or Max plans.
- Pi signed into xAI. xAI's terms couldn't be read when this was built, so the switch quotes nothing and links to them.
- Pi signed into Meta. Meta says a Muse Code credential is for Muse Code only.

## Sessions from other tools

⌘K's Import sessions… lists the project's sessions from the other tools on your Mac: Claude Code's from Terminal and Claude's app, Codex's from its CLI and its app, OpenCode's, Copilot's, Cursor's chats from `cursor-agent`, and T3 Code's threads. Each shows its tool's name and its agent's mark, and Import all brings in every one that isn't a thread yet. A session comes in on the agent that ran it and goes on in the same session, where that agent is turned on in Settings › Agents and can pick a session up by its id; T3 Code's go on in the Claude, Codex or Cursor session underneath them. The rest, Cursor's chats among them, come in with their transcript, and your next message hands it over to the agent a new thread starts on. So does a Claude Code session begun under another path to the folder, through a symlink, since Claude Code picks a session up only from the path it began in. Codex's and OpenCode's are asked of their own CLIs, so they're listed only while those agents are on. OriCode reads the other tools' files and writes nothing into them.

## Rays

A thread's model is its head, and its rays are the models it sends workers out on, any agent's. The model page picks the head, and its Rays line under the models picks the rays from every ready agent's models the model menu shows: Opus as the head with GPT-6-Luna as its ray, say. The model button shows each ray's mark beside the head's name, unless the head chooses. With rays picked, OriCode tells the head which it has, in its own instructions rather than your prompt, so it hands them the parts of a task that suit them without being asked. With none, the head works alone.

OriCode serves the head a few tools of its own over MCP: start a worker on one of its rays with a task, see how it's doing, read what it brought back, message it, stop it, and merge its work. A worker that edits can work in a worktree of its own, on an `oricode/ray-…` branch, and a merge brings its changes in uncommitted, as a thread's merge does, where the review says which worker changed what.

With Heads choose on in Settings › Agents, which it is unless you turn it off, the head picks all of that itself. It's told every model the model menu shows on each ready agent, with their effort levels and the plan windows its CLI reports, and it starts workers on whichever suit the parts, each at a level it names. It moves its own model and level too, up before a hard part and back down after, and each move is a line in the transcript with its reason: "Now at high effort · The parser needs care with leap days". Rays you pick still go to it, as the models you'd rather it used. Settings also keeps two limits. Spend per thread stops the head and its workers when the thread has spent that much since its first message under the limit, as the agents report it, and the thread then takes no more messages until you raise or lift it. It can end a little past the line, by the requests already on their way when it got there, since an agent says what a request cost only once it's made. Codex doesn't say what it spends, so with a limit set no worker starts on it, and under a limit the head can't open or message other threads, whose spending isn't counted in its own. Models heads keep off are never picked, for a worker or for the head itself. With Heads choose off, a head works on the rays picked for it and stays where you put it.

While it chooses, the model button says Choosing where the level and the rays' marks were, and its help says where the head is now. Every worker it starts comes with a line on why that model at that level, and ⌘I lists what it chose under what's at work, oldest first: each worker's model, level and task with its reason, and each move of its own with why.

Each worker is a ray on the thread's mark, in its agent's colour, around a dot in the head's: a Claude head with Codex rays is an orange dot with white rays, and a Codex head with Claude rays the other way round. Each is also a read-only thread folded under the head's, whose transcript shows live when opened and whose Stop stops that worker alone. ⌘I lists them with their agent, model, step, time and cost, their cost counts toward the thread's, and Stop on the head stops them too, with every thread it opened that's still on a turn it set going. Once the head's own turn is over, the composer's button goes back to sending, and the Stop command, the main loop's row in ⌘I, its row in ⌘⇧I or another thread's stop_thread stops what it left working. Heads may start workers, in Settings › Agents, turns it all off.

Claude Code, the model APIs inside it, Codex, and the ACP agents that take MCP over HTTP, such as OpenCode, Cursor and Copilot, can be heads. Pi, Command Code and Antigravity take no MCP tools, so they can only be workers. So far a Claude head with a Codex worker and an OpenCode worker has run for real, and an Opus head that sent its GPT-6-Luna ray a task nobody had told it to hand out.

## Threads that work with threads

An agent does to your threads what you can. It opens one when it judges the work wants it, a part of a task that can go on alone or something in another of your projects, and a thread it opened can open its own. It sends any thread a message, waits for a thread's turn to end and gets its last reply, and stops one. So a thread handed a task with two parts that don't depend on each other can give each part a thread, wait on both and bring back what they did. It asks you first only where it isn't sure.

Every open, message and stop leaves a line in both threads' transcripts with the agent's one-line reason, and a click on it opens the other thread. A thread opened this way is an ordinary thread, folded in the list under the thread that opened it, which says how many under it are working and takes them to the archive and back with it. Stop on a thread stops the threads it opened as well, and theirs, with a line in each saying so, but only a turn it set going there with open_thread or message_thread: a turn you started in one of them is yours, and a thread that stops its own opener goes on itself. It runs in a permission mode no looser than its opener's, and a thread takes no message from one in a tighter mode than its own, so a thread on Plan can't have one on Don't ask make the edits it may not. What you don't want an agent to do with threads goes in the project's CLAUDE.md or AGENTS.md, which it reads and keeps to. Threads working at once, in Settings › Agents, caps how many can be working before an agent can't set another going: six unless you change it. What you send yourself is never held back by it.

A thread that edits files while another does works in a worktree of its own, and once its turn is over the thread that opened it merges it back: what's uncommitted there goes onto its branch, git merges the branch into the opener's folder as it stands, and the files arrive uncommitted beside the opener's own edits, for you to review. A conflict leaves the merge open with git's markers in the files, and the agent settles them, asks you which side to keep, or takes the merge back, which puts every file it wrote back as it was. A file one side deleted, or a binary one, has no markers to settle, so the merge waits until the agent names the side it keeps. A merge still open when its turn ends, or when OriCode quits, is taken back. A thread on Plan merges nothing, and a thread in a looser mode than its opener's isn't merged from there. Once nothing in the worktree is left out, a file git ignores that the opener's folder lacks or has otherwise included, the worktree and its branch go, and the merged thread works in its opener's folder from then on, its subagents and the threads it merged with it. Both transcripts say what came in. When two threads at work edit the same file, each gets a line naming the other, and so does the thread that opened them. Only an edit an agent makes with its edit tool is seen; a file a command changes isn't.

A Claude Code workflow's agents and a Claude thread's Task subagents are read-only threads under the thread that started them too, each with its transcript live and, once it ends, the first line of what it returned. A subagent stops alone. A workflow's agent stops only with its workflow: Claude Code can't stop one agent of a workflow, so the Stop in that agent's thread stops all of them.

⌘⇧I puts everything running on one screen: every thread that works, waits or has had a turn since OriCode opened, in every project, each under the thread that opened it, and a workflow's agents, a Task subagent and a head's workers under the thread that started them, with whether it's working, waiting, done, stopped or failed and what it's on now. A click opens a thread, Stop is on a working row under the pointer, and the composer under the screen still writes to the open thread. Above them is every question and permission waiting on you, oldest first, each named by the thread or worker that asks and answered right there without opening it; with OriCode in the background a notification names the thread, and its click opens the screen on that ask. In the drawer a row says how many asks wait at it and under it.

Each project has a plan the agents keep. A thread handed work whose parts wait on each other writes every part as a task, with what done means and what it waits on, then opens a thread for each task that waits on nothing and the rest once what they wait on is done. A thread opened for a task is told it, and keeps it with a short note as it goes until it's done or stuck. Any thread can read the plan, and in the same call every thread working in any project and every ask waiting on you. On ⌘⇧I each project's plan stands above its threads while a task of it isn't done or has changed since OriCode opened, each task with its state, its thread and its note, changing as they keep it, and past six done tasks only the latest three of them; a click opens a task's thread, and under the pointer a task can be stopped, reopened or deleted, as ⌘K's Stop, reopen or delete a task can from the keyboard. The plan is stored with the project's threads and is there after a relaunch.

Claude Code, the model APIs inside it, Codex, and the ACP agents that take MCP over HTTP have these tools. Pi, Command Code and Antigravity take no MCP tools, so their threads can be opened, messaged and stopped but do none of it themselves.

## Seeing and using the Mac

An agent can take a picture of an app's window and click, type and scroll in it, to check a change in the running app, say, if you let it. OriCode asks once, in a sheet at the first launch that hasn't answered: Turn On or Not now, and the answer stays, with the switch under The Mac in Settings › Agents from then on. It needs Screen Recording and Accessibility given to OriCode in System Settings › Privacy & Security, since the agents run as its children; the sheet and Settings each have a button that opens the pane, and OriCode has to be reopened after Screen Recording is turned on.

With it on, an agent gets list_apps, screenshot, click, type_text, press_key and scroll on OriCode's MCP server. Its first call on an app asks you in the thread, "Let this thread see and use Safari?", and that thread keeps the app until OriCode quits. Nothing either permission covers is read before you answer, and list_apps gives only each running app's name and bundle id. The app is brought to the front before a click, a key or a scroll, and the pointer moves. OriCode's own windows are never seen or used. With it off, no agent is offered the tools, and turning it off takes back every app a thread was let use. The agents that take OriCode's tools get these; Pi, Command Code and Antigravity don't.

## The marks in the model menu

The model menu lists each agent's models under its name and its maker's logo, drawn in the colour its maker draws it in on a dark background, white where the maker's mark is black or white, which the effort rail and the thread's mark take too. Claude's logo marks Claude Code's models and Anthropic's own logo the Anthropic API's, both Anthropic's. The logos of OpenAI (Codex), Anysphere (Cursor), GitHub (Copilot), OpenCode, xAI (Grok Build), Cognition (Devin), Pi, Google (Antigravity), Z.ai, DeepSeek, OpenRouter, Meta and Command Code belong to their makers, as each agent's name does. OriCode shows them only to mark each agent's models, none of those makers made or endorsed it, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) says where each came from.

## Building

```sh
make run    # builds OriCode Molten, the Debug app, and opens it beside OriCode
make app    # builds Release and copies it to /Applications
make test   # the engine's protocol tests and the Swift unit tests
```

## How it reaches the agents

The app never sees an agent's password or token. It starts a Node process, `engine/`, which starts each agent's own CLI and asks it whether it's signed in; it never reads a file or a keychain item that holds a login. Claude Code runs through the Claude Agent SDK, and the SDK runs the `claude` on your Mac, signed in however you signed it in.

The one credential OriCode keeps is a model API's key. The app writes it to your login Keychain and never reads it back, and the engine reads it only as it starts the process that calls that API, into that process's environment alone. What you do in OriCode counts against your own plans and keys, under each maker's terms, [Anthropic's](https://code.claude.com/docs/en/legal-and-compliance) included.

## Where things are

`App/` is the Swift app and `engine/` the TypeScript engine it speaks newline-delimited JSON with, and `project.yml` generates the Xcode project through XcodeGen.

## License

MIT, in [LICENSE](LICENSE). The code and marks OriCode builds on are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
