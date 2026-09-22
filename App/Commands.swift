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
            Button(model.changesShown ? "Hide Changes" : "Changes") { model.toggleChanges() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.chat == nil)
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
            Picker("Model", selection: modelBinding) {
                ForEach(model.models) { option in
                    Text(option.name).tag(option.id)
                }
            }
            if let efforts = model.models.first(where: { $0.id == modelBinding.wrappedValue })?.efforts, !efforts.isEmpty {
                Picker("Effort", selection: effortBinding) {
                    Text("Default").tag("")
                    ForEach(efforts, id: \.self) { Text(ModelMenu.effortName($0)).tag($0) }
                }
            }
            Picker("Permission Mode", selection: modeBinding) {
                ForEach(PermissionModeOption.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button("Rename Thread…") {
                if let chat = model.chat { model.startRename(chat) }
            }
            .keyboardShortcut("r")
            .disabled(model.chat == nil)
            Button("Delete Thread…") { model.deletingChat = model.chat }
                .keyboardShortcut(.delete)
                .disabled(model.chat == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showingShortcuts = true }
                .keyboardShortcut("/")
        }
    }

    private var modelBinding: Binding<String> {
        Binding {
            model.chat?.model ?? model.lastModel ?? model.models.first?.id ?? ""
        } set: { id in
            model.setModel(id, for: model.chat)
        }
    }

    private var effortBinding: Binding<String> {
        Binding { model.chat?.effort ?? "" } set: { model.setEffort($0.isEmpty ? nil : $0, for: model.chat) }
    }

    private var modeBinding: Binding<String> {
        Binding { model.chat?.permissionMode ?? model.lastPermissionMode } set: { model.setPermissionMode($0, for: model.chat) }
    }
}
