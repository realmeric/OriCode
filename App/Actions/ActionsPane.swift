import AppKit
import SwiftUI

/// Settings › Actions: your own ⌘K rows, in the order ⌘K lists them, each edited in a sheet.
struct ActionsPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: CustomAction?

    var body: some View {
        let store = model.customActions
        PaneTitle(text: "Actions")
        if let problem = store.problem {
            SectionHeading("actions.json")
            SettingsCard {
                SettingsRow(title: "The file didn't read", detail: problem) {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.file]) }
                        .buttonStyle(.action)
                }
            }
        }
        SectionHeading("In ⌘K")
        SettingsCard {
            ForEach(Array(store.actions.enumerated()), id: \.element.id) { index, action in
                ActionRow(action: action, project: projectName(action.project)) {
                    Button("Edit…") { editing = action }
                    Button("Duplicate") {
                        var copy = action
                        copy.id = UUID()
                        copy.name += " copy"
                        store.save(copy)
                    }
                    Divider()
                    Button("Move Up") { store.move(action, up: true) }
                        .disabled(index == 0)
                    Button("Move Down") { store.move(action, up: false) }
                        .disabled(index == store.actions.count - 1)
                    Divider()
                    Button("Delete", role: .destructive) { store.remove(action) }
                }
            }
            HStack {
                Button("Add Action…") { editing = CustomAction(name: "", command: "") }
                    .buttonStyle(.action)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.file]) }
                    .buttonStyle(.plain)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .disabled(store.problem != nil)
        }
        .sheet(item: $editing) { action in
            ActionForm(action: action, projects: model.projects, commands: model.commandChoices, refusal: { model.refusal($0, for: $1) }) { store.save($0) }
        }
        .onAppear { store.refresh() }
        Text("An action is a line for your shell, or one of OriCode's own commands under your name, and either can have a key of its own. They're kept in Application Support/\(Build.folder)/actions.json, never in a project, and that file can be edited by hand.")
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
            .padding(.top, 10)
    }
}

extension ActionsPane {
    private func projectName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return model.projects.first { $0.id == id }?.name ?? "a project that's gone"
    }
}

private struct ActionRow<Actions: View>: View {
    let action: CustomAction
    let project: String?
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(action.name).font(.system(size: 14)).foregroundStyle(Ink.primary)
                Text(action.command)
                    .font(Type.mono)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Text([action.keys?.label, action.runs == .builtIn ? "OriCode's command" : action.runs == .quietly ? "Quietly" : "In the thread",
                  action.asks && action.runs != .builtIn ? "asks first" : nil, project].compactMap { $0 }.joined(separator: " · "))
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .fixedSize()
            Menu("Actions", systemImage: "ellipsis.circle") { actions }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// One action in a form: its name, the line with its placeholders, where it runs, whether it
/// asks first and which projects have it.
private struct ActionForm: View {
    @State var action: CustomAction
    let projects: [Project]
    /// ⌘K's own commands, which an action can stand for.
    let commands: [(id: String, title: String)]
    let refusal: (KeyCombo, CustomAction) -> String?
    let save: (CustomAction) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The next key-down is the action's key.
    @State private var recording = false
    @State private var monitor: Any?
    @State private var refused: String?

    private var ready: Bool {
        !action.name.trimmingCharacters(in: .whitespaces).isEmpty && !action.command.trimmingCharacters(in: .whitespaces).isEmpty
            && (action.runs == .builtIn || ActionLine.problem(in: action.command) == nil)
    }

    private func record() {
        stop()
        refused = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53, EventModifiers(event.modifierFlags).isEmpty {
                stop()
            } else if let combo = KeyCombo(event) {
                refused = refusal(combo, action)
                if refused == nil {
                    action.keys = combo
                    stop()
                }
            } else {
                refused = "That key can't be a shortcut"
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $action.name, prompt: Text("Stash changes"))
                Picker("Runs", selection: $action.runs) {
                    Text("A shell line, in the thread").tag(CustomAction.Runs.terminal)
                    Text("A shell line, quietly, with its last line as a note").tag(CustomAction.Runs.quietly)
                    Text("One of OriCode's own commands").tag(CustomAction.Runs.builtIn)
                }
                if action.runs == .builtIn {
                    Picker("Command", selection: $action.command) {
                        if !commands.contains(where: { $0.id == action.command }) {
                            Text(action.command.isEmpty ? "Choose one" : action.command).tag(action.command)
                        }
                        ForEach(commands, id: \.id) { command in
                            Text(command.title).tag(command.id)
                        }
                    }
                } else {
                    TextField("Command", text: $action.command, prompt: Text("git stash push"), axis: .vertical)
                        .font(Type.mono)
                        .lineLimit(2...8)
                    if let problem = ActionLine.problem(in: action.command) {
                        Text(problem)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                    }
                    Toggle("Ask before running", isOn: $action.asks)
                }
                LabeledContent("Key") {
                    HStack(spacing: 8) {
                        if let refused {
                            Text(refused).font(Type.secondary).foregroundStyle(Ink.secondary)
                        }
                        Button(recording ? "Press a key…" : action.keys?.label ?? "Record…") { recording ? stop() : record() }
                        if action.keys != nil, !recording {
                            Button("Clear") { action.keys = nil }
                        }
                    }
                }
                Picker("Projects", selection: $action.project) {
                    Text("Every project").tag(UUID?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                    if let id = action.project, !projects.contains(where: { $0.id == id }) {
                        Text("A project that's gone").tag(Optional(id))
                    }
                }
                if action.runs != .builtIn {
                Section {
                    Text("{cwd} {project} {projectName} {branch} {thread} {session} {input}")
                        .font(Type.mono)
                        .textSelection(.enabled)
                } footer: {
                    Text("Each value arrives quoted, inside quotes of your own too, so nothing in it runs. {input} is asked for in ⌘K when the action runs, and an action whose value is missing, like a branch outside a repository, can't run there.")
                }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .onDisappear { stop() }
            .onChange(of: action.runs) { before, now in
                // A shell line isn't a command's id, nor the other way round.
                if (before == .builtIn) != (now == .builtIn) { action.command = "" }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(action)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready)
            }
            .padding(20)
        }
        .frame(width: 540)
    }
}
