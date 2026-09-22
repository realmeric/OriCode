# Changelog

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
