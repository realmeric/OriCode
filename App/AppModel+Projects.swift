import AppKit
import Foundation
import SwiftData

extension AppModel {
    /// Fetched again only after a save that could have added or removed one: the composer asks
    /// for the open thread on every key, and a fetch each time was most of a keystroke's cost.
    var projects: [Project] {
        if let fetched, fetched.revision == revision { return fetched.projects }
        let projects = (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        fetched = (revision, projects)
        return projects
    }

    var project: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Every project's threads in one list, in the drawer's order: the drawer, ⌘1–9 and the
    /// Thread menu. A draft isn't one of them until its first message.
    var chats: [Chat] {
        projects.flatMap(\.chats).filter(\.started).sorted(by: Chat.drawerOrder)
    }

    /// Pinning puts a thread after the pinned ones; unpinning puts it back on top of the rest.
    func togglePin(_ chat: Chat) {
        if chat.pinned {
            chat.pinned = false
            chat.position = nil
        } else {
            chat.position = (chats.filter(\.pinned).compactMap(\.position).max() ?? -1) + 1
            chat.pinned = true
        }
        save()
    }

    /// A drag in the drawer. A row moves within the pinned threads or within the rest; one dropped
    /// above a pinned thread is pinned there, and a pinned one dropped below the rest's first row
    /// isn't pinned any more. Both groups then keep the order the drag left.
    func moveThreads(from source: IndexSet, to destination: Int) {
        var list = chats
        guard let first = source.first, list.indices.contains(first) else { return }
        let moving = list[first]
        let pinnedCount = list.filter(\.pinned).count
        moving.pinned = moving.pinned ? destination <= pinnedCount : destination < pinnedCount
        list.move(fromOffsets: source, toOffset: destination)
        for (index, chat) in list.filter(\.pinned).enumerated() { chat.position = Double(index) }
        for (index, chat) in list.filter({ !$0.pinned }).enumerated() { chat.position = Double(index) }
        save()
    }

    var chat: Chat? {
        guard let selectedChatID else { return nil }
        if let selected, (selected.revision, selected.project, selected.id) == (revision, selectedProjectID, selectedChatID) {
            return selected.chat
        }
        let chat = project?.chats.first { $0.id == selectedChatID }
        selected = (revision, selectedProjectID, selectedChatID, chat)
        return chat
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(at: url)
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path) else {
            say("\(url.lastPathComponent) isn't a git repository, so OriCode can't show the changes made there.")
            return
        }
        if let existing = projects.first(where: { $0.path == path }) {
            select(existing)
            return
        }
        let project = Project(name: url.lastPathComponent, path: path)
        project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
        context.insert(project)
        save()
        select(project)
    }

    func select(_ project: Project) {
        selectedProjectID = project.id
        selectedChatID = project.chats.max { $0.updatedAt < $1.updatedAt }?.id
    }

    /// Picking a thread picks its project, since the list holds every project's threads.
    func select(_ chat: Chat) {
        if let project = chat.project { selectedProjectID = project.id }
        selectedChatID = chat.id
    }

    /// Whether ⌘W closes the open thread rather than a window.
    var closesThread: Bool {
        mainWindowKey && chat != nil
    }

    /// ⌘W: the open thread goes back to the project's empty composer, the way Claude's app
    /// closes a session, and stays in the list. With none open it closes the window.
    func close() {
        if closesThread {
            if let chat { release(chat) }
            selectedChatID = nil
            return
        }
        let key = NSApp.keyWindow
        let window = key?.styleMask.contains(.titled) == true ? key : NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        window?.performClose(nil)
    }

    /// Lets go of a thread that isn't doing anything: its CLI in the engine, and its transcript
    /// here, which the store has and which is read again when the thread is opened.
    func release(_ chat: Chat) {
        guard let conversation = conversations[chat.id],
              !conversation.working, conversation.waitingAsk == nil, !conversation.holdsMessages
        else { return }
        conversation.flush()
        conversations[chat.id] = nil
        let id = chat.id.uuidString
        Task { _ = try? await engine.request("close", ["threadId": .string(id)]) }
    }

    /// At launch: threads from before drafts count as started when they have messages or their
    /// own worktree, and the drafts left from last time go, being empty.
    func clearDrafts() {
        let drafts = projects.flatMap(\.chats).filter { !$0.started }
        guard !drafts.isEmpty else { return }
        for chat in drafts {
            if !chat.events.isEmpty || chat.worktreeBranch != nil {
                chat.started = true
            } else {
                context.delete(chat)
            }
        }
        save()
    }

    /// Projects from before badges had colours get theirs the first time the app opens.
    func colourProjects() {
        let uncoloured = projects.filter { $0.colorIndex == nil }
        guard !uncoloured.isEmpty else { return }
        for project in uncoloured {
            project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
        }
        save()
    }

    /// ⌘N and New thread: the project's draft when it has one, so pressing it again and again
    /// doesn't pile up empty threads.
    func openNewThread() {
        if let draft = project?.chats.first(where: { !$0.started }) {
            selectedChatID = draft.id
        } else {
            newChat()
        }
        composerFocus += 1
    }

    /// A new thread, which stays a draft until its first message. A project keeps one draft at
    /// most: an older one is empty, and goes.
    @discardableResult
    func newChat() -> Chat? {
        guard let project else { return nil }
        for draft in project.chats where !draft.started {
            conversations[draft.id] = nil
            context.delete(draft)
        }
        let chat = Chat(project: project, permissionMode: startingPermissionMode)
        chat.model = startingModel
        let levels = option(for: chat)?.levels ?? []
        chat.effort = startingEffort.flatMap { levels.contains($0) ? $0 : nil }
        chat.fastMode = startingFast
        context.insert(chat)
        save()
        selectedChatID = chat.id
        return chat
    }

    func rename(_ chat: Chat, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        chat.title = trimmed
        chat.titleIsCustom = true
        save()
    }

    /// A worktree thread's folder is its own, and so is the shell in it, which goes with it.
    func ownFolder(of chat: Chat) -> String? {
        guard chat.worktreeBranch != nil, !projects.flatMap(\.chats).contains(where: { $0.id != chat.id && $0.cwd == chat.cwd }) else { return nil }
        return chat.cwd
    }

    func delete(_ chat: Chat) {
        let deleted = chat.id
        let wasSelected = deleted == selectedChatID
        endShells(of: chat)
        Task { _ = try? await engine.request("close", ["threadId": .string(deleted.uuidString)]) }
        // Its events can't find it through the conversation any more.
        conversations[deleted] = nil
        context.delete(chat)
        save()
        guard wasSelected else { return }
        // The next thread in the same project if there is one, so deleting doesn't switch projects.
        let rest = chats.filter { $0.id != deleted }
        if let next = rest.first(where: { $0.project?.id == selectedProjectID }) ?? rest.first {
            select(next)
        } else {
            selectedChatID = nil
        }
    }

    func save() {
        touch()
        do {
            try context.save()
        } catch {
            Engine.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
