# OriCode

A native macOS app for coding agents: Swift and SwiftUI, one pane of glass with the conversation on it. The agent it runs today is Claude Code, the one you already use, signed in with your own account, through Anthropic's Claude Agent SDK.

OriCode isn't made or endorsed by Anthropic. Claude, Claude Code and the Claude logo are Anthropic's trademarks.

## What it needs

- macOS 26 or newer on Apple silicon
- Claude Code, installed and logged in: run `claude` in Terminal once
- Node 24 or newer, which runs the app's engine
- To build it: Xcode 26 or newer with its Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), and XcodeGen (`brew install xcodegen`)

## Opening it the first time

OriCode is signed but not notarized by Apple, so the first time you open a copy you downloaded, macOS stops it and says Apple couldn't check it for malicious software. Open System Settings › Privacy & Security, find the line saying OriCode was blocked, click Open Anyway and confirm. macOS remembers that for this copy.

## Building

```sh
make run    # builds OriCode Molten, the Debug app, and opens it beside OriCode
make app    # builds Release and copies it to /Applications
make test   # the engine's protocol tests and the Swift unit tests
```

## How it reaches Claude

The app never sees a password, a token or an API key. It starts a Node process, `engine/`, that drives the Claude Agent SDK, and the SDK runs the `claude` on your Mac, signed in however you signed it in. What you do in OriCode counts against your own plan or key, under [Anthropic's terms](https://code.claude.com/docs/en/legal-and-compliance).

## Where things are

`App/` is the Swift app and `engine/` the TypeScript engine it speaks newline-delimited JSON with. `KANBAN.md` is the plan and the record of every change so far, and `project.yml` generates the Xcode project through XcodeGen.

## License

MIT, in [LICENSE](LICENSE). The code and marks OriCode builds on are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
