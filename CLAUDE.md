# OriCode

KANBAN.md is the plan and the tracker. Work it the way its "How to work this board" section says.

Linear's OriCode project holds what's next. A REA issue is built as a card on this board and committed to main like any other card, not on a branch or in a pull request, whatever the global Linear rule says. The card and its commit name the issue, as in `K-137: Write while Claude works (REA-153)`, and the issue moves to In Progress when its card starts and to Done once the card is pushed.

## Rules that don't move

1. **Never hand-roll a control the platform already has.** `Picker`, `Toggle`, `Slider`, `Menu`, `List`, `TextField`, the `Settings` scene, `NSOpenPanel`, `UserNotifications`, native materials, the native window. The previous version of this app was a web view, and over a thousand lines went into redrawing dropdowns, toggles and window chrome that AppKit gives away. It still looked wrong. If a card starts to read as "build a custom X", the card is wrong; fix the card.
2. **No persistent panels.** The only things always on screen are the transcript and the composer. Threads, changes, files, settings: each slides over the same glass when called and leaves when done. Keyboard summons it, a click elsewhere or Esc dismisses it.
3. **The app never touches an Anthropic credential.** No API-key field, no token, no login screen. The engine runs the Claude Agent SDK, which uses the `claude` the user already logged into in Terminal. If that login is missing, the app says "run `claude` in Terminal and log in" and nothing more. The previous version settled on this as the line that keeps a personal client inside Anthropic's terms; keep it.
4. **One window, dark glass.** No light mode. The desktop's colour coming through the blur is the app's colour. Nothing in the interface has a border; surfaces come apart by tint and by space.
5. **Every card leaves a working build.** A card that ends with the app not launching is not done.
6. **Fast, light and small.** OriCode is meant to be the quickest, smoothest agent window there is. With nothing working it idles at no CPU: nothing polls, animates or wakes the Mac unless the user is looking at it or waiting on it. A frame is never dropped under the pointer, a keystroke never waits on the disk or the engine, and nothing is added to the app or the engine that it doesn't need. A card that touches a path the user feels, launch, typing, scrolling a transcript, a turn streaming, measures it before and after, and says so in its Notes.

## Make targets

- `make run` builds the Debug app, OriCode Molten, and opens it beside the installed OriCode. Molten has its own bundle id and its own Application Support and Logs folders, so it never opens OriCode's threads, and `make run` quits only Molten.
- `make engine` type-checks the engine and stages it with production dependencies in `~/Library/Developer/OriCode/engine`.
- `make test` runs the engine's protocol tests and the Swift unit tests.
- `make app` builds Release, signs it ad hoc and copies it to `/Applications`, quitting the installed OriCode to replace it. Meriç runs it, in Terminal: a thread inside OriCode that ran it would end its own session mid-turn.
- `make release` publishes project.yml's MARKETING_VERSION as a GitHub release, notes from its CHANGELOG.md entry, and points `appcast.xml` at it, which every installed OriCode checks daily. It needs the OriCode certificate and the Sparkle key in the login keychain. Meriç runs it, in Terminal, like `make app`.

## Where things live

`App/` is the Swift app. `engine/` is the TypeScript sidecar the app spawns with `node engine/main.ts`, speaking newline-delimited JSON. `project.yml` generates `OriCode.xcodeproj` through XcodeGen (`brew install xcodegen`); the project file is gitignored, so never edit it.

SwiftTerm, the terminal, compiles a Metal shader, so Xcode's Metal Toolchain must be installed (`xcodebuild -downloadComponent MetalToolchain`), and it runs a package plugin, so every xcodebuild line passes `-skipPackagePluginValidation`.

Node 24 or newer is required. On this Mac the first `node` on the PATH is v22, so run engine commands with `PATH=/opt/homebrew/bin:$PATH`.
