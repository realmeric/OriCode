import AppKit
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
            // A terminal can move the branch behind the app's back, and actions.json can change.
            refreshBranch(for: chat)
            customActions.refresh()
            withAnimation(Motion.move) { commandCenterShown = true }
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
        withAnimation(Motion.move) { commandCenterShown = true }
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
        rememberInPalette(item.id)
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
        let commands = paletteCommands
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
    func paletteSearchable() -> [PaletteItem] {
        paletteCommands + paletteThreads + paletteProjects + paletteChoices
    }

    /// Only what the moment calls for: Stop while a turn runs, Compact near the context's end, and
    /// sending the last message again after it failed.
    private var paletteNow: [PaletteItem] {
        guard let chat, let conversation = currentConversation else { return [] }
        var now: [PaletteItem] = []
        if conversation.running {
            now.append(command("thread.stop", "Stop", icon: "stop.circle", shortcut: "⌘.") { [weak self] in self?.stop() })
        } else {
            if chat.sessionId != nil, chat.contextWindow > 0, Double(chat.contextUsed) / Double(chat.contextWindow) > 0.7 {
                now.append(command("thread.compact", "Compact", icon: "arrow.down.right.and.arrow.up.left",
                                   subtitle: "\(Int(Double(chat.contextUsed) / Double(chat.contextWindow) * 100))% of the context used") { [weak self] in
                    self?.send("/compact")
                })
            }
            if case .note = conversation.items.last, let text = lastUserText {
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

    private var paletteCommands: [PaletteItem] {
        let chat = chat
        let running = currentConversation?.running == true
        let option = option(for: chat)
        let noThread: String? = chat == nil ? "No thread is open" : nil
        let noProject: String? = project == nil ? "Add a project first" : nil
        let unsent: String? = chat?.started == true ? nil : noThread ?? "Send it a message first"
        let busy: String? = running ? "Wait for the turn to end" : nil
        var items: [PaletteItem] = []

        // Threads
        items.append(command("thread.new", "New thread", icon: "square.and.pencil", shortcut: "⌘N", unavailable: noProject) { [weak self] in
            self?.openNewThread()
        })
        items.append(command("thread.branch", "New thread on its own branch", icon: "arrow.triangle.branch", shortcut: "⌘⇧N",
                             keywords: ["worktree"], unavailable: noProject) { [weak self] in self?.newWorktreeChat() })
        items.append(command("thread.stop", "Stop", icon: "stop.circle", shortcut: "⌘.", keywords: ["interrupt", "cancel"],
                             unavailable: running ? nil : "Nothing is running") { [weak self] in self?.stop() })
        items.append(command("thread.compact", "Compact", icon: "arrow.down.right.and.arrow.up.left", keywords: ["context", "summarize"],
                             unavailable: chat?.sessionId == nil ? "Nothing to compact yet" : busy) { [weak self] in self?.send("/compact") })
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
        items.append(command("thread.copySession", "Copy session ID", icon: "number", keywords: ["claude", "resume", "clipboard"],
                             unavailable: chat?.sessionId == nil ? "No session yet" : nil) { [weak self] in
            self?.copy(chat?.sessionId, saying: "Copied the session ID.")
        })
        items.append(command("thread.pin", chat?.pinned == true ? "Unpin thread" : "Pin thread", icon: chat?.pinned == true ? "pin.slash" : "pin",
                             unavailable: unsent) { [weak self] in
            if let chat { withAnimation(Motion.move) { self?.togglePin(chat) } }
        })
        items.append(command("thread.rename", "Rename thread", icon: "pencil", shortcut: "⌘R", unavailable: unsent) { [weak self] in
            if let chat { self?.startRename(chat) }
        })
        items.append(command("thread.delete", "Delete thread…", icon: "trash", shortcut: "⌘⌫", unavailable: noThread) { [weak self] in
            self?.askToDelete(chat)
        })
        items.append(command("thread.close", "Close thread", icon: "xmark", shortcut: "⌘W", unavailable: noThread) { [weak self] in
            self?.close()
        })
        let others: String? = chats.count > 1 ? nil : "No other thread"
        items.append(command("thread.next", "Next thread", icon: "chevron.down", shortcut: "⌃Tab", unavailable: others) { [weak self] in
            self?.stepThread(1)
        })
        items.append(command("thread.previous", "Previous thread", icon: "chevron.up", shortcut: "⌃⇧Tab", unavailable: others) { [weak self] in
            self?.stepThread(-1)
        })
        items.append(command("threads.toggle", drawerPinned ? "Hide threads" : "Show threads", icon: "sidebar.left", shortcut: "⌘B",
                             keywords: ["drawer", "sidebar"]) { [weak self] in self?.toggleDrawerPin() })

        // Model, effort and permissions
        items.append(PaletteItem(id: "model.list", kind: .command, title: "Model…", subtitle: option?.name,
                                 keywords: ["opus", "sonnet", "haiku", "fable"], icon: "cpu", unavailable: noProject,
                                 action: .list(PaletteList(title: "Model", placeholder: "Search models") { [weak self] in self?.modelChoices(named: false) ?? [] })))
        if let option, !option.levels.isEmpty {
            let level = (chat == nil ? startingEffort : chat?.effort).flatMap { option.levels.contains($0) ? $0 : nil }
            items.append(PaletteItem(id: "effort.list", kind: .command, title: "Effort…",
                                     subtitle: level.map(ModelMenu.effortName) ?? "Default",
                                     keywords: ["thinking", "level", "ultracode"], icon: "gauge.with.dots.needle.67percent", unavailable: noProject,
                                     action: .list(PaletteList(title: "Effort", placeholder: "Search levels") { [weak self] in self?.effortChoices(named: false) ?? [] })))
        }
        let mode = PermissionModeOption(rawValue: chat?.permissionMode ?? startingPermissionMode) ?? .ask
        items.append(PaletteItem(id: "mode.list", kind: .command, title: "Permissions…", subtitle: mode.title,
                                 keywords: ["mode", "ask", "plan", "auto", "accept edits"], icon: mode.icon, unavailable: noProject,
                                 action: .list(PaletteList(title: "Permissions", placeholder: "Search modes") { [weak self] in self?.modeChoices(named: false) ?? [] })))
        if let option, option.fast {
            let on = chat.map(fastMode(of:)) ?? startingFast
            items.append(command("fast.toggle", on ? "Fast mode off" : "Fast mode on", icon: on ? "bolt.slash" : "bolt",
                                 subtitle: on ? PickerState(model: self, chat: chat).fastProblem : nil, keywords: ["speed", "fast"],
                                 unavailable: noProject) { [weak self] in self?.setFast(!on, for: chat) })
        }
        items.append(command("model.defaults", "Back to defaults", icon: "arrow.counterclockwise",
                             unavailable: noProject ?? (atDefaults(chat) ? "Already at the defaults" : nil)) { [weak self] in
            self?.resetToDefaults(for: chat)
        })
        if let option, option.needs == nil {
            let starred = favoriteModels.contains(option.id)
            items.append(command("model.star", starred ? "Unstar \(option.name)" : "Star \(option.name)", icon: starred ? "star.slash" : "star",
                                 keywords: ["favorite", "favourite"]) { [weak self] in self?.toggleFavorite(option.id) })
        }
        items.append(command("model.card", "Model and effort", icon: "slider.horizontal.3", shortcut: "⌘⇧M", unavailable: noProject) { [weak self] in
            self?.modelPickerShown.toggle()
        })

        // Git, in the thread's folder
        items += gitCommands

        // The terminal, and your own actions
        items += terminalCommands
        items += customActionCommands

        // Projects and files
        items.append(PaletteItem(id: "project.list", kind: .command, title: "Switch project…", subtitle: project?.name, icon: "folder",
                                 unavailable: projects.count > 1 ? nil : "There's only one project",
                                 action: .list(PaletteList(title: "Project", placeholder: "Search projects") { [weak self] in self?.paletteProjects ?? [] })))
        items.append(command("project.add", "Add project…", icon: "folder.badge.plus", shortcut: "⌘O") { [weak self] in self?.addProject() })
        items.append(command("files.find", "Find a file", icon: "doc.text.magnifyingglass", shortcut: "⌘P", unavailable: noThread) { [weak self] in
            self?.toggleFileFinder()
        })
        items.append(command("changes", "Changes", icon: "plusminus", shortcut: "⌘⇧D", keywords: ["commit", "diff", "stage", "git"],
                             unavailable: noThread) { [weak self] in self?.openChanges() })

        // Quality of life
        items += qualityCommands

        // The app
        items.append(command("settings", "Settings", icon: "gearshape", shortcut: "⌘,") { [weak self] in self?.openSettings(nil) })
        items.append(command("shortcuts", "Keyboard shortcuts", icon: "keyboard", shortcut: "⌘/", keywords: ["keys"]) { [weak self] in
            self?.showingShortcuts = true
        })
        return items
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
    /// top level.
    private func modelChoices(named: Bool) -> [PaletteItem] {
        guard project != nil else { return [] }
        let current = option(for: chat)?.id
        return modelGroups.flatMap(\.models).map { option in
            PaletteItem(id: "model." + option.id, kind: .choice, title: (named ? "Model: " : "") + option.name,
                        subtitle: option.description.isEmpty ? nil : option.description, icon: "cpu", checked: option.id == current,
                        unavailable: option.needs.map { "Needs Claude Code \($0)" },
                        action: .run { [weak self] in
                            guard let self else { return }
                            withAnimation(Motion.move) { self.setModel(option.id, for: self.chat) }
                        })
        }
    }

    private func effortChoices(named: Bool) -> [PaletteItem] {
        guard project != nil, let option = option(for: chat), !option.levels.isEmpty else { return [] }
        let current = (chat == nil ? startingEffort : chat?.effort).flatMap { option.levels.contains($0) ? $0 : nil }
        let prefix = named ? "Effort: " : ""
        let home = defaultLevel(for: chat).map { "Default (\(ModelMenu.effortName($0)))" } ?? "Default"
        var items = [PaletteItem(id: "effort.default", kind: .choice, title: prefix + home, icon: "gauge.with.dots.needle.50percent",
                                 checked: current == nil, action: .run { [weak self] in
                                     guard let self else { return }
                                     withAnimation(Motion.move) { self.setEffort(nil, for: self.chat) }
                                 })]
        let levels = option.efforts + (option.ultra || option.ultraBlocked != nil ? [Effort.ultracode] : [])
        items += levels.map { level in
            PaletteItem(id: "effort." + level, kind: .choice, title: prefix + ModelMenu.effortName(level),
                        subtitle: EffortScale.line(level).0, icon: "gauge.with.dots.needle.67percent", checked: current == level,
                        unavailable: level == Effort.ultracode && !option.ultra ? "Needs dynamic workflows, see /config in Claude Code" : nil,
                        action: .run { [weak self] in
                            guard let self else { return }
                            withAnimation(Motion.move) { self.setEffort(level, for: self.chat) }
                        })
        }
        return items
    }

    private func modeChoices(named: Bool) -> [PaletteItem] {
        guard project != nil else { return [] }
        let current = chat?.permissionMode ?? startingPermissionMode
        return PermissionModeOption.allCases.map { mode in
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
            if case .user(_, let text, _) = item { return text }
            return nil
        }.first
    }

    /// Claude's text since the last message sent, which is the last reply.
    var lastReply: String? {
        guard let items = currentConversation?.items, let sent = items.lastIndex(where: { if case .user = $0 { true } else { false } }) else { return nil }
        let texts = items[(sent + 1)...].compactMap { item -> String? in
            if case .text(_, let text) = item { return text }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    /// The thread's messages and Claude's text, as Markdown.
    var threadMarkdown: String? {
        guard let items = currentConversation?.items else { return nil }
        let parts = items.compactMap { item -> String? in
            switch item {
            case .user(_, let text, _): "**You**\n\n" + text
            case .text(_, let text): "**Claude**\n\n" + text
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
