import Foundation
import Observation
import SwiftUI

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
        /// The place of `steps`' first in all the agent has called here, so a step keeps who it is
        /// as newer ones push it down the card.
        fileprivate(set) var first = 0
        /// Its third call has landed, which folds the well its task opened in.
        fileprivate(set) var settled = false
    }

    @ObservationIgnored private var trails: [UUID: Trail] = [:]
    /// The run each thread's stage is up for, by the thread.
    private(set) var shown: [UUID: String] = [:]
    /// The runs a stage was called up for, or left folded, as each first came on the glass.
    @ObservationIgnored private var cued: Set<String> = []
    /// Each stage on the glass's running agents, whose trails the engine reads.
    @ObservationIgnored var watched: [UUID: Set<UUID>] = [:]
    /// What each agent returned, by Claude Code's id for it.
    private(set) var results: [String: String] = [:]
    /// The agents' threads whose trails the engine reads.
    @ObservationIgnored var followed: Set<UUID> = []
    /// What each task took from each result, found once for each pair.
    @ObservationIgnored private var handed: [String: Handoff.Runs] = [:]
    /// The agents a spark has travelled to, so it does once.
    @ObservationIgnored var sparked: Set<String> = []
    /// Each stage whose run has ended and folds in a moment, by its thread.
    @ObservationIgnored private var endings: [UUID: UUID] = [:]
    /// How long a stage stays as its run ended before it folds.
    static let lingering: Duration = .milliseconds(1200)

    /// An agent a stage is stepped into: Claude Code's id for it and its thread.
    struct Stepped: Equatable {
        let agent: String
        let thread: UUID
    }

    /// The agent each thread's stage is stepped into, by the thread.
    private(set) var stepped: [UUID: Stepped] = [:]
    /// Told of the agent's thread a stage stepped out of, or nil, each time one steps in or out.
    @ObservationIgnored var steppedMoved: ((UUID?) -> Void)?

    /// What `shown` holds for a stage called up by the line of what its thread set going besides a
    /// workflow, rather than by a run's line.
    static let laneKey = "lane"
    /// Each thread's column: what it set going that still works, and what of it ended since the
    /// first of those began, in the order they started.
    private(set) var lanes: [UUID: [LaneCard]] = [:]
    /// The cards that ended since the column's work began, by their id, kept until it's all over.
    @ObservationIgnored private var departed: [UUID: [String: LaneCard]] = [:]
    /// Each column whose work is over and folds in a moment, by its thread.
    @ObservationIgnored private var laneEndings: [UUID: UUID] = [:]
    /// The last reply of each task's or opened thread's that ended, read once for its card.
    private(set) var replies: [UUID: String] = [:]

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
        if trail.steps != steps {
            // The engine sends the last four each time: those it sent before are the new ones' start.
            let kept = (0...min(trail.steps.count, steps.count)).last { trail.steps.suffix($0).elementsEqual(steps.prefix($0)) } ?? 0
            trail.first += trail.steps.count - kept
            trail.steps = steps
            if !trail.settled, trail.first + steps.count >= 3 { trail.settled = true }
        }
        if let task = body["task"]?.string { trail.task = task }
        if body["ended"]?.bool == true { followed.remove(agent) }
    }

    /// An agent's `agent.result`, sent once as it ends.
    func took(_ body: JSON) {
        guard let agent = body["agentId"]?.string, let result = body["result"]?.string else { return }
        results[agent] = result
    }

    /// The runs of words a recipient's task shares with a source's result.
    func runs(_ recipient: String, task: String, source: String, result: String) -> Handoff.Runs {
        let key = "\(recipient) \(source) \(task.utf8.count) \(result.utf8.count)"
        if let runs = handed[key] { return runs }
        let runs = Handoff.runs(task: task, result: result)
        handed[key] = runs
        return runs
    }

    /// What a thread set going that's at work now, as its column's cards: one gone since last time
    /// stays, ended, until nothing of the column works. The column's first card coming grows the
    /// stage while the transcript is followed to its end; its last ending folds it a moment later.
    func lane(_ live: [LaneCard], in thread: UUID, grow: Bool) {
        let before = lanes[thread] ?? []
        let ids = Set(live.map(\.id))
        var gone = departed[thread] ?? [:]
        for card in before where !ids.contains(card.id) && gone[card.id] == nil {
            var ended = card
            if ended.working { ended.state = .done }
            gone[card.id] = ended
        }
        for id in ids { gone[id] = nil }
        let working = live.contains(where: \.working)
        let worked = before.contains(where: \.working)
        departed[thread] = gone.isEmpty ? nil : gone
        let cards = (live + gone.values).sorted { ($0.startedAt, $0.id) < ($1.startedAt, $1.id) }
        if cards != before { lanes[thread] = cards.isEmpty ? nil : cards }
        if working {
            laneEndings[thread] = nil
            if !worked, grow, shown[thread] == nil { withAnimation(Motion.move) { shown[thread] = Self.laneKey } }
        } else if worked {
            laneEnded(in: thread)
        }
    }

    /// The column's work is over: it stays as it ended for a moment, then folds and goes, unless the
    /// stage is stepped into one of its cards, which keeps it until the stage folds.
    private func laneEnded(in thread: UUID) {
        let ending = UUID()
        laneEndings[thread] = ending
        Task { [weak self] in
            try? await Task.sleep(for: Self.lingering)
            guard let self, laneEndings[thread] == ending else { return }
            laneEndings[thread] = nil
            guard stepped[thread] == nil else { return }
            if shown[thread] == Self.laneKey { _ = fold(thread) }
            clearLane(thread)
        }
    }

    /// Lets the cards of a column whose work is over go.
    private func clearLane(_ thread: UUID) {
        guard lanes[thread]?.contains(where: \.working) != true else { return }
        departed[thread] = nil
        lanes[thread] = nil
    }

    /// A task's or an opened thread's last reply, for its card once it has ended.
    func took(reply: String?, of thread: UUID) {
        replies[thread] = reply ?? ""
    }

    /// A run on the glass for the first time: its stage grows, unless the transcript under it is
    /// being read further up, when its line stays folded until clicked.
    func cue(_ run: String, in thread: UUID, grow: Bool) {
        guard cued.insert(run).inserted, grow else { return }
        withAnimation(Motion.move) { shown[thread] = run }
    }

    /// A run whose stage is up has ended: the stage stays as the run ended for a moment, then folds
    /// into its line, unless it's stepped into an agent, whose transcript is being read.
    func ended(_ run: String, in thread: UUID) {
        guard shown[thread] == run else { return }
        let folding = UUID()
        endings[thread] = folding
        Task { [weak self] in
            try? await Task.sleep(for: Self.lingering)
            guard let self, endings[thread] == folding else { return }
            endings[thread] = nil
            guard shown[thread] == run, stepped[thread] == nil else { return }
            // What else the thread set going keeps the stage up while it works.
            if lanes[thread]?.contains(where: \.working) == true {
                withAnimation(Motion.move) { shown[thread] = Self.laneKey }
            } else {
                _ = fold(thread)
            }
        }
    }

    func toggle(_ run: String, in thread: UUID) {
        endings[thread] = nil
        let left = stepped[thread]
        withAnimation(Motion.move) {
            shown[thread] = shown[thread] == run ? nil : run
            stepped[thread] = nil
        }
        if let left { steppedMoved?(left.thread) }
        if shown[thread] == nil { clearLane(thread) }
    }

    /// Calls a thread's stage up for a run, or with `laneKey` for its column, as ⌘⇧I's line does.
    func show(_ run: String, in thread: UUID) {
        endings[thread] = nil
        guard shown[thread] != run else { return }
        let left = stepped[thread]
        withAnimation(Motion.move) {
            shown[thread] = run
            stepped[thread] = nil
        }
        if let left { steppedMoved?(left.thread) }
    }

    /// Folds a thread's stage, saying whether one was up.
    func fold(_ thread: UUID) -> Bool {
        endings[thread] = nil
        guard shown[thread] != nil else { return false }
        let left = stepped[thread]
        withAnimation(Motion.move) {
            shown[thread] = nil
            stepped[thread] = nil
        }
        if let left { steppedMoved?(left.thread) }
        clearLane(thread)
        return true
    }

    /// Steps a thread's stage into an agent, from the columns or across from another, or with nil
    /// back out to the columns. The card grows into the agent's transcript with the spring; one
    /// agent's gives way to another's with a fade.
    func step(into agent: Stepped?, in thread: UUID) {
        let left = stepped[thread]
        guard left != agent else { return }
        withAnimation(left == nil || agent == nil ? Motion.move : Motion.fade) { stepped[thread] = agent }
        steppedMoved?(left?.thread)
        // Back out of a column whose work ended while it was stepped into: it folds now.
        if agent == nil, let lane = lanes[thread], !lane.contains(where: \.working) { laneEnded(in: thread) }
    }

    /// Its engine went, and every follow with it.
    func reset() {
        followed = []
    }
}
