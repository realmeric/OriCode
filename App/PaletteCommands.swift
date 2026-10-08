import AppKit
import SwiftData
import SwiftUI

/// What the command center offers: every command the app has, the threads and projects, and
/// the lists behind Model…, Effort…, Permissions…, Switch project… and the Settings panes.
extension AppModel {
    // MARK: - Showing it

    func toggleCommandCenter() {
        if commandCenterShown {
            closeCommandCenter()
        } else {
            palette.reset()
            // What was said since it was last open is found too.
            paletteFound = nil
            // A terminal can move the branch behind the app's back, and actions.json can change.
            refreshBranch(for: chat)
            customActions.refresh()
            readAgentModels()
            withAnimation(Motion.move) { openInIsland(.command) }
        }
    }

    /// ⌘⇧B: the command center open on Switch branch.
    func openBranchSwitcher() {
        guard gitUnavailable == nil else {
            if let reason = gitUnavailable { say(reason) }
            return
        }
        palette.reset()
        refreshBranch(for: chat)
        palette.push(.list(branchList))
        load(branchList, at: 1)
        withAnimation(Motion.move) { openInIsland(.command) }
    }

    func closeCommandCenter() {
        guard commandCenterShown else { return }
        withAnimation(Motion.move) { commandCenterShown = false }
    }

    /// Runs a row: a command closes the command center first, a task keeps it open until it's
    /// done, and a list or a line to type opens a level of its own.
    func activate(_ item: PaletteItem) {
        if let reason = item.unavailable {
            palette.problem = reason
            return
        }
        guard palette.busy == nil else { return }
        // A message found once isn't a row to come back to.
        if item.kind != .message { rememberInPalette(item.id) }
        switch item.action {
        case .run(let run):
            closeCommandCenter()
            run()
        case .task(let label, let work):
            runPaletteTask(label, work)
        case .list(let list):
            palette.push(.list(list))
            load(list, at: palette.stack.count - 1)
        case .input(let input):
            palette.push(.input(input), query: input.initial)
        }
    }

    func submit(_ input: PaletteInput, text: String) {
        guard palette.busy == nil else { return }
        if case .problem(let reason) = input.hint(text) {
            palette.problem = reason
            return
        }
        runPaletteTask(input.title + "…") { try await input.submit(text) }
    }

    func load(_ list: PaletteList, at index: Int) {
        palette.stack[index].loading = true
        Task {
            let items = (try? await list.items()) ?? []
            guard palette.stack.indices.contains(index) else { return }
            palette.stack[index].items = items
            palette.stack[index].loading = false
        }
    }

    private func runPaletteTask(_ label: String, _ work: @escaping @MainActor () async throws -> String?) {
        palette.busy = label
        palette.problem = nil
        Task {
            do {
                let note = try await work()
                palette.busy = nil
                closeCommandCenter()
                if let note { say(note) }
            } catch {
                palette.busy = nil
                // Esc while it ran closed the command center; the note says what happened instead.
                if commandCenterShown { palette.problem = error.localizedDescription } else { say(error.localizedDescription) }
            }
        }
    }

    /// The rows used lately, newest first, which a search puts ahead and the top level lists.
    var paletteRecents: [String] {
        UserDefaults.standard.stringArray(forKey: "paletteRecents") ?? []
    }

    private func rememberInPalette(_ id: String) {
        var recents = paletteRecents.filter { $0 != id }
        recents.insert(id, at: 0)
        UserDefaults.standard.set(Array(recents.prefix(20)), forKey: "paletteRecents")
    }

    // MARK: - The top level

    /// With nothing typed: what's worth doing now, what was used lately, the latest threads, then
    /// every command that can run.
    func paletteSections() -> [(title: String, items: [PaletteItem])] {
        let commands = paletteCommands()
        let reachable = commands + paletteThreads + paletteProjects + paletteChoices
        let recent = paletteRecents.compactMap { id in reachable.first { $0.id == id && $0.unavailable == nil } }.prefix(5)
        let threads = paletteThreads.filter { $0.id != "thread." + (chat?.id.uuidString ?? "") }.prefix(6)
        let sections: [(String, [PaletteItem])] = [
            ("Now", paletteNow),
            ("Recent", Array(recent)),
            ("Threads", Array(threads)),
            ("Commands", commands.filter { $0.unavailable == nil }),
        ]
        return sections.filter { !$0.1.isEmpty }.map { (title: $0.0, items: $0.1) }
    }

    /// With something typed: every command, thread and project, and the choices inside the lists.
    /// `whole` keeps what ⌘K leaves out of a thread without a folder, for a list that isn't the
    /// open thread's.
    func paletteSearchable(whole: Bool = false) -> [PaletteItem] {
        paletteCommands(whole: whole) + paletteThreads + paletteProjects + paletteChoices
    }

    /// Only what the moment calls for: Stop while a turn runs, Compact near the context's end, and
    /// sending the last message again after it failed.
    private var paletteNow: [PaletteItem] {
        guard let chat, let conversation = currentConversation else { return [] }
        var now: [PaletteItem] = []
        if conversation.running {
            now.append(command("thread.stop", "Stop", icon: "stop.circle", shortcut: shortcuts.label(.stop)) { [weak self] in self?.stop() })
        } else {
            if chat.sessionId != nil, agent(for: chat).capabilities.compact, chat.contextWindow > 0, Double(chat.contextUsed) / Double(chat.contextWindow) > 0.7 {
                now.append(command("thread.compact", "Compact", icon: "arrow.down.right.and.arrow.up.left",
                                   subtitle: "\(Int(Double(chat.contextUsed) / Double(chat.contextWindow) * 100))% of the context used") { [weak self] in
                    self?.send("/compact")
                })
            }
            if case .note = conversation.items.last(where: { !$0.followsTurn }), let text = lastUserText {
                now.append(command("thread.again", "Send the last message again", icon: "arrow.clockwise") { [weak self] in self?.send(text) })
            }
        }
        return now
    }

    private var paletteThreads: [PaletteItem] {
        projects
            .flatMap { project in project.chats.filter(\.started).map { (project, $0) } }
            .sorted { $0.1.updatedAt > $1.1.updatedAt }
            .map { project, chat in
                PaletteItem(id: "thread." + chat.id.uuidString, kind: .thread, title: chat.title, subtitle: project.name,
                            icon: "bubble.left", project: project, checked: chat.id == self.chat?.id,
                            action: .run { [weak self] in self?.open(chatID: chat.id) })
            }
    }

    /// What was said in the threads that holds every word typed, your messages and the replies,
    /// newest first and three a thread at most. It searches the stored `user` and `text` events,
    /// which every agent's thread has, through the index `said` keeps of them in memory.
    /// Worked out once for each query: an arrow key draws the rows again but asks nothing new.
    func paletteMessages(for query: String) -> [PaletteItem] {
        let words = MessageSearch.words(query)
        guard !words.isEmpty else { return [] }
        said.read(from: context.container)
        if let found = paletteFound, (found.query, found.revision, found.ready) == (query, revision, said.ready) { return found.items }
        let threads = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        let items = said.search(words, in: Set(threads.keys)).compactMap { message -> PaletteItem? in
            guard let chat = threads[message.chat], let project = chat.project,
                  let snippet = MessageSearch.snippet(words, in: message.text as String)
            else { return nil }
            let chatID = chat.id, eventID = message.id
            return PaletteItem(id: "message." + eventID.uuidString, kind: .message, title: snippet, subtitle: chat.title,
                               icon: message.user ? "person" : "text.bubble", project: project,
                               action: .run { [weak self] in
                                   self?.open(chatID: chatID)
                                   self?.reveal = eventID
                               })
        }
        paletteFound = (query, revision, said.ready, items)
        return items
    }

    private var paletteProjects: [PaletteItem] {
        projects.map { project in
            PaletteItem(id: "project." + project.id.uuidString, kind: .project, title: project.name, subtitle: "Project",
                        icon: "folder", project: project, checked: project.id == self.project?.id,
                        action: .run { [weak self] in self?.select(project) })
        }
    }

    /// The choices behind Model…, Effort…, Permissions… and the Settings panes, named for search:
    /// "Model: Opus 5", "Permissions: Plan".
    private var paletteChoices: [PaletteItem] {
        let lists = [modelChoices, effortChoices, modeChoices].flatMap { $0 }
        return lists + SettingsPane.allCases.map { pane in
            PaletteItem(id: "settings." + pane.rawValue, kind: .choice, title: "Settings: " + pane.title, icon: pane.icon,
                        action: .run { [weak self] in self?.openSettings(pane) })
        }
    }

    // MARK: - Commands

    private func paletteCommands(whole: Bool = false) -> [PaletteItem] {
        let chat = chat
        let running = currentConversation?.running == true
        let option = option(for: chat)
        let agent = self.agent(for: chat)
        let noThread: String? = chat == nil ? "No thread is open" : nil
        let noProject: String? = project == nil ? "Add a project first" : nil
        // No folder has no repository, no branches and no sessions of Terminal's, so its ⌘K has
        // no rows for them.
        let noFolder = !whole && project?.isNoFolder == true
        let unsent: String? = chat?.started == true ? nil : noThread ?? "Send it a message first"
        let busy: String? = running ? "Wait for the turn to end" : nil
        var items: [PaletteItem] = []

        // Threads
        // With no project it's a thread without a folder.
        items.append(command("thread.new", "New thread", icon: "square.and.pencil", shortcut: shortcuts.label(.newThread)) { [weak self] in
            self?.openNewThread()
        })
        if !noFolder {
            items.append(command("thread.branch", startsOnBranch ? "New thread in the project's folder" : "New thread on its own branch",
                                 icon: startsOnBranch ? "folder" : "arrow.triangle.branch", shortcut: shortcuts.label(.newThreadOnBranch),
                                 keywords: ["worktree", "branch", "local"], unavailable: noProject) { [weak self] in self?.openOtherThread() })
            items.append(PaletteItem(id: "thread.session", kind: .command, title: "Open a Claude Code session…", keywords: ["cli", "terminal", "resume", "import", "claude"],
                                     icon: "terminal", unavailable: noProject ?? (engineState == .ready ? nil : "The engine isn't running"), action: .list(sessionList)))
        }
        items.append(command("thread.noFolder", "New thread without a folder", icon: "laptopcomputer",
                             keywords: ["no folder", "no project", "laptop", "scratch", "anywhere"]) { [weak self] in self?.openThreadWithoutFolder() })
        items.append(command("thread.stop", "Stop", icon: "stop.circle", shortcut: shortcuts.label(.stop), keywords: ["interrupt", "cancel"],
                             unavailable: running ? nil : "Nothing is running") { [weak self] in self?.stop() })
        if agent.capabilities.compact {
            items.append(command("thread.compact", "Compact", icon: "arrow.down.right.and.arrow.up.left", keywords: ["context", "summarize"],
                                 unavailable: chat?.sessionId == nil ? "Nothing to compact yet" : busy) { [weak self] in self?.send("/compact") })
        }
        items.append(command("thread.again", "Send the last message again", icon: "arrow.clockwise", keywords: ["retry", "resend"],
                             unavailable: lastUserText == nil ? "Nothing sent yet" : busy) { [weak self] in
            if let text = self?.lastUserText { self?.send(text) }
        })
        items.append(command("thread.copyReply", "Copy last reply", icon: "doc.on.doc", keywords: ["clipboard"],
                             unavailable: lastReply == nil ? "No reply yet" : nil) { [weak self] in
            self?.copy(self?.lastReply, saying: "Copied the last reply.")
        })
        items.append(command("thread.copyMarkdown", "Copy thread as Markdown", icon: "doc.plaintext", keywords: ["export", "clipboard"],
                             unavailable: unsent) { [weak self] in
            self?.copy(self?.threadMarkdown, saying: "Copied the thread.")
        })
        // A session the agent can't pick up is no use to anyone.
        if agent.capabilities.resume {
            items.append(command("thread.copySession", "Copy session ID", icon: "number", keywords: [agent.agent.lowercased(), "resume", "clipboard"],
                                 unavailable: chat?.sessionId == nil ? "No session yet" : nil) { [weak self] in
                self?.copy(chat?.sessionId, saying: "Copied the session ID.")
            })
        }
        items.append(command("thread.end", "Jump to the end of the thread", icon: "arrow.down", keywords: ["bottom", "latest", "newest", "scroll"],
                             unavailable: unsent) { [weak self] in
            self?.threadEnd += 1
        })
        items.append(command("thread.pin", chat?.pinned == true ? "Unpin thread" : "Pin thread", icon: chat?.pinned == true ? "pin.slash" : "pin",
                             unavailable: unsent) { [weak self] in
            if let chat { withAnimation(Motion.move) { self?.togglePin(chat) } }
        })
        items.append(command("thread.rename", "Rename thread", icon: "pencil", shortcut: shortcuts.label(.rename), unavailable: unsent) { [weak self] in
            if let chat { self?.startRename(chat) }
        })
        items.append(command("thread.archive", "Archive thread", icon: "archivebox", keywords: ["hide", "put away"], unavailable: unsent ?? busy) { [weak self] in
            if let chat { self?.archive(chat) }
        })
        if chat?.archived == true {
            items.append(command("thread.restore", "Restore thread", icon: "tray.and.arrow.up", keywords: ["unarchive"]) { [weak self] in
                if let chat { self?.restore(chat) }
            })
        }
        items.append(PaletteItem(id: "threads.archived", kind: .command, title: "Archived threads…", keywords: ["archive", "restore", "unarchive", "old"],
                                 icon: "archivebox", unavailable: archivedChats.isEmpty ? "Nothing is archived" : nil, action: .list(archivedList)))
        items.append(PaletteItem(id: "threads.filter", kind: .command, title: "Filter threads…", subtitle: drawerFilter == .all ? nil : drawerFilter.title(in: projects),
                                 keywords: ["drawer", "sidebar", "show", "working", "waiting", "archived"], icon: "line.3.horizontal.decrease", action: .list(filterList)))
        items.append(command("thread.delete", "Delete thread…", icon: "trash", shortcut: shortcuts.label(.delete), unavailable: noThread) { [weak self] in
            self?.askToDelete(chat)
        })
        items.append(command("thread.close", "Close thread", icon: "xmark", shortcut: shortcuts.label(.close), unavailable: noThread) { [weak self] in
            self?.close()
        })
        let others: String? = chats.count > 1 ? nil : "No other thread"
        items.append(command("thread.next", "Next thread", icon: "chevron.down", shortcut: shortcuts.label(.nextThread), unavailable: others) { [weak self] in
            self?.stepThread(1)
        })
        items.append(command("thread.previous", "Previous thread", icon: "chevron.up", shortcut: shortcuts.label(.previousThread), unavailable: others) { [weak self] in
            self?.stepThread(-1)
        })
        items.append(command("threads.toggle", drawerPinned ? "Hide threads" : "Show threads", icon: "sidebar.left", shortcut: shortcuts.label(.toggleThreads),
                             keywords: ["drawer", "sidebar"]) { [weak self] in self?.toggleDrawerPin() })

        // Model, effort and permissions, which with no project are the next thread's
        items.append(PaletteItem(id: "model.list", kind: .command, title: "Model…", subtitle: option?.name,
                                 keywords: ["opus", "sonnet", "haiku", "fable"], icon: "cpu",
                                 action: .list(PaletteList(title: "Model", placeholder: "Search models") { [weak self] in self?.modelChoices(named: false) ?? [] })))
        if let option, !option.efforts.isEmpty {
            let level = (chat == nil ? startingEffort : chat?.effort).flatMap { option.efforts.contains($0) ? $0 : nil }
            items.append(PaletteItem(id: "effort.list", kind: .command, title: "Effort…",
                                     subtitle: level.map(ModelMenu.effortName) ?? "Default",
                                     keywords: ["thinking", "level"], icon: "gauge.with.dots.needle.67percent",
                                     action: .list(PaletteList(title: "Effort", placeholder: "Search levels") { [weak self] in self?.effortChoices(named: false) ?? [] })))
        }
        if !agent.permissionModes.isEmpty {
            let mode = PermissionModeOption(rawValue: chat?.permissionMode ?? startingPermissionMode) ?? .ask
            items.append(PaletteItem(id: "mode.list", kind: .command, title: "Permissions…", subtitle: mode.title,
                                     keywords: ["mode", "ask", "plan", "auto", "accept edits"], icon: mode.icon,
                                     action: .list(PaletteList(title: "Permissions", placeholder: "Search modes") { [weak self] in self?.modeChoices(named: false) ?? [] })))
        }
        if let option, option.fast {
            let on = chat.map(fastMode(of:)) ?? startingFast
            items.append(command("fast.toggle", on ? "Fast mode off" : "Fast mode on", icon: on ? "bolt.slash" : "bolt",
                                 subtitle: on ? PickerState(model: self, chat: chat).fastProblem : nil, keywords: ["speed", "fast"]) { [weak self] in self?.setFast(!on, for: chat) })
        }
        if let option, option.ultra || option.ultraBlocked != nil {
            let on = workflows(of: chat)
            items.append(command("workflows.toggle", on ? "Workflows off" : "Workflows on", icon: "circle.dashed.inset.filled",
                                 subtitle: on ? PickerState(model: self, chat: chat).workflowsMissing : nil,
                                 keywords: ["ultracode", "agents", "fan out", "workflow"],
                                 unavailable: option.ultra ? nil : "Needs dynamic workflows, see /config in \(agent.name)") { [weak self] in
                self?.setWorkflows(!on, for: chat)
            })
        }
        items.append(command("model.defaults", "Back to defaults", icon: "arrow.counterclockwise",
                             unavailable: atDefaults(chat) ? "Already at the defaults" : nil) { [weak self] in
            self?.resetToDefaults(for: chat)
        })
        if let option, option.needs == nil {
            let starred = favoriteModels.contains(option.id)
            items.append(command("model.star", starred ? "Unstar \(option.name)" : "Star \(option.name)", icon: starred ? "star.slash" : "star",
                                 keywords: ["favorite", "favourite"]) { [weak self] in self?.toggleFavorite(option.id) })
        }
        items.append(command("model.card", "Model and effort", icon: "slider.horizontal.3", shortcut: shortcuts.label(.modelPicker)) { [weak self] in
            self?.modelPickerShown.toggle()
        })

        // Git, in the thread's folder
        if !noFolder {
            items += gitCommands
            items += pullCommands
        }

        // The terminal, and your own actions
        items += terminalCommands
        items += customActionCommands

        // Projects and files
        items.append(PaletteItem(id: "project.list", kind: .command, title: "Switch project…", subtitle: project?.name, icon: "folder",
                                 unavailable: projects.count > 1 ? nil : "There's only one project",
                                 action: .list(PaletteList(title: "Project", placeholder: "Search projects") { [weak self] in self?.paletteProjects ?? [] })))
        items.append(command("project.add", "Add project…", icon: "folder.badge.plus", shortcut: shortcuts.label(.addProject)) { [weak self] in self?.addProject() })
        if showsHeads(chat) {
            items.append(command("heads", "Show heads", icon: "circle.dotted", shortcut: shortcuts.label(.heads), keywords: ["agents", "tasks", "running"],
                                 unavailable: noThread) { [weak self] in self?.toggleHeads() })
        }
        items.append(command("files.find", "Find a file", icon: "doc.text.magnifyingglass", shortcut: shortcuts.label(.findFile), unavailable: noThread) { [weak self] in
            self?.toggleFileFinder()
        })
        items.append(command("side", "Ask a side question", icon: "bubble.left.and.bubble.right", shortcut: shortcuts.label(.sideQuestion),
                             keywords: ["aside", "btw", "quick"], unavailable: sideUnavailable) { [weak self] in self?.toggleSide() })
        items.append(command("changes", "Review changes", icon: "plus.forwardslash.minus", shortcut: shortcuts.label(.review),
                             keywords: ["commit", "diff", "changes", "stage", "git", "revert"],
                             unavailable: noProject) { [weak self] in self?.openReview() })

        items.append(command("review.ask", "Ask for a review of the changes", icon: "sparkle", keywords: ["review", "comments", "diff"],
                             unavailable: noProject) { [weak self] in
            self?.openReview()
            self?.askForReviewOnceRead()
        })
        if let file = openFile {
            if file.editing {
                items.append(command("file.save", "Save \((file.path as NSString).lastPathComponent)", icon: "square.and.arrow.down", shortcut: "⌘S",
                                     unavailable: file.dirty ? nil : "Nothing to save") { [weak self] in self?.saveFile() })
            } else {
                items.append(command("file.edit", "Edit \((file.path as NSString).lastPathComponent)", icon: "pencil.line",
                                     unavailable: file.truncated ? "Too large to edit here" : nil) { [weak self] in self?.editFile() })
            }
        }
        let thinking = UserDefaults.standard.object(forKey: TranscriptSettings.showThinking) as? Bool ?? true
        items.append(command("transcript.thinking", thinking ? "Hide thinking" : "Show thinking", icon: "brain", keywords: ["thought", "reasoning"]) {
            UserDefaults.standard.set(!thinking, forKey: TranscriptSettings.showThinking)
        })
        let concise = UserDefaults.standard.bool(forKey: TranscriptSettings.concise)
        items.append(command("replies.concise", concise ? "Concise replies off" : "Concise replies on", icon: "text.alignleft", keywords: ["short", "brief"]) {
            UserDefaults.standard.set(!concise, forKey: TranscriptSettings.concise)
        })

        // Quality of life
        items += qualityCommands

        // The app
        items.append(command("settings", "Settings", icon: "gearshape", shortcut: "⌘,") { [weak self] in self?.openSettings(nil) })
        items.append(command("shortcuts", "Keyboard shortcuts", icon: "keyboard", shortcut: shortcuts.label(.shortcuts), keywords: ["keys"]) { [weak self] in
            self?.showingShortcuts = true
        })
        return items
    }

    /// The archived threads, each a row that restores it and opens it.
    private var archivedList: PaletteList {
        PaletteList(title: "Archived threads", placeholder: "Search archived threads") { [weak self] in
            (self?.archivedChats ?? []).map { chat in
                PaletteItem(id: "archived." + chat.id.uuidString, kind: .thread, title: chat.title,
                            subtitle: [chat.project?.name, chat.updatedAt.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }.joined(separator: " · "),
                            icon: "archivebox", project: chat.project, action: .run { [weak self] in self?.restore(chat) })
            }
        }
    }

    /// What the thread list shows, as the drawer's own filter has it.
    private var filterList: PaletteList {
        PaletteList(title: "Filter threads", placeholder: "Which threads the list shows") { [weak self] in
            guard let self else { return [] }
            let choices: [(DrawerFilter, String, String)] = [(.all, "All threads", "tray.full")]
                + projects.map { (.project($0.id), $0.name, "folder") }
                + [(.working, "Working", "circle.dotted"), (.waiting, "Waiting on you", "hand.raised"), (.archived, "Archived", "archivebox")]
            return choices.map { filter, title, icon in
                PaletteItem(id: "filter." + title, kind: .choice, title: title, icon: icon, checked: filter == self.drawerFilter,
                            action: .run { [weak self] in
                                self?.drawerFilter = filter
                                // Pinned open, or else just long enough to see what it shows now.
                                if self?.drawerPinned == false {
                                    self?.showDrawer()
                                    self?.scheduleHide(after: .seconds(2))
                                }
                            })
            }
        }
    }

    /// A ⌘K command by its id, as an action of the user's own or its key runs it: one that opens
    /// a list or asks for input opens ⌘K there.
    func runPaletteCommand(_ id: String) {
        guard let item = paletteSearchable().first(where: { $0.id == id }) else {
            // One of a folder's commands, which No folder's ⌘K leaves out.
            say(project?.isNoFolder == true ? Self.missingInNoFolder(id) ?? "There's no command called \(id)" : "There's no command called \(id)")
            return
        }
        if let reason = item.unavailable {
            say(reason)
            return
        }
        switch item.action {
        case .run(let run):
            if commandCenterShown { closeCommandCenter() }
            run()
        case .task, .list, .input:
            if !commandCenterShown {
                palette.reset()
                withAnimation(Motion.move) { openInIsland(.command) }
            }
            activate(item)
        }
    }

    /// What a command ⌘K leaves out of No folder says when an action of the user's runs it there,
    /// or nil for an id that was never one of them.
    nonisolated static func missingInNoFolder(_ id: String) -> String? {
        if id == "thread.session" { return "No folder has no Claude Code sessions to open" }
        return id == "thread.branch" || id.hasPrefix("git.") || id.hasPrefix("pr.") ? "No folder has no repository" : nil
    }

    /// Every command an action can point at, by id, for the action's form: the same ones whichever
    /// project is open, No folder too, since the action may be for another.
    var commandChoices: [(id: String, title: String)] {
        paletteSearchable(whole: true)
            .filter { ($0.kind == .command || $0.id.hasPrefix("settings.")) && !$0.id.hasPrefix("action.") }
            .map { ($0.id, $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func command(_ id: String, _ title: String, icon: String, shortcut: String? = nil, subtitle: String? = nil,
                         keywords: [String] = [], unavailable: String? = nil, _ run: @escaping @MainActor () -> Void) -> PaletteItem {
        PaletteItem(id: id, kind: .command, title: title, subtitle: subtitle, keywords: keywords, shortcut: shortcut, icon: icon,
                    unavailable: unavailable, action: .run(run))
    }

    // MARK: - Lists

    private var modelChoices: [PaletteItem] { modelChoices(named: true) }
    private var effortChoices: [PaletteItem] { effortChoices(named: true) }
    private var modeChoices: [PaletteItem] { modeChoices(named: true) }

    /// The models in the pickers' order; `named` puts "Model: " before each, for a search from the
    /// top level. With several agents listed each row names its agent before its line.
    private func modelChoices(named: Bool) -> [PaletteItem] {
        let current = option(for: chat).map { ModelRef(provider: providerID(for: chat), id: $0.id).stored }
        let rows = modelGroups(for: chat).flatMap(\.rows)
        let several = Set(rows.map(\.agent)).count > 1
        return rows.map { row in
            let option = row.option
            let line = [several ? providerInfo(row.agent).name : nil, option.description.nonEmpty].compactMap { $0 }.joined(separator: " · ")
            return PaletteItem(id: "model." + row.id, kind: .choice, title: (named ? "Model: " : "") + option.name,
                               subtitle: line.nonEmpty, agent: row.agent, checked: row.id == current,
                               unavailable: option.needs.map { "Needs Claude Code \($0)" } ?? forbiddenHelp(option, on: row.agent),
                               action: .run { [weak self] in
                                   guard let self else { return }
                                   withAnimation(Motion.move) { self.setModel(row.ref, for: self.chat) }
                               })
        }
    }

    private func effortChoices(named: Bool) -> [PaletteItem] {
        guard let option = option(for: chat), !option.efforts.isEmpty else { return [] }
        let current = (chat == nil ? startingEffort : chat?.effort).flatMap { option.efforts.contains($0) ? $0 : nil }
        let prefix = named ? "Effort: " : ""
        let home = defaultLevel(for: chat).map { "Default (\(ModelMenu.effortName($0)))" } ?? "Default"
        var items = [PaletteItem(id: "effort.default", kind: .choice, title: prefix + home, icon: "gauge.with.dots.needle.50percent",
                                 checked: current == nil, action: .run { [weak self] in
                                     guard let self else { return }
                                     withAnimation(Motion.move) { self.setEffort(nil, for: self.chat) }
                                 })]
        items += option.efforts.map { level in
            PaletteItem(id: "effort." + level, kind: .choice, title: prefix + ModelMenu.effortName(level),
                        subtitle: EffortScale.line(level).0, icon: "gauge.with.dots.needle.67percent", checked: current == level,
                        action: .run { [weak self] in
                            guard let self else { return }
                            withAnimation(Motion.move) { self.setEffort(level, for: self.chat) }
                        })
        }
        return items
    }

    private func modeChoices(named: Bool) -> [PaletteItem] {
        let current = chat?.permissionMode ?? startingPermissionMode
        return agent(for: chat).permissionModes.map { mode in
            PaletteItem(id: "mode." + mode.rawValue, kind: .choice, title: (named ? "Permissions: " : "") + mode.title, subtitle: mode.summary,
                        icon: mode.icon, checked: mode.rawValue == current,
                        action: .run { [weak self] in
                            guard let self else { return }
                            withAnimation(Motion.move) { self.setPermissionMode(mode.rawValue, for: self.chat) }
                        })
        }
    }

    // MARK: - Helpers

    /// The last message sent in the open thread.
    var lastUserText: String? {
        currentConversation?.items.reversed().lazy.compactMap { item -> String? in
            if case .user(_, let text, _, _) = item { return text }
            return nil
        }.first
    }

    /// Claude's text in the last turn, which is the last reply.
    var lastReply: String? {
        guard let items = currentConversation?.items, let sent = items.lastIndex(where: \.startsTurn) else { return nil }
        let texts = items[(sent + 1)...].compactMap { item -> String? in
            if case .text(_, let text) = item { return text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// The thread's messages and its agent's text, as Markdown.
    var threadMarkdown: String? {
        guard let items = currentConversation?.items else { return nil }
        let speaker = "**\(agent(for: chat).agent)**\n\n"
        let parts = items.compactMap { item -> String? in
            switch item {
            case .user(_, let text, _, _): "**You**\n\n" + text
            case .text(_, let text): speaker + text
            default: nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    func copy(_ text: String?, saying line: String) {
        guard let text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say(line)
    }

    /// Opens Settings, on a pane when one is named.
    func openSettings(_ pane: SettingsPane?) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: SettingsPane.key) }
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
