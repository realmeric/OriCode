import AppKit
import SwiftUI

struct GoToEntry: Identifiable {
    enum Kind {
        case thread, project, action
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let run: @MainActor () -> Void
}

extension AppModel {
    var goToEntries: [GoToEntry] {
        let threads = projects
            .flatMap { project in project.chats.map { (project, $0) } }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .map { project, chat in
                GoToEntry(id: chat.id.uuidString, kind: .thread, title: chat.title, detail: project.name) { [weak self] in
                    self?.open(chatID: chat.id)
                }
            }
        let projectEntries = projects.map { project in
            GoToEntry(id: project.id.uuidString, kind: .project, title: project.name, detail: "Project") { [weak self] in
                self?.select(project)
            }
        }
        var actions: [GoToEntry] = [
            GoToEntry(id: "new", kind: .action, title: "New thread", detail: "⌘N") { [weak self] in self?.newChat() },
            GoToEntry(id: "branch", kind: .action, title: "New thread on its own branch", detail: "⌘⇧N") { [weak self] in self?.newWorktreeChat() },
            GoToEntry(id: "add", kind: .action, title: "Add project…", detail: "⌘O") { [weak self] in self?.addProject() },
            GoToEntry(id: "changes", kind: .action, title: "Changes", detail: "⌘⇧D") { [weak self] in self?.openChanges() },
            GoToEntry(id: "files", kind: .action, title: "Find a file", detail: "⌘P") { [weak self] in self?.toggleFileFinder() },
            GoToEntry(id: "threads", kind: .action, title: drawerPinned ? "Hide threads" : "Show threads", detail: "⌘B") { [weak self] in self?.toggleDrawerPin() },
            GoToEntry(id: "shortcuts", kind: .action, title: "Keyboard shortcuts", detail: "⌘/") { [weak self] in self?.showingShortcuts = true },
            GoToEntry(id: "settings", kind: .action, title: "Settings", detail: "⌘,") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            },
        ]
        if currentConversation?.running == true {
            actions.insert(GoToEntry(id: "stop", kind: .action, title: "Stop", detail: "⌘.") { [weak self] in self?.stop() }, at: 0)
        }
        return threads + projectEntries + actions
    }

    func toggleGoTo() {
        withAnimation(Motion.move) { goToShown.toggle() }
    }
}

/// ⌘K: threads, projects and actions, fuzzy-matched; arrows move, Return opens.
struct GoToSheet: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [GoToEntry] {
        Array(Fuzzy.rank(model.goToEntries, by: query) { "\($0.title) \($0.detail)" }.prefix(12))
    }

    var body: some View {
        let results = results
        VStack(alignment: .leading, spacing: 6) {
            TextField("Go to a thread, project or action", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Ink.primary)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .onKeyPress(.downArrow) {
                    selected = min(selected + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selected = max(selected - 1, 0)
                    return .handled
                }
                .onSubmit { open(results) }
                .onChange(of: query) { selected = 0 }
            if !results.isEmpty {
                ScrollViewReader { proxy in
                    List(Array(results.enumerated()), id: \.element.id) { index, entry in
                        Button {
                            selected = index
                            open(results)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(entry.kind))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Ink.faint)
                                    .frame(width: 14)
                                Text(entry.title)
                                    .font(Type.body)
                                    .foregroundStyle(Ink.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text(entry.detail)
                                    .font(Type.secondary)
                                    .foregroundStyle(Ink.faint)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .background(index == selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .id(entry.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(height: CGFloat(results.count) * 30 + 8)
                    .onChange(of: selected) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .padding(.bottom, results.isEmpty ? 0 : 6)
        .frame(width: 560)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
        // The field isn't in the window until the slide-in starts, so focus it a beat later.
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }

    private func open(_ results: [GoToEntry]) {
        guard results.indices.contains(selected) else { return }
        let entry = results[selected]
        model.toggleGoTo()
        entry.run()
    }

    private func icon(_ kind: GoToEntry.Kind) -> String {
        switch kind {
        case .thread: "bubble.left"
        case .project: "folder"
        case .action: "command"
        }
    }
}
