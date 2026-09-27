# OriCode

A native macOS window for coding agents: Swift and SwiftUI, one pane of glass with the conversation on it. It runs the agents you already have, Claude Code, Codex, Cursor, Copilot, OpenCode and others, each through its own CLI and the login you made for it in Terminal, and a few model APIs by a key kept in your Keychain.

OriCode isn't made or endorsed by Anthropic or by any other agent's maker. Claude, Claude Code and the Claude logo are Anthropic's trademarks, and every other agent's name and logo belong to its maker.
<img width="3410" height="2166" alt="image" src="https://github.com/user-attachments/assets/f015cde4-ba20-439d-8db5-bbebeff3f0d9" />

## What it needs

- macOS 26 or newer on Apple silicon
- Claude Code, installed and logged in: run `claude` in Terminal once. Every other agent is optional and turned on in Settings › Agents.
- Node 24 or newer, which runs the app's engine
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

- Z.ai, DeepSeek, OpenRouter and Meta run inside Claude Code, pointed at each maker's Anthropic-compatible endpoint. The key takes the place of your Claude login in that thread's process, so your Claude subscription is never sent to them, and Claude's plan usage, limits and fast mode don't show on those threads. They need Claude Code installed, not logged in.
- Command Code runs its own `cmd`, headless, with your Command Code key, or with the login `cmd login` made.

A thread offers only what its agent can do: no effort rail on an agent without levels, no permission tiles on one that never asks, no usage glass where the agent reports none.

Claude Code is what OriCode was built on. Codex, Cursor and OpenCode have run real threads in it. Copilot's check has run against the real CLI, on an account without a plan. Grok Build, Devin, Pi, Command Code, Antigravity and the four model APIs are built to their makers' protocols and tested against stand-ins, and haven't had a real turn yet, so expect rough edges there.

## Logins that stay off

Some agents can sign in with an account whose maker keeps that login to its own apps. OriCode offers each of those off, under the maker's own sentence and a link to its terms, and you can turn one on in Settings › Agents. Until you do, the models behind it show dimmed in the model menu.

- Antigravity with a Google account. Google's terms call reaching Antigravity through third-party software with its Google login a breach that can get the account suspended, and Google suggests an API key for third-party agents instead.
- Pi signed into claude.ai. Anthropic doesn't let third-party apps offer claude.ai login or route requests through Free, Pro or Max plans.
- Pi signed into xAI. xAI's terms couldn't be read when this was built, so the switch quotes nothing and links to them.
- Pi signed into Meta. Meta says a Muse Code credential is for Muse Code only.

## Rays

A thread's head can send out workers on other agents. OriCode serves the head a few tools of its own over MCP: start a worker on an agent and model with a task, see how it's doing, read what it brought back, message it, stop it, and merge its work. A worker that edits can work in a worktree of its own, on an `oricode/ray-…` branch, and a merge brings its changes in staged, where the review says which worker changed what.

Each worker is a ray on the thread's mark, in its agent's colour. ⌘I lists them with their agent, model, step, time and cost, their cost counts toward the thread's, and Stop on the head stops them too. At the foot of the model menu's model page, Workers may use picks the agents a thread's workers can run on; with none picked, a head may use any ready agent while Heads may start workers is on in Settings › Agents, as it is at first.

Claude Code, the model APIs inside it, Codex, and the ACP agents that take MCP over HTTP, such as OpenCode, Cursor and Copilot, can be heads. Pi, Command Code and Antigravity take no MCP tools, so they can only be workers. So far a Claude head with a Codex worker and an OpenCode worker has run for real.

## The marks in the model menu

The model menu lists each agent's models under its name and its maker's logo, drawn in a colour of the agent's own, which the effort rail and the thread's mark take too. Claude's logo is Anthropic's. The logos of OpenAI (Codex), Anysphere (Cursor), GitHub (Copilot), OpenCode, xAI (Grok Build), Cognition (Devin), Pi, Google (Antigravity), Z.ai, DeepSeek, OpenRouter, Meta and Command Code belong to their makers, as each agent's name does. OriCode shows them only to mark each agent's models, none of those makers made or endorsed it, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) says where each came from.

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
