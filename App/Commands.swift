import SwiftUI

struct OriCodeCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { model.newChat() }
                .keyboardShortcut("n")
                .disabled(model.project == nil)
            Button("New Thread on Its Own Branch") { model.newWorktreeChat() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.project == nil)
            Button("Add Project…") { model.addProject() }
                .keyboardShortcut("o")
        }
        // One ⌘W for both: the open thread first, then the window. A disabled Close Thread
        // beside the system's Close held on to ⌘W, so the window never closed.
        CommandGroup(replacing: .saveItem) {
            Button(model.closesThread ? "Close Thread" : "Close") { model.close() }
                .keyboardShortcut("w")
        }
        CommandGroup(before: .toolbar) {
            Button(model.drawerPinned ? "Hide Threads" : "Show Threads") { model.toggleDrawerPin() }
                .keyboardShortcut("b")
            Button("Go To…") { model.toggleGoTo() }
                .keyboardShortcut("k")
            Button("Find File…") { model.toggleFileFinder() }
                .keyboardShortcut("p")
                .disabled(model.chat == nil)
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
                ForEach(ModelsPage.groups(model.models)) { group in
                    if group.title != nil { Divider() }
                    ForEach(group.models) { option in
                        Text(option.name).tag(option.id)
                    }
                }
            }
            if let option = model.models.first(where: { $0.id == modelBinding.wrappedValue }), !option.levels.isEmpty {
                Picker("Effort", selection: effortBinding) {
                    Text(model.defaultLevel(for: model.chat).map { "Default (\(ModelMenu.effortName($0)))" } ?? "Default").tag("")
                    ForEach(option.levels, id: \.self) { Text(ModelMenu.effortName($0)).tag($0) }
                }
            }
            Button(model.modelPickerShown ? "Hide Model and Effort" : "Model and Effort…") { model.modelPickerShown.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.project == nil)
            Button("Back to Defaults") { model.resetToDefaults(for: model.chat) }
                .disabled(model.project == nil || model.atDefaults(model.chat))
            Toggle("Fast Mode", isOn: fastBinding)
                .disabled(!(model.models.first { $0.id == modelBinding.wrappedValue }?.fast ?? false))
            Picker("Permission Mode", selection: modeBinding) {
                ForEach(PermissionModeOption.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button("Rename Thread…") {
                if let chat = model.chat { model.startRename(chat) }
            }
            .keyboardShortcut("r")
            .disabled(model.chat == nil)
            Button("Delete Thread…") { model.askToDelete(model.chat) }
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
            model.option(for: model.chat)?.id ?? ""
        } set: { id in
            model.setModel(id, for: model.chat)
        }
    }

    private var effortBinding: Binding<String> {
        Binding { (model.chat == nil ? model.startingEffort : model.chat?.effort) ?? "" } set: { model.setEffort($0.isEmpty ? nil : $0, for: model.chat) }
    }

    private var modeBinding: Binding<String> {
        Binding { model.chat?.permissionMode ?? model.startingPermissionMode } set: { model.setPermissionMode($0, for: model.chat) }
    }

    private var fastBinding: Binding<Bool> {
        Binding { model.chat?.fastMode ?? model.startingFast } set: { model.setFast($0, for: model.chat) }
    }
}
