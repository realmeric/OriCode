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
        VStack(alignment: .leading, spacing: 16) {
            Menu {
                Picker("", selection: Binding(get: { picked?.id }, set: { project = $0 })) {
                    ForEach(projects) { option in
                        Text(option.name).tag(Optional(option.id))
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Badge(project: picked)
                    Text(picked?.name ?? "")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Ink.faint)
                }
            }
            .buttonStyle(.glass)
            Composer(text: $text, lines: 8, typing: $typing, send: send)
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium])
        .onAppear { typing = true }
    }

    private func send() {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        sent = store.send(.open(project: picked?.id, text: text))
        dismiss()
    }
}
