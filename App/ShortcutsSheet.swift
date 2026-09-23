import SwiftUI

/// Every shortcut, for the ⌘/ sheet and Settings › Shortcuts alike.
enum ShortcutList {
    struct Row {
        let name: String
        let keys: String
    }

    struct Group {
        let title: String
        let rows: [Row]
    }

    static let groups: [Group] = [
        Group(title: "Threads", rows: [
            Row(name: "New thread", keys: "⌘N"),
            Row(name: "New thread on its own branch", keys: "⌘⇧N"),
            Row(name: "Add project", keys: "⌘O"),
            Row(name: "Go to thread 1–9", keys: "⌘1 … ⌘9"),
            Row(name: "Show or hide the thread list", keys: "⌘B"),
            Row(name: "Close the thread, then the window", keys: "⌘W"),
            Row(name: "Rename thread", keys: "⌘R"),
            Row(name: "Delete thread", keys: "⌘⌫"),
        ]),
        Group(title: "Git", rows: [
            Row(name: "Changes", keys: "⌘⇧D"),
            Row(name: "Commit", keys: "⌘Return"),
        ]),
        Group(title: "Conversation", rows: [
            Row(name: "Send", keys: "Return"),
            Row(name: "New line", keys: "⇧Return"),
            Row(name: "Slash commands and skills", keys: "/ at the start"),
            Row(name: "Stop", keys: "⌘."),
            Row(name: "Model and effort", keys: "⌘⇧M"),
            Row(name: "Allow what Claude asks", keys: "Return"),
            Row(name: "Deny it, or close what's on top", keys: "Esc"),
        ]),
        Group(title: "App", rows: [
            Row(name: "Command center", keys: "⌘K"),
            Row(name: "Next and previous thread", keys: "⌃Tab ⌃⇧Tab"),
            Row(name: "Find a file", keys: "⌘P"),
            Row(name: "Settings", keys: "⌘,"),
            Row(name: "These shortcuts", keys: "⌘/"),
        ]),
    ]
}

/// ⌘/ : every shortcut in one place.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups = ShortcutList.groups

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(groups, id: \.title) { group in
                    GridRow {
                        Text(group.title)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .padding(.top, group.title == groups.first?.title ? 0 : 12)
                            .gridCellColumns(2)
                    }
                    ForEach(group.rows, id: \.name) { row in
                        GridRow {
                            Text(row.name).font(Type.body).foregroundStyle(Ink.primary)
                            Text(row.keys).font(Type.mono).foregroundStyle(Ink.secondary)
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
