import AppKit
import Foundation
import SwiftData

/// How long a main thread is left alone before it goes to the archive by itself, in days as
/// Settings › Archive stores them, 0 for never. Nothing is lost: a thread keeps its transcript, its
/// session and its worktree, and Restore brings it back.
enum AutoArchive {
    static let key = "archiveOldThreads"
    static let standard = "14"
    static let choices = [(word: "two_weeks", stored: standard), (word: "a_week", stored: "7"), (word: "a_month", stored: "30"), (word: "never", stored: "0")]

    static var days: Int { Int(UserDefaults.standard.string(forKey: key) ?? standard) ?? 0 }
}

extension AppModel {
    /// Fetched again only after a save that could have added or removed one: the composer asks
    /// for the open thread on every key, and a fetch each time was most of a keystroke's cost.
    var projects: [Project] {
        if let fetched, fetched.revision == revision { return fetched.projects }
        let all = (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        // No folder comes after the folders, wherever projects are listed.
        let projects = all.filter { !$0.isNoFolder } + all.filter(\.isNoFolder)
        fetched = (revision, projects)
        initials = Project.initials(of: projects)
        return projects
    }

    var project: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    /// Every project's top threads in one list, a project's together, in the drawer's order: the
    /// drawer, ⌘1–9, ⌃Tab and the Thread menu. A draft isn't one of them until its first message,
    /// and a thread under another isn't one at all: ⌘⇧I, ⌘K and the lines in transcripts reach
    /// those. Under the drawer's filter, when it has one.
    var chats: [Chat] {
        // The archived ones, when they're what's asked for, the latest worked on first.
        Chat.byProject(drawerFilter == .archived ? listedChats : Chat.inDrawerOrder(listedChats)).flatMap(\.self)
    }

    /// Every thread under this one, at any depth, whatever the drawer's filter.
    func threads(under chat: Chat) -> [Chat] {
        let all = projects.flatMap(\.chats).filter(\.started)
        var found: [Chat] = []
        var openers: Set<UUID> = [chat.id]
        while true {
            let next = all.filter { $0.openedBy.map(openers.contains) == true && !found.contains($0) }
            guard !next.isEmpty else { return found }
            found += next
            openers = Set(next.map(\.id))
        }
    }

    /// Each started thread not archived, by the top thread it sits under: itself when it's a
    /// main thread, else the main thread above it.
    var topThreads: [UUID: UUID] {
        Self.tops(of: projects.flatMap(\.chats).filter { $0.started && !$0.archived })
    }

    /// `topThreads` of threads already gathered, which the drawer's list has in hand. A thread sits
    /// under the one that opened it in the same project, and an agent under its opener wherever it
    /// runs. One opened in another project is that project's main thread: Meriç, 2026-10-31, of a
    /// thread a No folder thread opened to run all of blackjack. Holding a task of a plan changes
    /// none of this: a lead that claims one is still the thread being written to.
    private static func tops(of threads: [Chat]) -> [UUID: UUID] {
        let places = Dictionary(threads.map { ($0.id, $0.project?.id) }, uniquingKeysWith: { first, _ in first })
        let openers = Dictionary(threads.map { chat -> (UUID, UUID?) in
            let under = chat.agentID != nil || chat.openedBy.flatMap { places[$0] } == chat.project?.id
            return (chat.id, under ? chat.openedBy : nil)
        }, uniquingKeysWith: { first, _ in first })
        var tops: [UUID: UUID] = [:]
        for id in openers.keys {
            var top = id
            var seen: Set<UUID> = [id]
            while let up = openers[top] ?? nil, openers[up] != nil, seen.insert(up).inserted { top = up }
            tops[id] = top
        }
        return tops
    }

    /// The same threads in no order, for whoever asks only which they are or how many: the
    /// drawer's order reads three stored values of two threads at every comparison. Working and
    /// Waiting on you list a top thread for what works or asks under it as well.
    var listedChats: [Chat] {
        // A thread archived with the one that opened it comes back with it, so it has no row.
        guard drawerFilter != .archived else { return archivedChats.filter { $0.archivedWith == nil } }
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }
        let tops = Self.tops(of: all)
        let top = all.filter { tops[$0.id] == $0.id }
        switch drawerFilter {
        case .project(let id): return top.filter { $0.project?.id == id }
        case .working:
            let working = Set(all.filter { conversations[$0.id]?.working == true || $0.agentWorking }.compactMap { tops[$0.id] })
            return top.filter { working.contains($0.id) }
        case .waiting:
            let asking = Set(waitingAsks.compactMap { tops[$0.thread.id] })
            return top.filter { asking.contains($0.id) }
        case .all, .archived: return top
        }
    }

    /// The archived threads, the latest worked on first, for Settings › Archive.
    var archivedChats: [Chat] {
        projects.flatMap(\.chats).filter(\.archived).sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Takes a thread out of the drawer and keeps everything of it: its transcript, its session,
    /// its worktree. Its CLI is let go, and a thread at work is stopped first by hand.
    /// The threads it opened go with it, and come back with it; one archived before it stays.
    func archive(_ chat: Chat) {
        guard conversations[chat.id]?.running != true else {
            say("Stop it first")
            return
        }
        guard !workflowRuns(in: chat) else {
            say("Stop it first")
            return
        }
        let under = threads(under: chat).filter { !$0.archived }
        guard !under.contains(where: { conversations[$0.id]?.running == true || workflowRuns(in: $0) }) else {
            say("Stop the threads under it first")
            return
        }
        for child in under { put(away: child, with: chat) }
        put(away: chat, with: nil)
    }

    /// The main threads left alone since `cutoff`, with everything under them. A thread stays while
    /// it's open, pinned, at work, waiting on someone, holding a draft or a task not done.
    func oldThreads(before cutoff: Date) -> [Chat] {
        let tops = topThreads
        let held = Set(projects.flatMap(\.tasks).filter { $0.state != "done" }.compactMap(\.thread))
        func kept(_ chat: Chat) -> Bool {
            chat.updatedAt >= cutoff || held.contains(chat.id) || chat.resumeAt != nil || chat.quitMidTurn || chat.agentWorking || workflowRuns(in: chat)
                || conversations[chat.id].map { $0.working || $0.waitingAsk != nil || $0.waitingAfterQuit } == true
        }
        return projects.flatMap(\.chats).filter { chat in
            guard chat.started, !chat.archived, tops[chat.id] == chat.id, !chat.pinned,
                  chat.id != selectedChatID, chat.id != besideChatID, !hasDraft(chat.id), !kept(chat)
            else { return false }
            return !threads(under: chat).contains { !$0.archived && kept($0) }
        }
    }

    /// Settings › Archive's sweep, as the app starts and comes to the front at most every six hours,
    /// so nothing wakes for it. A row at a time, so a first sweep of many doesn't hold a frame up.
    func sweepOldThreads() {
        guard engineState == .ready, swept.map({ Date.now.timeIntervalSince($0) > 6 * 3600 }) ?? true else { return }
        swept = .now
        guard AutoArchive.days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -AutoArchive.days, to: .now) else { return }
        let old = oldThreads(before: cutoff)
        guard !old.isEmpty else { return }
        Task {
            for chat in old {
                archive(chat)
                await Task.yield()
            }
            say(old.count == 1 ? "Archived an old thread" : "Archived \(old.count) old threads")
        }
    }

    private func put(away chat: Chat, with opener: Chat?) {
        let archived = chat.id
        let wasSelected = archived == selectedChatID
        if archived == besideChatID { besideChatID = nil }
        endShells(of: chat)
        Task { _ = try? await engine.request("close", ["threadId": .string(archived.uuidString)]) }
        dropConversation(archived)
        forgetComposer(of: archived)
        chat.archived = true
        chat.archivedWith = opener?.id
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

    /// Back into the drawer, on top of the threads that aren't pinned, and open, with the
    /// threads under it that went with it.
    func restore(_ chat: Chat) {
        let went = chat.archivedWith ?? chat.id
        for thread in [chat] + threads(under: chat).filter({ $0.archived && $0.archivedWith == went }) {
            thread.archived = false
            thread.archivedWith = nil
        }
        // Brought back on purpose, so the next sweep doesn't take it straight away again.
        chat.updatedAt = .now
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

    /// A drag in the drawer, within a project's threads. A row moves within the pinned threads or
    /// within the rest; one dropped above a pinned thread is pinned there, and a pinned one dropped
    /// below the rest's first row isn't pinned any more. Both groups then keep the order the drag left.
    func moveThreads(in project: Project, from source: IndexSet, to destination: Int) {
        var list = chats.filter { $0.project?.id == project.id }
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

    /// The project the drawer's header names, or with none picked yet the open thread's.
    var drawerProject: Project? {
        drawerProjectID.flatMap { id in projects.first { $0.id == id } } ?? project
    }

    /// The drawer's New thread: in the project its header names.
    func openNewThreadInDrawer() {
        if let home = drawerProject, home.id != selectedProjectID { selectedProjectID = home.id }
        openNewThread()
    }

    /// New thread without a folder: No folder's draft, or a new thread there.
    func openThreadWithoutFolder() {
        selectedProjectID = noFolderProject().id
        drawerProjectID = selectedProjectID
        openLocalThread(home: false)
    }

    func select(_ project: Project) {
        let left = self.project
        selectedProjectID = project.id
        drawerProjectID = project.id
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
        dropConversation(chat.id)
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
    /// ⌘N: home, with the keyboard in its composer. What's sent there starts the thread and stays
    /// on home (Meriç, 2026-10-25: "cmd n ile bir şey yazdım o thread'e attı, home'da kalmalı").
    /// `home: false` opens the project's draft instead, for New Thread Without a Folder.
    func openLocalThread(home: Bool = true) {
        if home && Self.preview {
            selectedChatID = nil
        } else if let draft = project?.chats.first(where: { !$0.started }) {
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
    /// `open` puts the thread on the glass; a send from home starts one and stays on home.
    func newChat(open: Bool = true) -> Chat? {
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
            dropConversation(draft.id)
            if typed == nil { typed = composers[draft.id] }
            composers[draft.id] = nil
            context.delete(draft)
        }
        let chat = makeChat(in: project)
        if let typed { composers[chat.id] = typed }
        if open { selectedChatID = chat.id }
        return chat
    }

    /// A thread in `project` on what new threads start with, Settings › New threads' defaults or
    /// the last picks, stored and not opened: ⌘N's, and the one the phone starts.
    func makeChat(in project: Project) -> Chat {
        let chat = Chat(project: project, permissionMode: startingPermissionMode)
        chat.provider = startingProvider
        chat.model = startingModel
        let levels = option(for: chat)?.efforts ?? []
        chat.effort = startingEffort.flatMap { levels.contains($0) ? $0 : nil }
        chat.fastMode = startingFast
        context.insert(chat)
        save()
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
        guard chat.agentID == nil || !workflowRuns(in: chat) else {
            say("Stop it first")
            return
        }
        let deleted = chat.id
        // Its workflow's agents go with it: nothing else writes or reads them.
        let agents = agents(under: chat)
        let wasSelected = deleted == selectedChatID || agents.contains { $0.id == selectedChatID }
        if deleted == besideChatID || agents.contains(where: { $0.id == besideChatID }) { besideChatID = nil }
        let gone = Set([deleted] + agents.map(\.id))
        askers = askers.filter { !gone.contains($0.value.id) }
        for agent in agents {
            conversations[agent.id]?.forget()
            dropConversation(agent.id)
            context.delete(agent)
        }
        endShells(of: chat)
        // A thread it opened that still works in its worktree keeps it, as its own from here.
        if let branch = chat.worktreeBranch, let heir = projects.flatMap(\.chats).first(where: { $0.id != deleted && $0.cwd == chat.cwd && $0.worktreeBranch == nil }) {
            heir.worktreeBranch = branch
        }
        Task { _ = try? await engine.request("close", ["threadId": .string(deleted.uuidString)]) }
        // Its events can't find it through the conversation any more.
        conversations[deleted]?.forget()
        dropConversation(deleted)
        forgetComposer(of: deleted)
        SentPictures.standard.forget(thread: deleted)
        context.delete(chat)
        save()
        planThreadDeleted(deleted)
        guard wasSelected, !besideTakesWindow() else { return }
        // The next thread in the same project if there is one, so deleting doesn't switch projects.
        let rest = chats.filter { $0.id != deleted && $0.openedBy != deleted }
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
