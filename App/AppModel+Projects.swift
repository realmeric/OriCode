import AppKit
import Foundation
import SwiftData

extension AppModel {
    /// Fetched again only after a save that could have added or removed one: the composer asks
    /// for the open thread on every key, and a fetch each time was most of a keystroke's cost.
    var projects: [Project] {
        if let fetched, fetched.revision == revision { return fetched.projects }
        let all = (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        // No folder comes after the folders, wherever projects are listed.
        let projects = all.filter { !$0.isNoFolder } + all.filter(\.isNoFolder)
        fetched = (revision, projects)
        return projects
    }

    var project: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Every project's threads in one list, in the drawer's order: the drawer, ⌘1–9 and the
    /// Thread menu. A draft isn't one of them until its first message.
    /// Under the drawer's filter, when it has one.
    var chats: [Chat] {
        // The archived ones, when they're what's asked for, the latest worked on first.
        if drawerFilter == .archived { return archivedChats }
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }.sorted(by: Chat.drawerOrder)
        switch drawerFilter {
        case .all: return all
        case .project(let id): return all.filter { $0.project?.id == id }
        case .working: return all.filter { conversations[$0.id]?.working == true }
        case .waiting: return all.filter { conversations[$0.id]?.waitingAsk != nil }
        case .archived: return []
        }
    }

    /// The archived threads, the latest worked on first, for Settings › Archive.
    var archivedChats: [Chat] {
        projects.flatMap(\.chats).filter(\.archived).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Takes a thread out of the drawer and keeps everything of it: its transcript, its session,
    /// its worktree. Its CLI is let go, and a thread at work is stopped first by hand.
    func archive(_ chat: Chat) {
        guard conversations[chat.id]?.running != true else {
            say("Stop the thread before archiving it")
            return
        }
        let archived = chat.id
        let wasSelected = archived == selectedChatID
        if archived == besideChatID { besideChatID = nil }
        endShells(of: chat)
        Task { _ = try? await engine.request("close", ["threadId": .string(archived.uuidString)]) }
        conversations[archived] = nil
        composers[archived] = nil
        chat.archived = true
        chat.pinned = false
        chat.position = nil
        save()
        guard wasSelected, !besideTakesWindow() else { return }
        if let next = chats.first(where: { $0.project?.id == selectedProjectID }) ?? chats.first {
            select(next)
        } else {
            selectedChatID = nil
        }
    }

    /// Back into the drawer, on top of the threads that aren't pinned, and open.
    func restore(_ chat: Chat) {
        chat.archived = false
        save()
        drawerFilter = .all
        select(chat)
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
        // A filtered list shows some of the threads, and an order among those isn't one among all.
        guard drawerFilter == .all else { return }
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

    /// Where No folder's threads work: a folder of the app's own that it puts nothing in. Not
    /// home, which the composer's `@`, ⌘P and the review would each walk the whole of; from here an
    /// agent still reaches anything on the Mac by its full path, under the thread's permissions.
    var noFolderURL: URL {
        support.appending(path: "No Folder", directoryHint: .isDirectory).standardizedFileURL
    }

    /// The No folder project, made with its folder the first time something asks for it and found
    /// again after that. A support folder that moved takes the project with it; a thread from
    /// before keeps the folder it had.
    func noFolderProject() -> Project {
        let path = noFolderURL.path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        if let existing = projects.first(where: \.isNoFolder) {
            if existing.path != path {
                existing.path = path
                save()
            }
            return existing
        }
        let project = Project(name: Project.noFolderName, path: path)
        project.id = Project.noFolderID
        context.insert(project)
        save()
        return project
    }

    /// New thread without a folder: No folder's draft, or a new thread there.
    func openThreadWithoutFolder() {
        selectedProjectID = noFolderProject().id
        openLocalThread()
    }

    func select(_ project: Project) {
        let left = self.project
        selectedProjectID = project.id
        selectedChatID = project.chats.max { $0.updatedAt < $1.updatedAt }?.id
        leave(left)
    }

    /// Picking a thread picks its project, since the list holds every project's threads.
    func select(_ chat: Chat) {
        let left = project
        if let project = chat.project { selectedProjectID = project.id }
        selectedChatID = chat.id
        leave(left)
    }

    /// No folder with nothing sent in it goes when another project is opened over it: a model or
    /// a mode picked before the first folder was added made it, and it would stay in every list
    /// after. With a thread that was started it's the user's, and stays.
    private func leave(_ left: Project?) {
        guard let left, left.isNoFolder, left.id != selectedProjectID, !left.chats.contains(where: \.started) else { return }
        // What was typed in its draft began in the window with no thread open, and goes back
        // there rather than away with the draft, unless something has been typed there since.
        if looseComposer.isEmpty, let typed = left.chats.compactMap({ composers[$0.id] }).first(where: { !$0.isEmpty }) {
            looseComposer = typed
            composerShowsOpenThread()
        }
        // It comes back with the same id, so an action kept to it stays kept to it.
        remove(left, forgettingActions: false)
    }

    /// Whether ⌘W closes the open thread rather than a window.
    var closesThread: Bool {
        mainWindowKey && chat != nil
    }

    /// ⌘W: the open thread goes back to the project's empty composer, the way Claude's app
    /// closes a session, and stays in the list; with another beside it, that one takes the
    /// window. With none open it closes the window.
    func close() {
        if closesThread {
            let closed = chat
            if !besideTakesWindow() { selectedChatID = nil }
            if let closed { release(closed) }
            return
        }
        let key = NSApp.keyWindow
        let window = key?.styleMask.contains(.titled) == true ? key : NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        window?.performClose(nil)
    }

    /// Lets go of a thread that isn't doing anything: its CLI in the engine, and its transcript
    /// here, which the store has and which is read again when the thread is opened.
    func release(_ chat: Chat) {
        guard !inView(chat.id), let conversation = conversations[chat.id],
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
        let uncoloured = projects.filter { $0.colorIndex == nil && !$0.isNoFolder }
        guard !uncoloured.isEmpty else { return }
        for project in uncoloured {
            project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
        }
        save()
    }

    /// A thread in the project's folder: the project's draft when it has one, so pressing it again and again
    /// doesn't pile up empty threads.
    func openLocalThread() {
        if let draft = project?.chats.first(where: { !$0.started }) {
            selectedChatID = draft.id
        } else {
            newChat()
        }
        composerFocus += 1
    }

    /// A new thread, which stays a draft until its first message. A project keeps one draft at
    /// most: an older one is empty, and goes. With no project open it's a thread without a
    /// folder, so the first message needs no folder picked.
    @discardableResult
    func newChat() -> Chat? {
        // What's in the composer where no thread has begun, with none open or in the draft this
        // one takes the place of, is for the thread it starts: text typed, a picture dropped or
        // a prompt opened before the first message, or before a model pick, stays in the field.
        var typed: ComposerState?
        if chat == nil {
            typed = looseComposer
            looseComposer = ComposerState()
        }
        let project = project ?? noFolderProject()
        if selectedProjectID != project.id { selectedProjectID = project.id }
        for draft in project.chats where !draft.started {
            conversations[draft.id] = nil
            if typed == nil { typed = composers[draft.id] }
            composers[draft.id] = nil
            context.delete(draft)
        }
        let chat = Chat(project: project, permissionMode: startingPermissionMode)
        chat.provider = startingProvider
        chat.model = startingModel
        let levels = option(for: chat)?.efforts ?? []
        chat.effort = startingEffort.flatMap { levels.contains($0) ? $0 : nil }
        chat.fastMode = startingFast
        context.insert(chat)
        save()
        if let typed { composers[chat.id] = typed }
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
        if deleted == besideChatID { besideChatID = nil }
        endShells(of: chat)
        // A thread it opened that still works in its worktree keeps it, as its own from here.
        if let branch = chat.worktreeBranch, let heir = projects.flatMap(\.chats).first(where: { $0.id != deleted && $0.cwd == chat.cwd && $0.worktreeBranch == nil }) {
            heir.worktreeBranch = branch
        }
        Task { _ = try? await engine.request("close", ["threadId": .string(deleted.uuidString)]) }
        // Its events can't find it through the conversation any more.
        conversations[deleted] = nil
        composers[deleted] = nil
        SentPictures.standard.forget(thread: deleted)
        context.delete(chat)
        save()
        guard wasSelected, !besideTakesWindow() else { return }
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

    /// Stores a change to one of a stored thread's own settings, a level, a mode, fast or
    /// workflows, which views read from the thread itself. Moving the revision as save() does
    /// made every view that reads the open thread or the projects draw and fetch again, the
    /// whole window, in the frame a click in the picker starts its animation.
    func keep() {
        do {
            try context.save()
        } catch {
            Engine.logger.error("save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
