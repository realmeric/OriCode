import Foundation

/// What an agent does from OriCode's menus, ⌘K and Settings (K-303), through the oricode server's
/// menu tools (engine/threads.ts). Each comes as `oricode.act` with the tool's name and arguments
/// and is done as the menu does it, with a quiet line in the asking thread. A change that loosens
/// what guards the user is answered with `change`, the sentence the engine asks them to allow, and
/// comes again with `allowed` once they have. Tightening is the agent's own call, and nothing here
/// reads or sets a login or an API key (rule 3).
extension AppModel {
    func menuAct(_ body: JSON, from asking: UUID) async throws -> JSON {
        guard let chat = chat(withID: asking) else { throw Refused(why: "The thread that asked is gone.") }
        let args = body["args"] ?? .null
        let allowed = body["allowed"]?.bool == true
        let reason = args["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch body["tool"]?.string ?? "" {
        case "rename_thread":
            let target = try thread(args["thread"]?.string, from: chat)
            let title = Chat.title(from: args["title"]?.string ?? "")
            guard !title.isEmpty else { throw Refused(why: "A thread needs a name in `title`.") }
            let was = target.title
            rename(target, to: title)
            did("Renamed \(was) to \(target.title)", on: target, by: chat, reason: reason)
            return ["thread": .string(target.title), "id": .string(target.id.uuidString)]
        case "archive_thread":
            let target = try other(args["thread"]?.string ?? "", from: asking, doing: "archive_thread").thread
            guard !target.archived else { throw Refused(why: "\(target.title) is archived already.") }
            guard conversations[target.id]?.running != true, !workflowRuns(in: target) else {
                throw Refused(why: "\(target.title) is working. Stop it with stop_thread first, then archive it.")
            }
            guard !threads(under: target).contains(where: { !$0.archived && (conversations[$0.id]?.running == true || workflowRuns(in: $0)) }) else {
                throw Refused(why: "A thread under \(target.title) is working. Stop it with stop_thread first.")
            }
            archive(target)
            did("Archived \(target.title)", on: target, by: chat, reason: reason)
            return ["thread": .string(target.title), "archived": true]
        case "restore_thread":
            let target = try other(args["thread"]?.string ?? "", from: asking, doing: "restore_thread").thread
            guard target.archived else { throw Refused(why: "\(target.title) isn't archived.") }
            // As restore() does, without opening it: the user stays on their thread.
            let went = target.archivedWith ?? target.id
            for thread in [target] + threads(under: target).filter({ $0.archived && $0.archivedWith == went }) {
                thread.archived = false
                thread.archivedWith = nil
            }
            save()
            did("Restored \(target.title)", on: target, by: chat, reason: reason)
            return ["thread": .string(target.title), "archived": false]
        case "delete_thread":
            let target = try other(args["thread"]?.string ?? "", from: asking, doing: "delete_thread").thread
            guard target.agentID == nil || !workflowRuns(in: target) else { throw Refused(why: "Stop \(target.agentStopFirst) before deleting it.") }
            askToDelete(target)
            did("Asked to delete \(target.title)", on: target, by: chat, reason: reason)
            return ["thread": .string(target.title), "askedTheUser": true, "deleted": false]
        case "pin_thread":
            let target = try thread(args["thread"]?.string, from: chat)
            guard let pinned = args["pinned"]?.bool else { throw Refused(why: "Say true or false in `pinned`.") }
            guard !target.archived else { throw Refused(why: "\(target.title) is archived. Restore it first.") }
            if target.pinned != pinned { togglePin(target) }
            did(pinned ? "Pinned \(target.title)" : "Unpinned \(target.title)", on: target, by: chat, reason: reason)
            return ["thread": .string(target.title), "pinned": .bool(pinned)]
        case "open_beside":
            let target = try other(args["thread"]?.string ?? "", from: asking, doing: "open_beside").thread
            guard target.started, !target.archived else { throw Refused(why: "\(target.title) is archived or hasn't started, so it can't come beside.") }
            openBeside(target)
            did("Put \(target.title) beside", on: target, by: chat, reason: reason)
            return ["beside": .string(target.title), "roomForTwo": .bool(roomForTwo)]
        case "close_other_side":
            guard let beside = besideChatID.flatMap(chat(withID:)) else { throw Refused(why: "No thread is beside the open one.") }
            closeOtherSide()
            did("Closed \(beside.title) beside", on: beside, by: chat, reason: reason)
            return ["closed": .string(beside.title)]
        case "show":
            return try show(args, from: chat, reason: reason)
        case "change_thread":
            return try changeThread(args, from: chat, allowed: allowed, reason: reason)
        case "change_setting":
            return try changeSetting(args, from: chat, allowed: allowed, reason: reason)
        case "add_project":
            let typed = args["folder"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let url = URL(fileURLWithPath: (typed as NSString).expandingTildeInPath).standardizedFileURL
            var folder: ObjCBool = false
            guard !typed.isEmpty, FileManager.default.fileExists(atPath: url.path, isDirectory: &folder), folder.boolValue else {
                throw Refused(why: "\(typed.isEmpty ? "That" : typed) isn't a folder on this Mac.")
            }
            if let existing = projects.first(where: { $0.path == url.path }) { return ["project": .string(existing.name), "added": false] }
            let project = Project(name: url.lastPathComponent, path: url.path)
            project.colorIndex = ProjectColor.pick(taken: projects.compactMap(\.colorIndex))
            context.insert(project)
            save()
            did("Added the project \(project.name)", on: nil, by: chat, reason: reason)
            return ["project": .string(project.name), "added": true]
        case "run_command":
            let command = args["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !command.isEmpty else { throw Refused(why: "Say the command in `command`.") }
            if !allowed, looseness(of: chat) < Self.tightness.firstIndex(of: "auto")! {
                return ["change": .string("Run \(command) in a terminal block in this thread")]
            }
            guard runCommand(command, in: chat) != nil else { throw Refused(why: "The shell couldn't start in this thread's folder.") }
            did("Ran \(command)", on: nil, by: chat, reason: reason)
            return ["started": true, "folder": .string(chat.cwd)]
        case "read_oricode":
            return readOriCode()
        case let tool:
            throw Refused(why: "OriCode has no tool called \(tool).")
        }
    }

    /// A thread a menu tool names, this one when none is named. Unlike `other`, it may be itself.
    private func thread(_ named: String?, from chat: Chat) throws -> Chat {
        guard let named = named?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty else { return chat }
        guard let found = threads(around: chat).first(where: { $0.id.uuidString.caseInsensitiveCompare(named) == .orderedSame }) else {
            throw Refused(why: "No thread of this project has the id \(named). list_threads gives the ones there are.")
        }
        return found
    }

    /// A quiet line in the thread it did it to, when that's another the user may be reading. The
    /// asking thread has none: its call says what it did, in words, inside its turn.
    private func did(_ what: String, on target: Chat?, by chat: Chat, reason: String, there: String? = nil) {
        let target = target ?? chat
        if let there, target.id != chat.id, !target.archived {
            conversation(for: target).threadAct(ThreadAct(act: .did, by: false, thread: chat.id, title: chat.title, reason: reason, what: there))
        }
    }

    private func show(_ args: JSON, from chat: Chat, reason: String) throws -> JSON {
        let path = args["path"]?.string?.nonEmpty
        let line = args["line"]?.int
        switch args["what"]?.string ?? "" {
        case "review":
            guard chat.cwd == workingFolder else {
                throw Refused(why: "The user has \(self.chat?.title ?? "another thread") open, and the review shows its changes, not this thread's. Show the file instead.")
            }
            if let path { openReview(at: path, line: line ?? 1) } else { openReview() }
        case "file":
            guard let path else { throw Refused(why: "Name the file in `path`.") }
            openFile(path, line: line, in: chat.cwd)
        case "everything_running":
            if !overviewShown { toggleOverview() }
        case "heads":
            guard let open = self.chat, showsHeads(open) else { throw Refused(why: "The thread the user has open has no heads to show.") }
            if !headsShown { toggleHeads() }
        case "threads":
            showDrawer()
        case "settings":
            let pane = args["pane"]?.string.flatMap(SettingsPane.init(rawValue:))
            openSettings(pane)
            did("Opened Settings\(pane.map { " › \($0.title)" } ?? "")", on: nil, by: chat, reason: reason)
        case "shortcuts":
            showingShortcuts = true
        case let what:
            throw Refused(why: "OriCode can't show \(what.isEmpty ? "nothing" : what). It shows review, file, everything_running, heads, threads, settings or shortcuts.")
        }
        return ["shown": .string(args["what"]?.string ?? "")]
    }

    /// The Thread menu's pickers. Everything is checked before anything changes, so a refusal or
    /// the user's ask leaves the thread as it was.
    private func changeThread(_ args: JSON, from chat: Chat, allowed: Bool, reason: String) throws -> JSON {
        let target = try thread(args["thread"]?.string, from: chat)
        let agent = agent(for: target)
        var said: [String] = []

        let model = args["model"]?.string?.nonEmpty
        if let model {
            let listed = models(of: target.providerID)
            guard !listed.isEmpty else { throw Refused(why: "\(agent.name) didn't list its models just now, so OriCode can't tell whether \(model) is one.") }
            guard listed.contains(where: { $0.id == model }) else {
                throw Refused(why: "\(agent.name) has no model called \(model). It has: \(listed.map(\.id).joined(separator: ", ")).")
            }
        }
        let option = model.flatMap { model in models(of: target.providerID).first { $0.id == model } } ?? option(for: target)
        let effort = args["effort"]?.string?.nonEmpty
        if let effort, effort != NewThreads.claudeDefault, !(option?.efforts.contains(effort) ?? false) {
            throw Refused(why: "\(option?.name ?? agent.name) has no level called \(effort). It has: \((option?.efforts ?? []).joined(separator: ", ")).")
        }
        let fast = args["fast_mode"]?.bool
        if fast == true, option?.fast != true { throw Refused(why: "\(option?.name ?? agent.name) has no fast mode.") }
        let workflows = args["workflows"]?.bool
        if workflows == true, option?.ultra != true { throw Refused(why: "\(option?.name ?? agent.name) can't run workflows.") }
        let mode = args["permission_mode"]?.string?.nonEmpty
        if let mode {
            guard agent.modes.contains(mode) else { throw Refused(why: "\(agent.name) has no permission mode called \(mode). It has: \(agent.modes.joined(separator: ", ")).") }
            let title = PermissionModeOption(rawValue: mode)?.title ?? mode
            if !allowed, (Self.tightness.firstIndex(of: mode) ?? Self.tightness.count) > looseness(of: target) {
                let was = PermissionModeOption(rawValue: target.permissionMode)?.title ?? target.permissionMode
                return ["change": .string(target.id == chat.id ? "Set this thread's permission mode to \(title), from \(was)" : "Set \(target.title)'s permission mode to \(title), from \(was)")]
            }
        }
        guard model != nil || effort != nil || fast != nil || workflows != nil || mode != nil else {
            throw Refused(why: "Say what to change: model, effort, fast_mode, workflows or permission_mode.")
        }

        if let model, let option {
            target.model = model
            if let level = target.effort, !option.efforts.contains(level) { target.effort = nil }
            said.append(option.name)
        }
        if let effort {
            target.effort = effort == NewThreads.claudeDefault ? nil : effort
            said.append("effort \(effort == NewThreads.claudeDefault ? "Default" : ModelMenu.effortName(effort))")
        }
        if let workflows {
            target.workflows = workflows
            said.append(workflows ? "Workflows on" : "Workflows off")
        }
        if let fast {
            target.fastMode = fast
            said.append(fast ? "fast mode on" : "fast mode off")
            let on = fastMode(of: target)
            Task { _ = try? await engine.request("setFast", ["threadId": .string(target.id.uuidString), "fast": .bool(on)]) }
        }
        if let mode {
            target.permissionMode = mode
            said.append(PermissionModeOption(rawValue: mode)?.title ?? mode)
            Task { _ = try? await engine.request("setMode", ["threadId": .string(target.id.uuidString), "permissionMode": .string(mode)]) }
        }
        save()
        let what = said.joined(separator: ", ")
        did(target.id == chat.id ? "Set this thread to \(what)" : "Set \(target.title) to \(what)", on: target, by: chat, reason: reason, there: "Set this thread to \(what)")
        return ["thread": .string(target.title), "model": target.model.map(JSON.string) ?? .null, "effort": target.effort.map(JSON.string) ?? .null,
                "fastMode": .bool(target.fastMode), "workflows": .bool(target.workflows), "permissionMode": .string(target.permissionMode)]
    }
}

// MARK: - Settings

/// A setting change_setting takes, by the name read_oricode lists it under, and the defaults key
/// Settings keeps it in.
@MainActor
struct MenuSetting {
    enum Kind {
        case toggle(Bool)
        case number(Double, ClosedRange<Double>)
        case whole(Int, ClosedRange<Int>)
        /// Each word the agent says, with what's stored for it.
        case choice([(word: String, stored: String)])
        case text(String)
    }

    let name: String
    let key: String
    let kind: Kind

    static let modes = AppModel.tightness.map { (word: $0, stored: $0) }

    static let all: [MenuSetting] = [
        MenuSetting(name: "heads_may_start_workers", key: Rays.allowKey, kind: .toggle(true)),
        MenuSetting(name: "heads_choose", key: Rays.chooseKey, kind: .toggle(false)),
        MenuSetting(name: "spend_per_thread", key: Rays.budgetKey, kind: .number(0, 0...(Rays.budgets.max() ?? 0))),
        MenuSetting(name: "threads_working_at_once", key: AppModel.ceilingKey, kind: .whole(AppModel.defaultCeiling, 1...20)),
        MenuSetting(name: "threads_answer_first", key: AppModel.openersAnswerKey, kind: .toggle(false)),
        MenuSetting(name: "show_thinking", key: TranscriptSettings.showThinking, kind: .toggle(true)),
        MenuSetting(name: "concise_replies", key: TranscriptSettings.concise, kind: .toggle(false)),
        MenuSetting(name: "how_long_it_took", key: TranscriptSettings.showTime, kind: .toggle(false)),
        MenuSetting(name: "what_it_cost", key: TranscriptSettings.showCost, kind: .toggle(false)),
        MenuSetting(name: "water", key: TranscriptSettings.showWater, kind: .toggle(false)),
        MenuSetting(name: "go_on_when_a_limit_resets", key: Limit.goOnKey, kind: .toggle(true)),
        MenuSetting(name: "notify", key: "notify", kind: .toggle(true)),
        MenuSetting(name: "glass", key: Glass.key, kind: .number(Glass.defaultTint, Glass.range)),
        MenuSetting(name: "transparency", key: Glass.transparencyKey, kind: .number(Glass.defaultTransparency, 0...1)),
        MenuSetting(name: "new_threads_permissions", key: NewThreads.permissionMode, kind: .choice([(word: "last_picked", stored: "")] + modes)),
        MenuSetting(name: "new_threads_fast_mode", key: NewThreads.fast, kind: .choice([("last_picked", ""), ("on", NewThreads.on), ("off", NewThreads.off)])),
        MenuSetting(name: "new_threads_workspace", key: NewThreads.workspace, kind: .choice([("projects_folder", ""), ("its_own_branch", NewThreads.worktree)])),
        MenuSetting(name: "review", key: ReviewDesign.key, kind: .choice(ReviewDesign.allCases.map { (word: $0.rawValue, stored: $0.rawValue) })),
        MenuSetting(name: "branch_prefix", key: NewThreads.branchPrefix, kind: .text(NewThreads.defaultBranchPrefix)),
        MenuSetting(name: "write_message_with", key: NewThreads.messageModel, kind: .choice([("a_small_model", ""), ("the_threads_model", NewThreads.threadModel)])),
    ]

    var value: JSON {
        let defaults = UserDefaults.standard
        switch kind {
        case .toggle(let standard): return .bool(defaults.object(forKey: key) as? Bool ?? standard)
        case .number(let standard, _): return .number(defaults.object(forKey: key) as? Double ?? standard)
        case .whole(let standard, _): return .number(Double(defaults.object(forKey: key) as? Int ?? standard))
        case .choice(let words):
            let stored = defaults.string(forKey: key) ?? words[0].stored
            return .string(words.first { $0.stored == stored }?.word ?? stored)
        case .text(let standard): return .string(defaults.string(forKey: key) ?? standard)
        }
    }

    /// The value as it will be stored, or why it can't be.
    func parse(_ given: JSON) throws -> Any {
        switch kind {
        case .toggle:
            guard let on = given.bool else { throw AppModel.Refused(why: "\(name) is true or false.") }
            return on
        case .number(_, let range):
            guard let number = given.double, range.contains(number) else { throw AppModel.Refused(why: "\(name) is a number from \(range.lowerBound) to \(range.upperBound).") }
            if key == Rays.budgetKey, !Rays.budgets.contains(number) {
                throw AppModel.Refused(why: "spend_per_thread is one of \(Rays.budgets.map { $0 == 0 ? "0 (none)" : Rays.budgetName($0) }.joined(separator: ", ")).")
            }
            return number
        case .whole(_, let range):
            guard let number = given.int, range.contains(number) else { throw AppModel.Refused(why: "\(name) is a whole number from \(range.lowerBound) to \(range.upperBound).") }
            return number
        case .choice(let words):
            guard let word = given.string, let found = words.first(where: { $0.word == word }) else {
                throw AppModel.Refused(why: "\(name) is one of: \(words.map(\.word).joined(separator: ", ")).")
            }
            return found.stored
        case .text:
            guard let text = given.string?.trimmingCharacters(in: .whitespacesAndNewlines) else { throw AppModel.Refused(why: "\(name) is a word.") }
            return text
        }
    }

    /// Whether going from `old` to `new` loosens what guards the user: a higher spend or none, more
    /// threads at once, threads answering asks for the user, or a looser mode for new threads,
    /// `lastPicked` standing for what Last picked would give.
    static func loosens(_ name: String, from old: JSON, to new: JSON, lastPicked: String = "default") -> Bool {
        switch name {
        case "spend_per_thread":
            let (was, now) = (old.double ?? 0, new.double ?? 0)
            return was != 0 && (now == 0 || now > was)
        case "threads_working_at_once":
            return (new.double ?? 0) > (old.double ?? 0)
        case "threads_answer_first":
            return new.bool == true && old.bool != true
        case "new_threads_permissions":
            func rank(_ value: JSON) -> Int {
                let word = value.string.flatMap { $0 == "last_picked" ? nil : $0 } ?? lastPicked
                return AppModel.tightness.firstIndex(of: word) ?? AppModel.tightness.count
            }
            return rank(new) > rank(old)
        default:
            return false
        }
    }
}

extension AppModel {
    private func changeSetting(_ args: JSON, from chat: Chat, allowed: Bool, reason: String) throws -> JSON {
        let name = args["setting"]?.string ?? ""
        let given = args["value"] ?? .null
        switch name {
        case "this_projects_check":
            guard let project = chat.project, !project.isNoFolder else { throw Refused(why: "This thread has no project folder to name a check for.") }
            setCheck(given.string ?? "", for: project)
            did("Set \(project.name)'s check to \(given.string?.nonEmpty ?? "none")", on: nil, by: chat, reason: reason)
            return ["setting": .string(name), "value": .string(project.check ?? "")]
        case "keep_heads_off":
            guard let ref = given["model"]?.string?.nonEmpty, let off = given["off"]?.bool, ref.contains("/") else {
                throw Refused(why: "keep_heads_off takes {\"model\": \"agent/model\", \"off\": true or false}.")
            }
            keepHeadsOff(ModelRef(stored: ref), off)
            did(off ? "Kept heads off \(ref)" : "Let heads use \(ref) again", on: nil, by: chat, reason: reason)
            return ["setting": .string(name), "value": .array(headsKeepOff.map(JSON.string))]
        case "agent_on":
            guard let id = given["agent"]?.string?.nonEmpty, let on = given["on"]?.bool else { throw Refused(why: "agent_on takes {\"agent\": \"codex\", \"on\": true or false}.") }
            guard let agent = agents.first(where: { $0.id == id }) else { throw Refused(why: "OriCode has no agent called \(id). It has: \(agents.map(\.id).joined(separator: ", ")).") }
            guard on || (id != "claude" && id != chat.providerID) else { throw Refused(why: "\(agent.name) can't be turned off from a thread that runs on it, and Claude Code never is.") }
            turnAgent(id, on: on)
            did(on ? "Turned \(agent.name) on" : "Turned \(agent.name) off", on: nil, by: chat, reason: reason)
            return ["setting": .string(name), "agent": .string(id), "on": .bool(on)]
        default:
            break
        }
        guard let setting = MenuSetting.all.first(where: { $0.name == name }) else {
            throw Refused(why: "OriCode has no setting called \(name). read_oricode lists the ones change_setting takes.")
        }
        let stored = try setting.parse(given)
        let old = setting.value
        let new = given
        let last = UserDefaults.standard.string(forKey: "lastPermissionMode") ?? PermissionModeOption.ask.rawValue
        if !allowed, MenuSetting.loosens(name, from: old, to: new, lastPicked: last) {
            return ["change": .string("Set \(name.replacingOccurrences(of: "_", with: " ")) to \(Self.words(new)), from \(Self.words(old))")]
        }
        UserDefaults.standard.set(stored, forKey: setting.key)
        if name == "threads_answer_first", given.bool == false { handAsksToUser() }
        did("Set \(name.replacingOccurrences(of: "_", with: " ")) to \(Self.words(new))", on: nil, by: chat, reason: reason)
        return ["setting": .string(name), "value": setting.value]
    }

    private static func words(_ value: JSON) -> String {
        switch value {
        case .bool(let on): on ? "on" : "off"
        case .number(let number): number == number.rounded() ? String(Int(number)) : String(number)
        case .string(let text): text.replacingOccurrences(of: "_", with: " ")
        default: "\(value)"
        }
    }

    /// read_oricode: what the window shows, and every setting change_setting takes.
    private func readOriCode() -> JSON {
        var shown: [String: JSON] = [
            "threadsList": .bool(threadsOut), "review": .bool(reviewShown), "everythingRunning": .bool(overviewShown), "heads": .bool(headsShown),
        ]
        if let open = chat { shown["open"] = ["id": .string(open.id.uuidString), "title": .string(open.title), "project": .string(open.project?.name ?? "")] }
        if let beside = besideChatID.flatMap(chat(withID:)) { shown["beside"] = ["id": .string(beside.id.uuidString), "title": .string(beside.title)] }
        if let file = openFile { shown["file"] = .string(file.path) }
        var settings = Dictionary(uniqueKeysWithValues: MenuSetting.all.map { ($0.name, $0.value) })
        settings["this_projects_check"] = .string((chat?.project ?? project)?.check ?? "")
        settings["keep_heads_off"] = .array(headsKeepOff.map(JSON.string))
        settings["agent_on"] = .object(Dictionary(uniqueKeysWithValues: agents.map { ($0.id, JSON.bool(agentSettings.isOn($0.id))) }))
        return ["shown": .object(shown), "settings": .object(settings), "projects": .array(projects.filter { !$0.isNoFolder }.map { .string($0.path) })]
    }
}
