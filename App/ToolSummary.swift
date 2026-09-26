import Foundation

/// The quiet one-line description of a tool call: "Read App/Engine.swift", "Bash: swift build".
enum ToolSummary {
    static func line(for call: ToolCall, cwd: String) -> String {
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
    /// read or edited.
    static func run(_ calls: [ToolCall]) -> String {
        var kinds: [RunKind] = []
        var seen: [RunKind: Set<String>] = [:]
        for call in calls {
            let kind = RunKind(call.kind)
            if seen[kind] == nil { kinds.append(kind) }
            seen[kind, default: []].insert(path(for: call) ?? call.toolUseId)
        }
        let line = kinds.map { $0.phrase(seen[$0]?.count ?? 0) }.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    private enum RunKind {
        case read, edit, command, search, list, fetch, web, agent, plan, skill, question, planning, other

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

    static func relative(_ path: String, to cwd: String) -> String {
        let path = (path as NSString).standardizingPath
        let cwd = (cwd as NSString).standardizingPath
        let root = cwd.hasSuffix("/") ? cwd : cwd + "/"
        if path.hasPrefix(root) { return String(path.dropFirst(root.count)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}
