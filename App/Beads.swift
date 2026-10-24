import SwiftUI

/// A bead for each agent in a phase, wrapping: faint while queued, lit while it runs, settled once
/// done, and red if it failed.
struct Beads: View {
    let agents: [WorkflowRun.Agent]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 7, maximum: 7), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                Bead(state: agent.state)
            }
        }
        .frame(minHeight: 7)
    }
}

struct Bead: View {
    let state: WorkflowRun.Agent.State

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 7, height: 7)
            .background {
                if state == .running {
                    Circle().fill(Color.white.opacity(0.16)).frame(width: 13, height: 13)
                }
            }
    }

    private var fill: Color {
        switch state {
        case .queued: Color.white.opacity(0.18)
        case .running: Ink.primary
        case .done: Color.white.opacity(0.5)
        case .failed: Ink.deleted
        }
    }
}

/// One agent under its workflow's row on ⌘I: its bead and label, and the tool it's on, what it
/// used, or why it failed.
struct AgentLine: View {
    let agent: WorkflowRun.Agent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Bead(state: agent.state)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(agent.label)
                .font(Type.mono)
                .foregroundStyle(agent.state == .queued ? Ink.faint : Ink.primary)
                .lineLimit(1)
            Text(detail)
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var detail: String {
        switch agent.state {
        case .queued:
            return "Queued"
        case .running:
            return [agent.lastTool, agent.lastDetail].compactMap { $0 }.joined(separator: " · ")
        case .done:
            let tokens = agent.tokens.formatted(.number.notation(.compactName))
            return "\(agent.tools) \(agent.tools == 1 ? "tool" : "tools") · \(tokens) tokens"
        case .failed:
            return agent.error ?? "Failed"
        }
    }
}
