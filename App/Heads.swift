import Foundation
import Observation
import SwiftUI

/// One thing at work in a thread besides its main loop, as the engine last told of it: a
/// subagent, a command Claude left running, a workflow, or another task the CLI runs. Each is an
/// object of its own, so a step or a count that changes redraws its row and nothing else.
@MainActor
@Observable
final class Head: Identifiable {
    enum Kind: String {
        case agent, command, workflow, other
    }

    struct Step: Hashable {
        let tool: String
        let detail: String?
    }

    let id: String
    let kind: Kind
    /// The call that started it, which a workflow's card and its events name too.
    let toolUseId: String?
    let startedAt: Date
    fileprivate(set) var label: String
    /// The subagent's type, for an agent.
    fileprivate(set) var type: String?
    fileprivate(set) var background: Bool
    fileprivate(set) var depth: Int
    fileprivate(set) var tokens: Int?
    fileprivate(set) var tools: Int?
    fileprivate(set) var step: Step?
    /// A command's last line of output.
    fileprivate(set) var line: String?
    /// A workflow's run, from its own events.
    fileprivate(set) var run: WorkflowRun?
    /// The rays it holds, in the order it took them.
    fileprivate(set) var rays: [Int] = []
    /// Gone from the engine's list: its ray has gone out, and its row goes next.
    fileprivate(set) var ending = false

    fileprivate init(_ body: JSON) {
        id = body["id"]?.string ?? ""
        kind = Kind(rawValue: body["kind"]?.string ?? "") ?? .other
        toolUseId = body["toolUseId"]?.string
        startedAt = body["startedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        label = ""
        background = false
        depth = 1
        take(body)
    }

    /// Whether it lights rays: an agent its own, and a workflow one for each of its agents at work.
    var lights: Bool {
        kind == .agent || kind == .workflow
    }

    /// What the engine says now. Only what changed is set, so a row doesn't redraw for the rest.
    fileprivate func take(_ body: JSON) {
        let label = body["label"]?.string ?? ""
        if label != self.label { self.label = label }
        let type = body["type"]?.string
        if type != self.type { self.type = type }
        let background = body["background"]?.bool ?? false
        if background != self.background { self.background = background }
        let depth = body["depth"]?.int ?? 1
        if depth != self.depth { self.depth = depth }
        // Detail comes only while the surface watches; without it, what was last said stands.
        if case .object(let fields) = body, fields.keys.contains("step") {
            let step = body["step"]?["tool"]?.string.map { Step(tool: $0, detail: body["step"]?["detail"]?.string) }
            if step != self.step { self.step = step }
            let line = body["line"]?.string
            if line != self.line { self.line = line }
        }
    }

    fileprivate func count(tokens: Int?, tools: Int?) {
        if tokens != self.tokens { self.tokens = tokens }
        if tools != self.tools { self.tools = tools }
    }
}

/// A thread's heads, kept apart from its transcript's items so that nothing here re-runs the
/// transcript. The six rays are given out here: an agent keeps the ray it was given for as long
/// as it runs, a workflow holds one for each of its agents at work, a head that comes when all six
/// are out gets one once one is free, and commands never hold one.
@MainActor
@Observable
final class Heads {
    /// As they came, which is the order the surface lists them in.
    private(set) var list: [Head] = []
    /// The rays lit on the thread's mark.
    private(set) var lit: Set<Int> = []
    /// Workflows' runs by task, which can come before their head does.
    @ObservationIgnored private var runs: [String: WorkflowRun] = [:]
    /// Tokens and tool calls change on screen at most once a second: the counts held back, and
    /// when they last changed.
    @ObservationIgnored private var heldCounts: [String: (tokens: Int?, tools: Int?)] = [:]
    @ObservationIgnored private var countedAt = Date.distantPast
    @ObservationIgnored private var counting: Task<Void, Never>?

    /// How long a head that ended keeps its row, while its ray goes out.
    static let fading: Duration = .milliseconds(450)

    var isEmpty: Bool {
        !list.contains { !$0.ending }
    }

    /// Agents and workflows still at work, which a main loop whose turn is over waits on.
    var agents: Int {
        list.count { !$0.ending && $0.lights }
    }

    /// The engine's whole list. A head it no longer lists ends: its ray goes out now, and its row
    /// a moment later.
    func update(_ body: JSON) {
        let listed = body["heads"]?.array ?? []
        let ids = Set(listed.compactMap { $0["id"]?.string })
        var arrived: [Head] = []
        for entry in listed {
            guard let id = entry["id"]?.string else { continue }
            if let head = list.first(where: { $0.id == id }) {
                head.take(entry)
                if head.ending { head.ending = false }
                hold(head, entry)
            } else {
                let head = Head(entry)
                head.run = runs[id]
                head.count(tokens: entry["tokens"]?.int, tools: entry["tools"]?.int)
                arrived.append(head)
            }
        }
        var ended = false
        for head in list where !head.ending && !ids.contains(head.id) {
            head.ending = true
            ended = true
            runs[head.id] = nil
        }
        if !arrived.isEmpty { withAnimation(Motion.move) { list += arrived } }
        assignRays()
        if ended { removeEnded() }
    }

    /// A workflow's latest run, whose agents at work light its rays.
    func workflow(_ body: JSON) {
        guard let taskId = body["taskId"]?.string else { return }
        let run = WorkflowRun(body)
        runs[taskId] = run.state == .running ? run : nil
        guard let head = list.first(where: { $0.id == taskId }), head.run != run else { return }
        head.run = run
        assignRays()
    }

    /// The engine has gone, and whatever it ran with it.
    func clear() {
        runs = [:]
        heldCounts = [:]
        counting?.cancel()
        counting = nil
        guard !list.isEmpty else { return }
        for head in list { head.ending = true }
        assignRays()
        removeEnded()
    }

    /// A head's tokens and tool calls, now or, within a second of the last change, when it's up.
    private func hold(_ head: Head, _ entry: JSON) {
        let counts = (tokens: entry["tokens"]?.int ?? head.tokens, tools: entry["tools"]?.int ?? head.tools)
        guard counts.tokens != head.tokens || counts.tools != head.tools else { return }
        heldCounts[head.id] = counts
        let wait = 1 - Date.now.timeIntervalSince(countedAt)
        guard wait > 0 else {
            countNow()
            return
        }
        guard counting == nil else { return }
        counting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.countNow()
        }
    }

    private func countNow() {
        counting = nil
        countedAt = .now
        for head in list {
            guard let counts = heldCounts[head.id] else { continue }
            withAnimation(Motion.fade) { head.count(tokens: counts.tokens, tools: counts.tools) }
        }
        heldCounts = [:]
    }

    private func removeEnded() {
        let ended = Set(list.filter(\.ending).map(\.id))
        Task { [weak self] in
            try? await Task.sleep(for: Self.fading)
            guard let self else { return }
            withAnimation(Motion.move) { list.removeAll { $0.ending && ended.contains($0.id) } }
            assignRays()
        }
    }

    /// Hands out the rays: what each head wants, from the lowest free ray up, keeping what it has.
    /// A head on its way out keeps its ray until its row has gone, so no other takes it meanwhile,
    /// but it isn't lit.
    private func assignRays() {
        var taken = Set(list.flatMap(\.rays))
        for head in list {
            let wanted = head.ending ? head.rays.count : wants(head)
            if head.rays.count > wanted {
                let freed = head.rays.suffix(head.rays.count - wanted)
                taken.subtract(freed)
                head.rays.removeLast(freed.count)
            }
            while head.rays.count < wanted, let free = (0..<RaysMark.rays).first(where: { !taken.contains($0) }) {
                head.rays.append(free)
                taken.insert(free)
            }
        }
        let lit = Set(list.filter { !$0.ending }.flatMap(\.rays))
        if lit != self.lit { self.lit = lit }
    }

    private func wants(_ head: Head) -> Int {
        switch head.kind {
        case .agent: 1
        case .workflow: head.run?.count(.running) ?? 0
        case .command, .other: 0
        }
    }
}

extension Conversation {
    /// Whether the thread works: a turn running, or anything it left running.
    var working: Bool {
        running || !heads.isEmpty
    }

    /// The plan's item in progress while a turn runs, as Claude words it then: "Running the tests".
    var planStep: String? {
        running ? plan?.current?.activeForm : nil
    }

    /// What the main loop is on, read off the end of the transcript: thinking, writing, a call still
    /// out and what on, waiting on you, or, with its turn over, waiting on its agents.
    func mainStep(cwd: String) -> Head.Step {
        if waitingAsk != nil { return Head.Step(tool: "Waiting on you", detail: nil) }
        guard running else {
            let agents = heads.agents
            return Head.Step(tool: agents == 0 ? "Idle" : "Waiting on \(agents) \(agents == 1 ? "agent" : "agents")", detail: nil)
        }
        switch items.last {
        case .text:
            return Head.Step(tool: "Writing", detail: nil)
        case .tool(_, let call) where call.result == nil:
            return Head.Step(tool: call.name, detail: ToolSummary.target(for: call, cwd: cwd))
        default:
            return Head.Step(tool: "Thinking", detail: nil)
        }
    }
}
