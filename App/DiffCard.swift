import SwiftUI

/// One edited file: the path and its counts, with the diff folded underneath.
struct DiffCard: View {
    let call: ToolCall
    let cwd: String
    @State private var open = false

    var body: some View {
        let diff = Diff.of(call, cwd: cwd)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    if let path = ToolSummary.path(for: call) {
                        FileLink(path: path, label: diff?.path ?? ToolSummary.relative(path, to: cwd))
                            .font(Type.mono)
                            .foregroundStyle(Ink.primary)
                    } else {
                        Text(ToolSummary.line(for: call, cwd: cwd))
                            .font(Type.mono)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                    }
                    if call.isError {
                        Text("failed").foregroundStyle(Ink.faint)
                    } else if call.result == nil {
                        ProgressView().controlSize(.mini)
                    } else if let diff {
                        Counts(added: diff.added, deleted: diff.deleted)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .font(Type.secondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if open, let diff {
                DiffLinesView(lines: diff.lines)
                    .transition(.opacity)
            }
        }
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

struct Counts: View {
    let added: Int
    let deleted: Int

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(Ink.added)
            Text("−\(deleted)").foregroundStyle(Ink.deleted)
        }
        .font(Type.secondary.monospacedDigit())
    }
}
