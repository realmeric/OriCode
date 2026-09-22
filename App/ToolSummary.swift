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
        default:
            if call.name.hasPrefix("mcp__") {
                return call.name.split(separator: "__").dropFirst().joined(separator: " › ")
            }
            return call.name
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
