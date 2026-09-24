# OriCode

KANBAN.md is the plan and the tracker. Work it the way its "How to work this board" section says.

## Rules that don't move

1. **Never hand-roll a control the platform already has.** `Picker`, `Toggle`, `Slider`, `Menu`, `List`, `TextField`, the `Settings` scene, `NSOpenPanel`, `UserNotifications`, native materials, the native window. The previous version of this app was a web view, and over a thousand lines went into redrawing dropdowns, toggles and window chrome that AppKit gives away. It still looked wrong. If a card starts to read as "build a custom X", the card is wrong; fix the card.
2. **No persistent panels.** The only things always on screen are the transcript and the composer. Threads, changes, files, settings: each slides over the same glass when called and leaves when done. Keyboard summons it, a click elsewhere or Esc dismisses it.
3. **The app never touches an Anthropic credential.** No API-key field, no token, no login screen. The engine runs the Claude Agent SDK, which uses the `claude` the user already logged into in Terminal. If that login is missing, the app says "run `claude` in Terminal and log in" and nothing more. The previous version settled on this as the line that keeps a personal client inside Anthropic's terms; keep it.
4. **One window, dark glass.** No light mode. The desktop's colour coming through the blur is the app's colour. Nothing in the interface has a border; surfaces come apart by tint and by space.
5. **Every card leaves a working build.** A card that ends with the app not launching is not done.

## Make targets

- `make run` builds the Debug app and opens it.
- `make engine` type-checks the engine and stages it with production dependencies in `~/Library/Developer/OriCode/engine`.
- `make test` runs the engine's protocol tests and the Swift unit tests.
- `make app` builds Release, signs it ad hoc and copies it to `/Applications`.

## Where things live

`App/` is the Swift app. `engine/` is the TypeScript sidecar the app spawns with `node engine/main.ts`, speaking newline-delimited JSON. `project.yml` generates `OriCode.xcodeproj` through XcodeGen (`brew install xcodegen`); the project file is gitignored, so never edit it.

SwiftTerm, the terminal, compiles a Metal shader, so Xcode's Metal Toolchain must be installed (`xcodebuild -downloadComponent MetalToolchain`), and it runs a package plugin, so every xcodebuild line passes `-skipPackagePluginValidation`.

Node 24 or newer is required. On this Mac the first `node` on the PATH is v22, so run engine commands with `PATH=/opt/homebrew/bin:$PATH`.
