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
        /// When its task came, which a hop is drawn from.
        fileprivate var told: ContinuousClock.Instant?
        /// The place of `steps`' first in all the agent has called here, so a step keeps who it is
        /// as newer ones push it down the card.
        fileprivate(set) var first = 0
        /// Its third call has landed, which folds the well its task opened in.
        fileprivate(set) var settled = false
        /// The well's words have faded, and its room closes.
        fileprivate(set) var folded = false
        /// The well has gone, so the hop is no longer drawn and its gutter closes.
        fileprivate(set) var closed = false
        /// Its transcript has the reply that ended its turn, which says it's done before the run's
        /// next snapshot does, and that reply's text.
        fileprivate(set) var done = false
        fileprivate(set) var result: String?
    }

    /// A well folds in two steps a fade long each: its words fade, then its room closes. Only then
    /// does the hop's gutter close.
    static let folding: Duration = .milliseconds(180)
    /// The least a hop is drawn for, from its task coming: its wires come about a spring and a
    /// third of a second after that, and stay a little over two seconds.
    static let handing: Duration = .milliseconds(3000)

    @ObservationIgnored private var trails: [UUID: Trail] = [:]
    /// The run each thread's stage is up for, by the thread.
    private(set) var shown: [UUID: String] = [:]
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
    /// Each stage whose run ended while it was stepped into an agent, by its thread: it folds once
    /// it steps back out.
    @ObservationIgnored private var overWhileStepped: [UUID: String] = [:]
    /// How long a stage stays as its run ended before it folds.
    static let lingering: Duration = .milliseconds(1200)

    /// An agent a stage is stepped into: Claude Code's id for it and its thread.
    struct Stepped: Equatable {
        let agent: String
        let thread: UUID
    }

    /// The agent each thread's stage is stepped into, by the thread.
    private(set) var stepped: [UUID: Stepped] = [:]
    /// The stages stepping back out, whose agent's transcript fades before its surface folds into
    /// its card, so it's never drawn over the cards coming back or the lead's transcript.
    private(set) var leaving: Set<UUID> = []
    /// How long the agent's transcript takes to fade before its surface folds.
    static let unstepping: Duration = .milliseconds(100)
    /// Told of the agent's thread a stage stepped out of, or nil, each time one steps in or out.
    @ObservationIgnored var steppedMoved: ((UUID?) -> Void)?

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
            // A trail read for the first time with its three calls already made never opened a well.
            let fresh = trail.steps.isEmpty && trail.first == 0 && trail.task == nil
            // The engine sends the last four each time: those it sent before are the new ones' start.
            let kept = (0...min(trail.steps.count, steps.count)).last { trail.steps.suffix($0).elementsEqual(steps.prefix($0)) } ?? 0
            trail.first += trail.steps.count - kept
            trail.steps = steps
            if !trail.settled, trail.first + steps.count >= 3 {
                if fresh {
                    trail.settled = true
                    trail.folded = true
                    trail.closed = true
                } else {
                    fold(trail)
                }
            }
        }
        if let task = body["task"]?.string {
            trail.task = task
            trail.told = trail.told ?? .now
        }
        if body["done"]?.bool == true {
            trail.result = body["result"]?.string
            trail.done = true
        }
        if body["ended"]?.bool == true { followed.remove(agent) }
    }

    /// Folds a trail's well: its words fade, then its room closes with the card closing up around
    /// it, so the trail under it moves up only into glass; then the hop goes.
    private func fold(_ trail: Trail) {
        Task {
            // After the call that settled it has been laid out on its own, so its card grows
            // under no animation of the fold's; and not before the hop has been up long enough
            // to be read, however soon an agent making its calls at once gets to its third.
            let shown = trail.told.map { ContinuousClock.now - $0 } ?? .zero
            try? await Task.sleep(for: max(.milliseconds(50), Self.handing - shown))
            withAnimation(Motion.fade) { trail.settled = true }
            try? await Task.sleep(for: Self.folding)
            withAnimation(Motion.fade) { trail.folded = true }
            try? await Task.sleep(for: Self.folding)
            withAnimation(Motion.move) { trail.closed = true }
        }
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

    /// A run whose stage is up has ended: the stage stays as the run ended for a moment, then folds
    /// into its line, unless it's stepped into an agent, whose transcript is being read: then it
    /// does once it steps back out.
    func ended(_ run: String, in thread: UUID) {
        guard shown[thread] == run else { return }
        let folding = UUID()
        endings[thread] = folding
        Task { [weak self] in
            try? await Task.sleep(for: Self.lingering)
            guard let self, endings[thread] == folding else { return }
            endings[thread] = nil
            guard shown[thread] == run else { return }
            guard stepped[thread] == nil else {
                overWhileStepped[thread] = run
                return
            }
            _ = fold(thread)
        }
    }

    func toggle(_ run: String, in thread: UUID) {
        endings[thread] = nil
        overWhileStepped[thread] = nil
        let left = stepped[thread]
        withAnimation(Motion.move) {
            shown[thread] = shown[thread] == run ? nil : run
            stepped[thread] = nil
        }
        if let left { steppedMoved?(left.thread) }
    }

    /// Calls a thread's stage up for a run, as ⌘⇧I's line does.
    func show(_ run: String, in thread: UUID) {
        endings[thread] = nil
        overWhileStepped[thread] = nil
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
        overWhileStepped[thread] = nil
        guard shown[thread] != nil else { return false }
        let left = stepped[thread]
        withAnimation(Motion.move) {
            shown[thread] = nil
            stepped[thread] = nil
        }
        if let left { steppedMoved?(left.thread) }
        return true
    }

    /// Steps a thread's stage into an agent, from the phases or across from another, or with nil
    /// back out to the phases. The card grows into the agent's transcript with the spring; one
    /// agent's gives way to another's with a fade.
    func step(into agent: Stepped?, in thread: UUID) {
        let left = stepped[thread]
        if agent != nil, leaving.contains(thread) { withAnimation(.easeOut(duration: 0.1)) { _ = leaving.remove(thread) } }
        guard left != agent else { return }
        if agent == nil {
            guard !leaving.contains(thread) else { return }
            withAnimation(.easeOut(duration: 0.1)) { _ = leaving.insert(thread) }
            Task { [weak self] in
                try? await Task.sleep(for: Self.unstepping)
                guard let self, leaving.contains(thread), stepped[thread] == left else { return }
                moveStep(nil, from: left, in: thread)
            }
            return
        }
        moveStep(agent, from: left, in: thread)
    }

    private func moveStep(_ agent: Stepped?, from left: Stepped?, in thread: UUID) {
        withAnimation(left == nil || agent == nil ? Motion.move : Motion.fade) { stepped[thread] = agent }
        steppedMoved?(left?.thread)
        // Back out of a run whose work ended while it was stepped into: it folds now, after the
        // moment it would have stayed as it ended.
        if agent == nil, let run = overWhileStepped.removeValue(forKey: thread) { ended(run, in: thread) }
    }

    /// Its engine went, and every follow with it.
    func reset() {
        followed = []
    }
}
