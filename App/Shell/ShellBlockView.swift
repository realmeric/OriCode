import SwiftUI

/// A command from the shell prompt in the transcript: the line, then what it printed in the
/// terminal's colours, following the output while it runs. Stop sends ⌃C.
struct ShellBlockView: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let run: ShellRun
    /// What a block from an earlier launch printed, drawn once.
    @State private var stored: (screen: AttributedString, lines: Int)?

    var body: some View {
        let live = model.shellBlocks[id]
        let screen = live?.screen ?? stored?.screen ?? AttributedString()
        let lines = live?.lineCount ?? stored?.lines ?? 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("$").foregroundStyle(Ink.faint)
                Text(run.command)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                status(live)
            }
            .font(Type.mono)
            if lines > ShellRender.shown {
                Text("\(lines - ShellRender.shown) earlier lines")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
            }
            if !screen.characters.isEmpty {
                ScrollView {
                    Text(screen)
                        .font(Type.mono)
                        .foregroundStyle(Ink.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
                .defaultScrollAnchor(.bottom)
            }
        }
        .padding(12)
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
        // Out of view while it runs, the line under the composer takes its place.
        .onScrollVisibilityChange(threshold: 0.15) { model.shellsInView[id] = $0 }
        .task(id: run.output) {
            guard live == nil, !run.output.isEmpty else { return }
            let output = run.output
            let drawn = await Task.detached(priority: .userInitiated) {
                let lines = ShellRender.lines(ShellRender.replay(output))
                return (ShellRender.attributed(lines.suffix(ShellRender.shown)), lines.count)
            }.value
            stored = drawn
        }
    }

    @ViewBuilder
    private func status(_ live: ShellBlock?) -> some View {
        if let live, live.running {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini).tint(Ink.secondary)
                Button("Stop") { live.stop() }
                    .buttonStyle(.plain)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.primary)
                    .help("Stop the command (⌃C)")
            }
        } else if live == nil, run.endedAt == nil {
            Text("stopped when OriCode quit").font(Type.secondary).foregroundStyle(Ink.faint)
        } else if let code = live?.exitCode ?? run.exitCode, code != 0 {
            Text("exit \(code)").font(Type.secondary).foregroundStyle(Ink.faint)
        }
    }
}
