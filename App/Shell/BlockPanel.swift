import AppKit
import SwiftUI

/// A block open over the conversation, its terminal drawn full. A program that takes the whole
/// screen, vim or less, opens its block here and puts it back in the thread when it lets go, and a
/// running block opens here to be typed into. Keys go to the program, Esc too; Close, ⌘J or a
/// click on the transcript put it back.
struct BlockPanel: View {
    @Environment(AppModel.self) private var model
    let block: ShellBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("$").foregroundStyle(Ink.faint)
                Text(block.command)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if block.running {
                    Button("Stop") { block.stop() }
                        .help("Stop the command (⌃C)")
                }
                Button("Close") { model.closeBlock() }
                    .help("Back into the thread (⌘J)")
            }
            .buttonStyle(.action(small: true))
            .font(Type.mono)
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 16)
            .frame(height: 36)
            // Only a running block opens, and a block keeps its view until it has ended.
            if let view = block.view {
                BlockTerminalPane(view: view, takesKeyboard: !model.keyboardTaken)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// Hosts a block's own view, which outlives the panel: closing it takes the view out of the
/// window, and the block goes on in the thread.
private struct BlockTerminalPane: NSViewRepresentable {
    let view: BlockTerminalView
    /// Not when the block opened by itself under ⌘K, ⌘P or a rename, which keep the keyboard
    /// until they go and hand it on.
    let takesKeyboard: Bool

    func makeNSView(context: Context) -> Host {
        Host(terminal: view, takesKeyboard: takesKeyboard)
    }

    func updateNSView(_ host: Host, context: Context) {}

    final class Host: NSView {
        let terminal: NSView
        let takesKeyboard: Bool

        init(terminal: NSView, takesKeyboard: Bool) {
            self.terminal = terminal
            self.takesKeyboard = takesKeyboard
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

        // The keys go to the program as soon as it's in the window, not to the composer.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if takesKeyboard { window?.makeFirstResponder(terminal) }
        }
    }
}
