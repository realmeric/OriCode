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
            ActionForm(action: action, projects: model.projects) { store.save($0) }
        }
        .onAppear { store.refresh() }
        Text("Actions are kept in Application Support/\(Build.folder)/actions.json, never in a project, and have no keys of their own.")
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
            Text([action.runs == .quietly ? "Quietly" : "In the thread", action.asks ? "asks first" : nil, project].compactMap { $0 }.joined(separator: " · "))
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
    let save: (CustomAction) -> Void
    @Environment(\.dismiss) private var dismiss

    private var ready: Bool {
        !action.name.trimmingCharacters(in: .whitespaces).isEmpty && !action.command.trimmingCharacters(in: .whitespaces).isEmpty
            && ActionLine.problem(in: action.command) == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $action.name, prompt: Text("Stash changes"))
                TextField("Command", text: $action.command, prompt: Text("git stash push"), axis: .vertical)
                    .font(Type.mono)
                    .lineLimit(2...8)
                if let problem = ActionLine.problem(in: action.command) {
                    Text(problem)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                }
                Picker("Runs", selection: $action.runs) {
                    Text("In the thread").tag(CustomAction.Runs.terminal)
                    Text("Quietly, with its last line as a note").tag(CustomAction.Runs.quietly)
                }
                Toggle("Ask before running", isOn: $action.asks)
                Picker("Projects", selection: $action.project) {
                    Text("Every project").tag(UUID?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                    if let id = action.project, !projects.contains(where: { $0.id == id }) {
                        Text("A project that's gone").tag(Optional(id))
                    }
                }
                Section {
                    Text("{cwd} {project} {projectName} {branch} {thread} {session} {input}")
                        .font(Type.mono)
                        .textSelection(.enabled)
                } footer: {
                    Text("Each value arrives quoted, inside quotes of your own too, so nothing in it runs. {input} is asked for in ⌘K when the action runs, and an action whose value is missing, like a branch outside a repository, can't run there.")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
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
