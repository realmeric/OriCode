import SwiftUI

/// ⌘⇧D: what changed, ticked for the commit, with a message and Commit and Push.
struct ChangesSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var changes = model.changes
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Changes")
                    .font(Type.body.weight(.medium))
                    .foregroundStyle(Ink.primary)
                if let info = model.currentBranch {
                    Text(info.branch).font(Type.mono).foregroundStyle(Ink.secondary)
                    if info.ahead > 0 { Text("↑\(info.ahead)").font(Type.mono).foregroundStyle(Ink.faint) }
                }
                Spacer()
                Button("Close") { model.closeChanges() }
                    .buttonStyle(.plain)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            if changes.files.isEmpty {
                Text("Nothing to commit.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List(changes.files) { file in
                    Toggle(isOn: Binding(
                        get: { changes.picked.contains(file.path) },
                        set: { if $0 { changes.picked.insert(file.path) } else { changes.picked.remove(file.path) } })
                    ) {
                        HStack(spacing: 8) {
                            Text(file.status == "?" ? "new" : file.status)
                                .font(Type.mono)
                                .foregroundStyle(file.status == "D" ? Ink.deleted : file.status == "?" || file.status == "A" ? Ink.added : Ink.secondary)
                                .frame(width: 28, alignment: .leading)
                            Text(file.path)
                                .font(Type.mono)
                                .foregroundStyle(Ink.primary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(Color(white: 0.55))
                .frame(height: min(CGFloat(changes.files.count) * 28 + 8, 220))
            }
            TextField("Commit message", text: $changes.message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
                .lineLimit(2...8)
                .padding(10)
                .background(Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                if let busy = changes.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(Type.secondary).foregroundStyle(Ink.secondary)
                } else if let problem = changes.problem {
                    Text(problem).font(Type.secondary).foregroundStyle(Ink.secondary).lineLimit(2)
                }
                Spacer()
                Button("Write message") { model.writeCommitMessage() }
                    .disabled(changes.picked.isEmpty || changes.busy != nil)
                Button("Commit") { model.commitChanges() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(changes.picked.isEmpty || changes.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || changes.busy != nil)
                Button("Push") { model.pushChanges() }
                    .disabled(changes.busy != nil || (model.currentBranch.map { $0.upstream && $0.ahead == 0 } ?? true))
            }
            .tint(Color(white: 0.5))
        }
        .padding(16)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}
