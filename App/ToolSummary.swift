import Foundation

/// The quiet one-line description of a tool call: "Read App/Engine.swift", "Bash: swift build".
enum ToolSummary {
    /// `titles` names a thread by its id, for an OriCode tool still out on one, whose answer
    /// would have named it.
    static func line(for call: ToolCall, cwd: String, titles: (UUID) -> String? = { _ in nil }) -> String {
        if let words = oricode(call, titles: titles) { return words }
        let input = call.input
        func path(_ key: String = "file_path") -> String {
            relative(call.view["path"]?.string ?? input[key]?.string ?? input["path"]?.string ?? "", to: cwd)
        }
        /// A fixed verb and what it's on. An agent's call that doesn't say what it's on keeps its
        /// own title, where Claude's has always shown the verb alone.
        func verb(_ verb: String, _ target: String) -> String {
            target.isEmpty && !call.namedByClaude ? call.name : "\(verb) \(target)"
        }
        switch call.kind {
        case .read: return verb("Read", path())
        case .edit: return verb("Edit", path())
        case .write: return verb("Write", path())
        case .notebook: return "Edit \(path("notebook_path"))"
        case .delete: return verb("Delete", path())
        case .move: return verb("Move", path())
        case .run:
            // Claude's tool by its name, "Bash: make test". An agent's title is a word or a
            // sentence depending on the agent, so its command goes under the kind's own word.
            let command = firstLine(call.shown("command") ?? "")
            if call.namedByClaude { return "\(call.name): \(command)" }
            return command.isEmpty ? call.name : "Run: \(command)"
        case .search:
            if call.namedByClaude { return "\(call.name) \(input["pattern"]?.string ?? "")" }
            return verb("Search", call.shown("pattern") ?? call.shown("query") ?? "")
        case .fetch: return verb("Fetch", call.shown("url") ?? "")
        case .web: return verb("Search", call.shown("query") ?? call.shown("url") ?? "")
        case .list where !call.namedByClaude: return verb("List", path())
        case .agent: return "Agent: \(call.shown("description") ?? "")"
        case .plan: return "Update the plan"
        case .question: return "Ask you"
        case .planning: return "Finish planning"
        case .skill: return "Skill: \(input["skill"]?.string ?? input["command"]?.string ?? "")"
        case .list, .think, .workflow, .mcp, .other: return name(call.name)
        }
    }

    /// OriCode's own tools in words, as Claude Code's are: "Opened Count A", "Waited on Count A".
    /// Nil for any other tool.
    static func oricode(_ call: ToolCall, titles: (UUID) -> String? = { _ in nil }) -> String? {
        guard let tool = call.oricodeTool else { return nil }
        let other = call.otherThread
        let title = other.title ?? other.id.flatMap(titles) ?? "a thread"
        // A wait still open is said as it is, beside the line's result coming back.
        let waits = call.result == nil && !call.isError ? "Waiting on" : "Waited on"
        return switch tool {
        case "open_thread": "Opened \(title)"
        case "message_thread": "Messaged \(title)"
        case "wait_thread": "\(waits) \(title)"
        case "read_thread": "Read \(title)"
        case "stop_thread": "Stopped \(title)"
        case "merge_thread": "Merged \(title)"
        case "finish_merge": "Finished the merge"
        case "answer_ask": "Answered an ask"
        case "suggest_thread": "Suggested a thread"
        case "list_threads": "Listed threads"
        case "rename_thread": "Renamed \(title)"
        case "archive_thread": "Archived \(title)"
        case "restore_thread": "Restored \(title)"
        case "delete_thread": "Asked to delete \(title)"
        case "pin_thread": "Pinned \(title)"
        case "open_beside": "Opened \(title) beside"
        case "close_other_side": "Closed the other side"
        case "change_thread": "Changed \(title)"
        case "change_setting": "Changed a setting"
        case "show": "Showed \(call.input["what"]?.string ?? "something")"
        case "add_project": "Added a project"
        // Also what its ask says, so in the words an agent's command has.
        case "run_command": "Run: \(firstLine(call.input["command"]?.string ?? ""))"
        case "read_oricode": "Read OriCode's settings"
        case "read_plan": "Read the plan"
        case "add_tasks": "Planned"
        case "wait_plan": "\(waits) the plan"
        case "claim_task": "Took a task"
        case "update_task": "Updated a task"
        case "list_agents": "Listed agents"
        case "change_my_model": "Changed its model"
        case "start_worker": "Started a worker"
        case "message_worker": "Messaged a worker"
        case "worker_status": "Checked on its workers"
        case "worker_result": "Read a worker's result"
        case "stop_worker": "Stopped a worker"
        case "merge_worker": "Merged a worker"
        case "list_apps": "Listed apps"
        case "screenshot": "Looked at \(call.input["app"]?.string ?? "an app")"
        case "click": "Clicked in \(call.input["app"]?.string ?? "an app")"
        case "type_text": "Typed in \(call.input["app"]?.string ?? "an app")"
        case "press_key": "Pressed \(call.input["keys"]?.string ?? "a key")"
        case "scroll": "Scrolled in \(call.input["app"]?.string ?? "an app")"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalizedFirst
        }
    }

    /// A tool's name as the thread shows it: an MCP server's tool as "server › tool".
    static func name(_ tool: String) -> String {
        tool.hasPrefix("mcp__") ? tool.split(separator: "__").dropFirst().joined(separator: " › ") : tool
    }

    /// What a call is on, without the tool: the file, the command's first line, the pattern, the
    /// page or the question, in the shape the engine gives an agent's step.
    static func target(for call: ToolCall, cwd: String) -> String? {
        if let path = call.file ?? call.input["notebook_path"]?.string { return relative(path, to: cwd) }
        if let command = call.shown("command") { return firstLine(command) }
        return ["pattern", "url", "query", "description", "skill", "path"].lazy.compactMap { call.shown($0) }.first { !$0.isEmpty }
    }

    /// What a run of calls did, in Claude Code's words, each kind where it first came: "Read 2
    /// files, ran 3 commands, searched for 1 pattern". A file counts once however often it's
    /// read or edited, and a thread once, only when the call reached it; waiting on threads is
    /// said only when the run did nothing else.
    static func run(_ calls: [ToolCall]) -> String {
        var kinds: [RunKind] = []
        var seen: [RunKind: Set<String>] = [:]
        for call in calls {
            let kind = RunKind(call)
            if kind.onThreads, call.isError { continue }
            if seen[kind] == nil { kinds.append(kind) }
            seen[kind, default: []].insert(path(for: call) ?? call.otherThread.id?.uuidString ?? call.toolUseId)
        }
        if kinds.count > 1 { kinds.removeAll { $0 == .waited } }
        guard !kinds.isEmpty else { return RunKind.other.phrase(calls.count).capitalizedFirst }
        if kinds == [.waited], calls.contains(where: { RunKind($0) == .waited && $0.result == nil && !$0.isError }) {
            let count = seen[.waited]?.count ?? 0
            return "Waiting on \(count) \(count == 1 ? "thread" : "threads")"
        }
        return kinds.map { $0.phrase(seen[$0]?.count ?? 0) }.joined(separator: ", ").capitalizedFirst
    }

    private enum RunKind {
        case read, edit, command, search, list, fetch, web, agent, plan, skill, question, planning, opened, messaged, waited, stopped, other

        var onThreads: Bool { [.opened, .messaged, .waited, .stopped].contains(self) }

        init(_ call: ToolCall) {
            switch call.oricodeTool {
            case "open_thread": self = .opened
            case "message_thread": self = .messaged
            case "wait_thread", "read_thread": self = .waited
            case "stop_thread": self = .stopped
            default: self.init(call.kind)
            }
        }

        init(_ kind: ToolKind) {
            switch kind {
            case .read: self = .read
            case .edit, .write, .notebook, .delete, .move: self = .edit
            case .run: self = .command
            case .search: self = .search
            case .list: self = .list
            case .fetch: self = .fetch
            case .web: self = .web
            case .agent: self = .agent
            case .plan: self = .plan
            case .skill: self = .skill
            case .question: self = .question
            case .planning: self = .planning
            case .think, .workflow, .mcp, .other: self = .other
            }
        }

        func phrase(_ count: Int) -> String {
            let one = count == 1
            return switch self {
            case .read: "read \(count) \(one ? "file" : "files")"
            case .edit: "edited \(count) \(one ? "file" : "files")"
            case .command: "ran \(count) \(one ? "command" : "commands")"
            case .search: "searched for \(count) \(one ? "pattern" : "patterns")"
            case .list: "listed \(count) \(one ? "directory" : "directories")"
            case .fetch: "fetched \(count) \(one ? "page" : "pages")"
            case .web: one ? "searched the web" : "searched the web \(count) times"
            case .agent: "ran \(count) \(one ? "agent" : "agents")"
            case .plan: "updated the plan"
            case .skill: "used \(count) \(one ? "skill" : "skills")"
            case .question: "asked you"
            case .planning: "finished planning"
            case .opened: "opened \(count) \(one ? "thread" : "threads")"
            case .messaged: "messaged \(count) \(one ? "thread" : "threads")"
            case .waited: "waited on \(count) \(one ? "thread" : "threads")"
            case .stopped: "stopped \(count) \(one ? "thread" : "threads")"
            case .other: "used \(count) \(one ? "tool" : "tools")"
            }
        }
    }

    /// The file a call that reads, edits, writes, deletes or moves one touched, as given to the tool.
    static func path(for call: ToolCall) -> String? {
        switch call.kind {
        case .read, .edit, .write, .delete, .move: call.file
        case .notebook: call.view["path"]?.string ?? call.input["notebook_path"]?.string
        default: nil
        }
    }

    /// A path inside the thread's folder from the folder, under the folder's real path too, which an
    /// agent names its files by when the folder was added by a link.
    static func relative(_ path: String, to cwd: String) -> String {
        let path = (path as NSString).standardizingPath
        let cwd = (cwd as NSString).standardizingPath
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        let real = (cwd as NSString).resolvingSymlinksInPath
        if real != cwd, path.hasPrefix(real + "/") { return String(path.dropFirst(real.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The first line that has anything on it, to 120 characters. Read no further than that, since
    /// a queued paste can be one line a megabyte long.
    static func firstLine(_ text: String) -> String {
        let line = text.drop { $0 == "\n" }.prefix(121).prefix { $0 != "\n" }
        return line.count > 120 ? String(line.prefix(120)) + "…" : String(line)
    }
}

extension ToolCall {
    /// One of OriCode's own tools, by its name without the server: "wait_thread".
    var oricodeTool: String? {
        name.hasPrefix("mcp__oricode__") ? String(name.dropFirst("mcp__oricode__".count)) : nil
    }

    /// The thread an OriCode tool was about, by the id it was asked about. open_thread is asked by
    /// a title, and its answer, a few lines, names the thread it made.
    var otherThread: (id: UUID?, title: String?) {
        guard oricodeTool == "open_thread" else { return (input["thread"]?.string.flatMap(UUID.init(uuidString:)), nil) }
        let made = isError ? nil : result.flatMap { try? JSONDecoder().decode(JSON.self, from: Data($0.utf8)) }
        return (made?["id"]?.string.flatMap(UUID.init(uuidString:)), made?["thread"]?.string ?? input["title"]?.string)
    }
}
