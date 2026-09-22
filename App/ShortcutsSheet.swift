import SwiftUI

/// ⌘/ : every shortcut in one place.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Threads", [
            ("New thread", "⌘N"),
            ("New thread on its own branch", "⌘⇧N"),
            ("Add project", "⌘O"),
            ("Go to thread 1–9", "⌘1 … ⌘9"),
            ("Show or hide the thread list", "⌘B"),
            ("Rename thread", "⌘R"),
            ("Delete thread", "⌘⌫"),
        ]),
        ("Git", [
            ("Changes", "⌘⇧D"),
            ("Commit", "⌘Return"),
        ]),
        ("Conversation", [
            ("Send", "Return"),
            ("New line", "⇧Return"),
            ("Slash commands and skills", "/ at the start"),
            ("Stop", "⌘."),
            ("Allow what Claude asks", "Return"),
            ("Deny it, or close what's on top", "Esc"),
        ]),
        ("App", [
            ("Go to anything", "⌘K"),
            ("Find a file", "⌘P"),
            ("Settings", "⌘,"),
            ("These shortcuts", "⌘/"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(groups, id: \.0) { title, rows in
                    GridRow {
                        Text(title)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .padding(.top, title == groups.first?.0 ? 0 : 12)
                            .gridCellColumns(2)
                    }
                    ForEach(rows, id: \.0) { name, keys in
                        GridRow {
                            Text(name).font(Type.body).foregroundStyle(Ink.primary)
                            Text(keys).font(Type.mono).foregroundStyle(Ink.secondary)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .tint(Color(white: 0.5))
            }
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(height: 0)
        }
        .padding(24)
        .frame(width: 420)
        .preferredColorScheme(.dark)
    }
}
