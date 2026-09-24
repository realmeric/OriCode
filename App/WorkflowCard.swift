import SwiftUI

/// A workflow the thread started, in place of its call's line: its name beside OriCode's mark,
/// whose rays light for the agents at work and turn while it runs, how far it has got, and its
/// phases in order, each with a bead per agent. A click opens the agents themselves.
struct WorkflowCard: View {
    let call: ToolCall
    @State private var open = false

    var body: some View {
        let run = call.workflow
        let script = call.input["script"]?.string ?? ""
        let groups = WorkflowRun.groups(run?.agents ?? [], planned: WorkflowRun.plannedPhases(in: script), reported: run?.phases ?? [])
        let running = run?.state == .running ? run?.count(.running) ?? 0 : 0
        let name = run?.name ?? call.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(Motion.fade) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    RaysMark(lit: running, turning: running > 0)
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(status(run, groups: groups))
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if !groups.isEmpty {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Ink.faint)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(groups.isEmpty)
            if !groups.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
                    ForEach(groups, id: \.phase) { group in
                        GridRow {
                            Text(group.phase.isEmpty ? "Agents" : group.phase)
                                .font(Type.secondary)
                                .foregroundStyle(group.agents.isEmpty ? Ink.faint : Ink.secondary)
                                .lineLimit(1)
                            Beads(agents: group.agents)
                        }
                        if open {
                            ForEach(Array(group.agents.enumerated()), id: \.offset) { _, agent in
                                GridRow {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                    AgentLine(agent: agent)
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
        .animation(Motion.fade, value: run)
    }

    /// How far it has got: the phase at work and the agents done, or how it ended.
    private func status(_ run: WorkflowRun?, groups: [(phase: String, agents: [WorkflowRun.Agent])]) -> String {
        guard let run else { return "Starting…" }
        let total = run.agents.count
        let failed = run.count(.failed)
        let tally = total == 0 ? nil : "\(run.count(.done)) of \(total) agents done" + (failed > 0 ? ", \(failed) failed" : "")
        switch run.state {
        case .running:
            let phase = groups.last { $0.agents.contains { $0.state == .running } }?.phase
            return [phase.flatMap { $0.isEmpty ? nil : $0 }, tally ?? "Running"].compactMap { $0 }.joined(separator: " · ")
        case .completed:
            return total == 0 ? "Done" : "Done · \(total) \(total == 1 ? "agent" : "agents")" + (failed > 0 ? ", \(failed) failed" : "")
        case .failed:
            return ["Failed", tally].compactMap { $0 }.joined(separator: " · ")
        case .stopped:
            return ["Stopped", tally].compactMap { $0 }.joined(separator: " · ")
        }
    }
}

/// A bead for each agent in a phase, wrapping: faint while queued, lit while it runs, settled once
/// done, and red if it failed.
private struct Beads: View {
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

private struct Bead: View {
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

/// One agent in the opened card: its bead and label, and the tool it's on, what it used, or why
/// it failed.
private struct AgentLine: View {
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
