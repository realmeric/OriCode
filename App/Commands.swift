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
            // .custom keeps it on the backslash key; automatic localization moved it onto
            // the comma on Turkish-QWERTY-PC, on top of Settings.
            Button(model.drawerPinned ? "Hide Threads" : "Show Threads") { model.toggleDrawerPin() }
                .keyboardShortcut("\\", modifiers: .command, localization: .custom)
            Divider()
        }
        CommandMenu("Thread") {
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!(model.currentConversation?.running ?? false))
            Button("Compact") { model.send("/compact") }
                .disabled(model.chat?.sessionId == nil || (model.currentConversation?.running ?? true))
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
