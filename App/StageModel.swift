import Foundation
import Observation

/// What the stage's cards show that the store doesn't keep: a running agent's last four calls and
/// its task while its card is followed, and what each finished agent of a run returned, whole,
/// which the snapshot cuts at about 400 characters. Kept apart from Conversation, and a trail
/// apart for each agent, so a step draws its own card and never lays out the lead's transcript.
@MainActor
@Observable
final class StageModel {
    struct Step: Hashable {
        let tool: String
        let input: JSON
    }

    /// One agent's card: its steps, the latest last, and its task, the script's words.
    @Observable
    final class Trail {
        fileprivate(set) var steps: [Step] = []
        fileprivate(set) var task: String?
    }

    @ObservationIgnored private var trails: [UUID: Trail] = [:]
    /// What each agent returned, by Claude Code's id for it.
    private(set) var results: [String: String] = [:]
    /// The agents' threads whose trails the engine reads.
    @ObservationIgnored var followed: Set<UUID> = []

    func trail(for agent: UUID) -> Trail {
        if let trail = trails[agent] { return trail }
        let trail = Trail()
        trails[agent] = trail
        return trail
    }

    /// An agent's `agent.steps`: its last calls, with its task the first time. One saying `ended`
    /// is the follow's last, its agent over.
    func take(_ body: JSON, for agent: UUID) {
        let trail = trail(for: agent)
        let steps = (body["steps"]?.array ?? []).compactMap { step in
            step["tool"]?.string.map { Step(tool: $0, input: step["input"] ?? .null) }
        }
        if trail.steps != steps { trail.steps = steps }
        if let task = body["task"]?.string { trail.task = task }
        if body["ended"]?.bool == true { followed.remove(agent) }
    }

    /// An agent's `agent.result`, sent once as it ends.
    func took(_ body: JSON) {
        guard let agent = body["agentId"]?.string, let result = body["result"]?.string else { return }
        results[agent] = result
    }

    /// Its engine went, and every follow with it.
    func reset() {
        followed = []
    }
}
