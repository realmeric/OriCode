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
        CommandMenu("Threads") {
            ForEach(Array(model.chats.prefix(9).enumerated()), id: \.element.id) { index, chat in
                Button(chat.title) { model.pick(threadAt: index) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Menu("Project") {
                ForEach(model.projects) { project in
                    Button(project.name) { model.select(project) }
                }
            }
            Button("Delete Thread") {
                if let chat = model.chat { model.delete(chat) }
            }
            .disabled(model.chat == nil)
        }
    }
}
