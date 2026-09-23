import AppKit
import SwiftTerm
import SwiftUI

/// The terminal, summoned with ⌘J: it comes down from under the title bar over the transcript and
/// stops above the composer, which stays in view. ⌘J again, a click on the transcript, or Esc at
/// an idle prompt puts it away; while a program holds the shell, Esc is that program's.
struct TerminalOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let folder = model.workingFolder
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Terminal")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Ink.primary)
                if let folder {
                    Text(URL(filePath: folder).lastPathComponent).font(Type.mono).foregroundStyle(Ink.secondary)
                }
                if let branch = model.currentBranch?.branch, branch != "HEAD" {
                    Text(branch).font(Type.mono).foregroundStyle(Ink.faint)
                }
                Spacer()
                Button("Close") { model.closeTerminal() }
                    .buttonStyle(.plain)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .help("Close the terminal (⌘J)")
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            if let folder, let session = model.terminals.existing(for: folder) {
                TerminalPane(session: session)
                    // A shell that exited is replaced, and its successor needs a host of its own.
                    .id(ObjectIdentifier(session))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else if let folder, !FileManager.default.fileExists(atPath: folder) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("This thread's folder isn't there any more.")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                    Text(folder)
                        .font(Type.mono)
                        .foregroundStyle(Ink.faint)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            } else {
                Spacer(minLength: 0)
            }
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
        // A shell is started outside the body, and for the next folder when the thread changes.
        .task(id: folder) {
            if let folder { model.startTerminal(in: folder) }
        }
    }
}

/// Hosts a session's own view, which outlives the pane: hiding the terminal takes the view out of
/// the window, and the shell goes on.
private struct TerminalPane: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> Host {
        Host(terminal: session.view)
    }

    func updateNSView(_ host: Host, context: Context) {}

    final class Host: NSView {
        let terminal: NSView

        init(terminal: NSView) {
            self.terminal = terminal
            super.init(frame: terminal.frame)
            terminal.removeFromSuperview()
            addSubview(terminal)
        }

        required init?(coder: NSCoder) { nil }

        // Never down to nothing on the way in: a terminal made a column wide rewraps its
        // scrollback to that column, and it doesn't come back.
        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            if size.width >= 100, size.height >= 60 {
                terminal.frame = CGRect(origin: .zero, size: size)
            }
        }

        // The keys go to the shell as soon as it's in the window, not to the composer.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(terminal)
        }
    }
}
