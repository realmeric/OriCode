import SwiftUI

struct OriCodeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { model.newChat() }
                .keyboardShortcut("n")
                .disabled(model.project == nil)
            Button("Add Project…") { model.addProject() }
                .keyboardShortcut("o")
        }
        CommandGroup(before: .toolbar) {
            Button(model.drawerPinned ? "Hide Threads" : "Show Threads") { model.toggleDrawerPin() }
                .keyboardShortcut("\\")
            Divider()
        }
        CommandMenu("Thread") {
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!(model.chat.map { model.conversation(for: $0).running } ?? false))
            Divider()
            ForEach(Array(model.chats.prefix(9).enumerated()), id: \.element.id) { index, chat in
                Button(chat.title) { model.pick(threadAt: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            if !model.projects.isEmpty {
                Divider()
                Menu("Project") {
                    ForEach(model.projects) { project in
                        Button(project.name) { model.select(project) }
                    }
                }
            }
            Divider()
            Button("Delete Thread") {
                if let chat = model.chat { model.delete(chat) }
            }
            .disabled(model.chat == nil)
        }
    }
}
