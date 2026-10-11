import SwiftUI

/// One edited file. While Witness is the review, the card shows the edit's first lines as the
/// review draws them and its header opens the review on that file; with Legacy chosen it is the
/// path and its counts, with the diff folded underneath.
struct DiffCard: View {
    @Environment(AppModel.self) private var model
    let call: ToolCall
    let cwd: String
    @AppStorage(ReviewDesign.key) private var design = ReviewDesign.witness
    @State private var open = false

    var body: some View {
        let diff = Diff.of(call, cwd: cwd)
        VStack(alignment: .leading, spacing: 0) {
            if design == .witness {
                Button {
                    model.openReview(at: call.file ?? "", line: diff?.line ?? 0)
                } label: {
                    header(diff, links: false)
                }
                .buttonStyle(.plain)
                .help("Review this file's changes")
                if let diff, !diff.lines.isEmpty {
                    WitnessDiff(diff: diff)
                        .equatable()
                        .padding(.bottom, 10)
                }
            } else {
                Button {
                    withAnimation(Motion.fade) { open.toggle() }
                } label: {
                    header(diff, links: true)
                }
                .buttonStyle(.plain)
                if open, let diff {
                    DiffLinesView(lines: diff.lines)
                        .transition(.opacity)
                }
            }
        }
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
    }

    /// The path and the counts. Legacy's path opens the file and its chevron says the card
    /// folds; Witness's header is one button, so its path is words.
    private func header(_ diff: Diff?, links: Bool) -> some View {
        HStack(spacing: 8) {
            if let path = ToolSummary.path(for: call) {
                let label = diff?.path ?? ToolSummary.relative(path, to: cwd)
                if links {
                    FileLink(path: path, label: label, cwd: cwd)
                        .font(Type.mono)
                        .foregroundStyle(Ink.primary)
                } else {
                    Text(label)
                        .font(Type.mono)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
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
            if links {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .font(Type.secondary)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .contentShape(.rect)
    }
}

struct Counts: View {
    let added: Int
    let deleted: Int
    /// Leaves out a side that's zero, where one number is all a line needs.
    var quiet = false

    var body: some View {
        HStack(spacing: 5) {
            if !quiet || added > 0 || deleted == 0 { Text("+\(added)").foregroundStyle(Ink.added) }
            if !quiet || deleted > 0 { Text("−\(deleted)").foregroundStyle(Ink.deleted) }
        }
        .font(Type.secondary.monospacedDigit())
    }
}
