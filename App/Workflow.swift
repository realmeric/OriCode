import Foundation

/// A workflow a thread started, as the engine last told of it: how far it has got, and its
/// phases and the agents in them from the CLI's latest snapshot.
struct WorkflowRun: Hashable {
    enum State: String {
        case running, completed, failed, stopped
    }

    struct Agent: Hashable {
        enum State: String {
            case queued, running, done, failed
        }

        let label: String
        let phase: String
        let state: State
        let tokens: Int
        let tools: Int
        let lastTool: String?
        let lastDetail: String?
        let error: String?
    }

    var state: State
    let name: String
    let phases: [String]
    let agents: [Agent]
    let summary: String?

    init(_ body: JSON) {
        state = State(rawValue: body["state"]?.string ?? "") ?? .running
        name = body["name"]?.string ?? "Workflow"
        phases = body["phases"]?.array?.compactMap(\.string) ?? []
        agents = (body["agents"]?.array ?? []).map { agent in
            Agent(
                label: agent["label"]?.string ?? "agent",
                phase: agent["phase"]?.string ?? "",
                state: Agent.State(rawValue: agent["state"]?.string ?? "") ?? .queued,
                tokens: agent["tokens"]?.int ?? 0,
                tools: agent["tools"]?.int ?? 0,
                lastTool: agent["lastTool"]?.string,
                lastDetail: agent["lastDetail"]?.string,
                error: agent["error"]?.string)
        }
        summary = body["summary"]?.string
    }

    func count(_ state: Agent.State) -> Int {
        agents.count { $0.state == state }
    }

    /// The phases in order with their agents: the ones the script names first, then any the CLI
    /// reported that it didn't, and last the agents in no phase.
    static func groups(_ agents: [Agent], planned: [String], reported: [String]) -> [(phase: String, agents: [Agent])] {
        var order: [String] = []
        for phase in planned + reported + agents.map(\.phase) where !phase.isEmpty && !order.contains(phase) {
            order.append(phase)
        }
        if agents.contains(where: { $0.phase.isEmpty }) { order.append("") }
        return order.map { phase in (phase, agents.filter { $0.phase == phase }) }
    }

    /// The phases a workflow's script names, from its meta, before the CLI has reported any:
    /// `phases: [{ title: '…' }, …]`. A saved workflow the call names has no script to read.
    static func plannedPhases(in script: String) -> [String] {
        guard let start = script.range(of: #"phases\s*:\s*\["#, options: .regularExpression) else { return [] }
        var depth = 1
        var end = start.upperBound
        while end < script.endIndex, depth > 0 {
            if script[end] == "[" { depth += 1 } else if script[end] == "]" { depth -= 1 }
            end = script.index(after: end)
        }
        return script[start.upperBound..<end].matches(of: /title\s*:\s*(?:'([^']*)'|"([^"]*)"|`([^`]*)`)/).compactMap { match in
            (match.output.1 ?? match.output.2 ?? match.output.3).map(String.init)
        }
    }

    /// The name in a script's meta, which the card shows until the CLI says it's running.
    static func plannedName(in script: String) -> String? {
        guard let match = script.firstMatch(of: /name\s*:\s*(?:'([^']*)'|"([^"]*)")/) else { return nil }
        return (match.output.1 ?? match.output.2).map(String.init)
    }
}
