import Link
import SwiftUI

/// A new thread: the project it starts in, the one new threads start in unless another is picked,
/// and its first message. The Mac makes it on Settings › New threads' defaults.
struct NewThreadSheet: View {
    @Environment(PhoneClient.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// The command sent, for home to push the thread once the Mac names it.
    @Binding var sent: String?
    @State private var project: UUID?
    @State private var text = ""
    @FocusState private var typing: Bool

    private var projects: [ProjectInfo] {
        store.projects.values.sorted { $0.order < $1.order }
    }

    private var picked: ProjectInfo? {
        project.flatMap { store.projects[$0] } ?? projects.first(where: \.starts) ?? projects.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Menu {
                ForEach(projects) { option in
                    Button(option.name) { project = option.id }
                }
            } label: {
                HStack(spacing: 8) {
                    Badge(project: picked)
                    Text(picked?.name ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.secondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Ink.faint)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($typing)
                    .foregroundStyle(Ink.primary)
                    .padding(.vertical, 10)
                    .padding(.leading, 16)
                let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(empty ? 0.4 : 0.92), in: .circle)
                }
                .disabled(empty)
                .accessibilityLabel("Send")
                .padding(6)
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationBackground(.black)
        .onAppear { typing = true }
    }

    private func send() {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sent = store.send(.open(project: picked?.id, text: text))
        dismiss()
    }
}
