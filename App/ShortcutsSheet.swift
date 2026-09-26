import SwiftUI

/// Every shortcut, for the ⌘/ sheet and Settings › Shortcuts alike, grouped as the menus are.
/// An action's keys are whatever Shortcuts has for it now; a fixed row's never move.
enum ShortcutList {
    enum Row: Hashable {
        case action(ShortcutAction)
        case fixed(String, keys: String)

        var title: String {
            switch self {
            case .action(let action): action.title
            case .fixed(let title, _): title
            }
        }

        @MainActor func keys(_ shortcuts: Shortcuts) -> String {
            switch self {
            case .action(let action): shortcuts.label(action)
            case .fixed(_, let keys): keys
            }
        }
    }

    struct Group {
        let title: String
        let rows: [Row]
    }

    static let groups: [Group] = [
        Group(title: Build.name, rows: [
            .fixed("Settings", keys: "⌘,"),
        ]),
        Group(title: "File", rows: [
            .action(.newThread),
            .action(.newThreadOnBranch),
            .action(.addProject),
            .action(.close),
        ]),
        Group(title: "View", rows: [
            .action(.toggleThreads),
            .action(.commandCenter),
            .action(.shellPrompt),
            .action(.heads),
            .action(.findFile),
            .action(.review),
        ]),
        Group(title: "Thread", rows: [
            .action(.stop),
            .action(.switchBranch),
            .action(.nextThread),
            .action(.previousThread),
            .fixed("Go to Thread 1–9", keys: "⌘1 … ⌘9"),
            .action(.modelPicker),
            .action(.rename),
            .action(.delete),
        ]),
        Group(title: "Help", rows: [
            .action(.shortcuts),
        ]),
        Group(title: "Composer", rows: [
            .action(.send),
            .action(.queue),
            .action(.newLine),
            .fixed("Complete a command or path", keys: "Tab"),
            .fixed("Earlier messages and commands", keys: "↑ ↓"),
            .fixed("Leave an empty shell prompt", keys: "⌫"),
            .fixed("Slash commands and skills", keys: "/ at the start"),
            .fixed("Shell prompt", keys: "! at the start"),
            .fixed("Allow what the thread asks", keys: "Return"),
            .fixed("Deny it, or close what's on top", keys: "Esc"),
        ]),
        Group(title: "Review", rows: [
            .fixed("Next and previous hunk", keys: "↓ ↑  or  J K"),
            .fixed("Fold or open the file", keys: "← →"),
            .fixed("Mark reviewed, then the next", keys: "Space"),
            .fixed("Add a note", keys: "N"),
            .fixed("Take it back", keys: "⌫"),
            .fixed("Undo that", keys: "⌘Z"),
            .fixed("Open the file", keys: "O"),
            .fixed("Commit", keys: "⌘Return"),
        ]),
    ]
}

/// ⌘/ : every shortcut in one place, as it is now.
struct ShortcutsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private let groups = ShortcutList.groups

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    ForEach(groups, id: \.title) { group in
                        GridRow {
                            Text(group.title)
                                .font(Type.secondary)
                                .foregroundStyle(Ink.secondary)
                                .padding(.top, group.title == groups.first?.title ? 0 : 12)
                                .gridCellColumns(2)
                        }
                        ForEach(group.rows, id: \.self) { row in
                            GridRow {
                                Text(row.title).font(Type.body).foregroundStyle(Ink.primary)
                                Text(row.keys(model.shortcuts)).font(Type.mono).foregroundStyle(Ink.secondary)
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 560)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Button("") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
                .frame(height: 0)
        }
        .padding(24)
        .frame(width: 440)
        .preferredColorScheme(.dark)
    }
}
