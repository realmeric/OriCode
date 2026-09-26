import Foundation

/// The quiet one-line description of a tool call: "Read App/Engine.swift", "Bash: swift build".
enum ToolSummary {
    static func line(for call: ToolCall, cwd: String) -> String {
        let input = call.input
        func path(_ key: String = "file_path") -> String {
            relative(input[key]?.string ?? input["path"]?.string ?? "", to: cwd)
        }
        switch call.name {
        case "Read": return "Read \(path())"
        case "Edit", "MultiEdit": return "Edit \(path())"
        case "Write": return "Write \(path())"
        case "NotebookEdit": return "Edit \(path("notebook_path"))"
        case "Bash": return "Bash: \(firstLine(input["command"]?.string ?? ""))"
        case "Grep": return "Grep \(input["pattern"]?.string ?? "")"
        case "Glob": return "Glob \(input["pattern"]?.string ?? "")"
        case "WebFetch": return "Fetch \(input["url"]?.string ?? "")"
        case "WebSearch": return "Search \(input["query"]?.string ?? "")"
        case "Task", "Agent": return "Agent: \(input["description"]?.string ?? "")"
        case "TodoWrite": return "Update the plan"
        case "AskUserQuestion": return "Ask you"
        case "ExitPlanMode": return "Finish planning"
        case "Skill": return "Skill: \(input["skill"]?.string ?? input["command"]?.string ?? "")"
        default: return name(call.name)
        }
    }

    /// A tool's name as the thread shows it: an MCP server's tool as "server › tool".
    static func name(_ tool: String) -> String {
        tool.hasPrefix("mcp__") ? tool.split(separator: "__").dropFirst().joined(separator: " › ") : tool
    }

    /// What a call is on, without the tool: the file, the command's first line, the pattern, the
    /// page or the question, in the shape the engine gives an agent's step.
    static func target(for call: ToolCall, cwd: String) -> String? {
        let input = call.input
        if let path = input["file_path"]?.string ?? input["notebook_path"]?.string { return relative(path, to: cwd) }
        if let command = input["command"]?.string { return firstLine(command) }
        return ["pattern", "url", "query", "description", "skill", "path"].lazy.compactMap { input[$0]?.string }.first { !$0.isEmpty }
    }

    /// What a run of calls did, in Claude Code's words, each kind where it first came: "Read 2
    /// files, ran 3 commands, searched for 1 pattern". A file counts once however often it's
    /// read or edited.
    static func run(_ calls: [ToolCall]) -> String {
        var kinds: [RunKind] = []
        var seen: [RunKind: Set<String>] = [:]
        for call in calls {
            let kind = RunKind(call.name)
            if seen[kind] == nil { kinds.append(kind) }
            seen[kind, default: []].insert(path(for: call) ?? call.toolUseId)
        }
        let line = kinds.map { $0.phrase(seen[$0]?.count ?? 0) }.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    private enum RunKind {
        case read, edit, command, search, list, fetch, web, agent, plan, skill, question, planning, other

        init(_ name: String) {
            switch name {
            case "Read": self = .read
            case "Edit", "MultiEdit", "Write", "NotebookEdit": self = .edit
            case "Bash": self = .command
            case "Grep", "Glob": self = .search
            case "LS": self = .list
            case "WebFetch": self = .fetch
            case "WebSearch": self = .web
            case "Task", "Agent": self = .agent
            case "TodoWrite": self = .plan
            case "Skill": self = .skill
            case "AskUserQuestion": self = .question
            case "ExitPlanMode": self = .planning
            default: self = .other
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

    /// The file a Read, Edit, MultiEdit, Write or NotebookEdit call touched, as given to the tool.
    static func path(for call: ToolCall) -> String? {
        switch call.name {
        case "Read", "Edit", "MultiEdit", "Write": call.input["file_path"]?.string
        case "NotebookEdit": call.input["notebook_path"]?.string
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
