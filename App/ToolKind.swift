import Foundation

/// What a tool call does, whichever agent made it (K-175). An agent says so on `tool.use` and
/// `ask`; Claude Code's calls, live or stored, never do, and their names say it instead.
enum ToolKind: String, Hashable {
    case read, edit, notebook, write, delete, move, run, search, list, fetch, web, think, agent, plan, question, planning, skill, workflow, mcp, other

    /// Claude Code's tools by name.
    init(claude name: String) {
        switch name {
        case "Read": self = .read
        case "Edit", "MultiEdit": self = .edit
        case "NotebookEdit": self = .notebook
        case "Write": self = .write
        case "Bash": self = .run
        case "Grep", "Glob": self = .search
        case "LS": self = .list
        case "WebFetch": self = .fetch
        case "WebSearch": self = .web
        case "Task", "Agent": self = .agent
        case "TodoWrite": self = .plan
        case "AskUserQuestion": self = .question
        case "ExitPlanMode": self = .planning
        case "Skill": self = .skill
        case "Workflow": self = .workflow
        default: self = name.hasPrefix("mcp__") ? .mcp : .other
        }
    }

    /// The kind an event declares, or else the one Claude Code's name for the tool gives.
    init(_ declared: JSON?, tool name: String) {
        self = declared?.string.flatMap(ToolKind.init(rawValue:)) ?? ToolKind(claude: name)
    }
}
