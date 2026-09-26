import SwiftUI

struct OriCodeCommands: Commands {
    let model: AppModel
    let updates: Updates

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            if updates.enabled {
                Button("Check for Updates…") { updates.check() }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Thread") { model.openNewThread() }
                .keyboardShortcut(shortcuts.key(.newThread))
                .disabled(model.project == nil)
            Button("New Thread on Its Own Branch") { model.newWorktreeChat() }
                .keyboardShortcut(shortcuts.key(.newThreadOnBranch))
                .disabled(model.project == nil)
            Button("Add Project…") { model.addProject() }
                .keyboardShortcut(shortcuts.key(.addProject))
        }
        // One ⌘W for both: the open thread first, then the window. A disabled Close Thread
        // beside the system's Close held on to ⌘W, so the window never closed.
        CommandGroup(replacing: .saveItem) {
            Button(model.closesThread ? "Close Thread" : "Close") { model.close() }
                .keyboardShortcut(shortcuts.key(.close))
        }
        CommandGroup(before: .toolbar) {
            Button(model.drawerPinned ? "Hide Threads" : "Show Threads") { model.toggleDrawerPin() }
                .keyboardShortcut(shortcuts.key(.toggleThreads))
            Button("Command Center…") { model.toggleCommandCenter() }
                .keyboardShortcut(shortcuts.key(.commandCenter))
            Button(model.shellPrompt ? "Leave Shell Prompt" : "Shell Prompt") { model.toggleShellPrompt() }
                .keyboardShortcut(shortcuts.key(.shellPrompt))
                .disabled(model.project == nil)
            Button(model.headsShown ? "Hide Heads" : "Show Heads") { model.toggleHeads() }
                .keyboardShortcut(shortcuts.key(.heads))
                .disabled(model.chat == nil)
            Button("Find File…") { model.toggleFileFinder() }
                .keyboardShortcut(shortcuts.key(.findFile))
                .disabled(model.chat == nil)
            Button(model.reviewShown ? "Hide Review" : "Review Changes") { model.toggleReview() }
                .keyboardShortcut(shortcuts.key(.review))
                .disabled(model.project == nil)
            Divider()
        }
        CommandMenu("Thread") {
            Button("Stop") { model.stop() }
                .keyboardShortcut(shortcuts.key(.stop))
                .disabled(!(model.currentConversation?.running ?? false))
            Button("Compact") { model.send("/compact") }
                .disabled(model.chat?.sessionId == nil || (model.currentConversation?.running ?? true))
            Divider()
            Button("Switch Branch…") { model.openBranchSwitcher() }
                .keyboardShortcut(shortcuts.key(.switchBranch))
                .disabled(model.project == nil)
            Button("Next Thread") { model.stepThread(1) }
                .keyboardShortcut(shortcuts.key(.nextThread))
                .disabled(model.chats.count < 2)
            Button("Previous Thread") { model.stepThread(-1) }
                .keyboardShortcut(shortcuts.key(.previousThread))
                .disabled(model.chats.count < 2)
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
                ForEach(model.modelGroups) { group in
                    if group.id != model.modelGroups.first?.id { Divider() }
                    ForEach(group.models.filter { $0.needs == nil }) { option in
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
                .keyboardShortcut(shortcuts.key(.modelPicker))
                .disabled(model.project == nil)
            Button("Back to Defaults") { model.resetToDefaults(for: model.chat) }
                .disabled(model.project == nil || model.atDefaults(model.chat))
            Toggle("Fast Mode", isOn: fastBinding)
                .disabled(!(model.models.first { $0.id == modelBinding.wrappedValue }?.fast ?? false))
            Picker("Permission Mode", selection: modeBinding) {
                ForEach(PermissionModeOption.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Divider()
            Button(model.chat?.pinned == true ? "Unpin Thread" : "Pin Thread") {
                if let chat = model.chat { withAnimation(Motion.move) { model.togglePin(chat) } }
            }
            .disabled(model.chat?.started != true)
            Button("Rename Thread…") {
                if let chat = model.chat { model.startRename(chat) }
            }
            .keyboardShortcut(shortcuts.key(.rename))
            .disabled(model.chat == nil)
            Button("Delete Thread…") { model.askToDelete(model.chat) }
                .keyboardShortcut(shortcuts.key(.delete))
                .disabled(model.chat == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.showingShortcuts = true }
                .keyboardShortcut(shortcuts.key(.shortcuts))
        }
    }

    private var shortcuts: Shortcuts { model.shortcuts }

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
