import AppKit
import SwiftUI

extension EnvironmentValues {
    /// The column's space for the run's mark and name, which pass between its line in the
    /// transcript and the head of its stage.
    @Entry var stageSpace: Namespace.ID?
}

/// A conversation column: its thread's transcript, and over its top the stage of the run the
/// thread has out, while that's up. The transcript is bounded under the stage's lowest card.
struct ConversationColumn: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let chat: Chat
    let active: Bool
    @Namespace private var space
    /// Where the stage's lowest card ends, nil while it's folded.
    @State private var foot: CGFloat?
    @State private var size = CGSize.zero

    var body: some View {
        let stepped = model.stage.stepped[chat.id] != nil
        // Stepped into an agent, the lead's transcript fades out where it is, as under ⌘I, and
        // comes back as it was once the stage steps out.
        TranscriptView(conversation: conversation, cwd: chat.cwd, active: active, stageFoot: foot)
            .opacity(stepped ? 0 : 1)
            .allowsHitTesting(!stepped)
            .animation(stepped ? .easeOut(duration: 0.1) : Motion.fade.delay(0.12), value: stepped)
            .overlay(alignment: .top) {
                StageSlot(conversation: conversation, chat: chat, active: active, size: size) { foot in
                    if foot != self.foot { self.foot = foot }
                }
            }
            .environment(\.stageSpace, space)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
    }
}

/// The stage's place in a column, which reads the thread's heads so that neither the transcript
/// nor the column does: nothing at all while the stage is folded or nothing runs.
private struct StageSlot: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let chat: Chat
    let active: Bool
    let size: CGSize
    let foot: (CGFloat?) -> Void
    /// The call that started the run, read once as the run comes, so the transcript's items
    /// changing never draws the stage again.
    @State private var call: ToolCall?

    var body: some View {
        let head = conversation.heads.liveWorkflow
        let up = head?.call.map { model.stage.shown[chat.id] == $0 } ?? false
        ZStack(alignment: .top) {
            if let head, up {
                RunStage(head: head, call: call, chat: chat, width: size.width, top: RunStage.top(active: active),
                         cap: size.height - RunStage.underneath, floor: size.height - RunStage.gap, foot: foot)
                    .transition(.opacity)
            }
        }
        // The transcript takes its room back as the fold begins, not once the cards have faded.
        .onChange(of: up) { if !up { foot(nil) } }
        .onChange(of: head?.call, initial: true) { old, now in
            call = now.flatMap(conversation.call)
            // Its run over, its stage leaves for good, and its line goes back to the card.
            if let old, now == nil, model.stage.shown[chat.id] == old { _ = model.stage.fold(chat.id) }
        }
    }
}

/// A workflow at work, on the column's glass above the lead's transcript: the run's mark and name,
/// then its phases left to right, each with its agents' cards, which say by their tint and their
/// mark how each agent is and show what it's doing now. It has no surface of its own.
struct RunStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let head: Head
    /// The Workflow call that started it, for the phases its script plans and its name.
    let call: ToolCall?
    let chat: Chat
    /// The column's width.
    let width: CGFloat
    /// Where the head row starts.
    let top: CGFloat
    /// The lowest the cards may reach.
    let cap: CGFloat
    /// Where an agent stepped into ends, the gap the lead's transcript keeps above the composer.
    let floor: CGFloat
    let foot: (CGFloat?) -> Void
    @State private var hovering = false
    /// The agents' threads, looked up as agents come rather than on every draw, which would have
    /// the stage drawn again for any change to any thread of the project.
    @State private var agentChats: [String: Chat] = [:]
    /// Whose trails this stage asks for: its own, so a stage made again for the same thread, which
    /// can appear before the old one has gone, never has its trails stopped by the old one going.
    @State private var watcher = UUID()

    /// The head row's top under the capsule, and under the title line of a column beside.
    static func top(active: Bool) -> CGFloat {
        active ? Island.top + TitleCapsule.height + 24 : TitleBar.height + BesideTitle.height + 24
    }
    /// Between the stage's lowest card and the lead's transcript, and between an agent stepped
    /// into and the composer.
    static let gap: CGFloat = 28
    /// What the stage leaves the lead under it: 180pt of transcript and the gap between.
    static let underneath: CGFloat = 180 + gap
    static let headHeight: CGFloat = 28
    /// From the head row's foot to the phases' labels.
    static let labelsGap: CGFloat = 14

    var body: some View {
        let run = head.run
        let script = call?.input["script"]?.string ?? ""
        let groups = WorkflowRun.groups(run?.agents ?? [], planned: WorkflowRun.plannedPhases(in: script), reported: run?.phases ?? [])
        let name = run?.name ?? call?.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        let inset: CGFloat = width < 900 ? 20 : 32
        let hops = Self.hops(groups, stage: model.stage, chats: agentChats)
        let layout = StageLayout.fitted(groups: groups, width: width - inset * 2, narrow: width < 560, wide: Set(hops.map(\.phase)),
                                        wells: hops.reduce(into: [:]) { $0[$1.recipient] = String($1.well.characters) })
        let room = cap - top - Self.headHeight - Self.labelsGap
        let steps = layout.steps(within: room)
        // Past the cap with no call left to drop, the cards scroll.
        let scrolls = layout.height(steps: 0) > room
        let agentIDs = (run?.agents ?? []).compactMap(\.id)
        let stepped = model.stage.stepped[chat.id]
        // Stepped into an agent, no card shows a trail.
        let watched = stepped != nil ? [] : Set(groups.flatMap(\.agents).filter { $0.state == .running }.compactMap { $0.id.flatMap { agentChats[$0] } }
            .filter { $0.agentTranscript != nil }.map(\.id))
        VStack(alignment: .leading, spacing: Self.labelsGap) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    RaysMark(slots: Set(head.rays), turning: !head.rays.isEmpty, colors: MarkPalette.colors(of: head))
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                .stageMatched(RunLine.matchID(head.call ?? head.id), in: space)
                Spacer(minLength: 8)
                // Stepped in, the marks keep the row's end and Stop comes in beside them.
                if stepped == nil || hovering {
                    Button("Stop workflow") { model.stopWorkflow(head.id, of: chat.id) }
                        .buttonStyle(.action(small: true))
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                        .help("Stops every agent of this workflow")
                        .transition(.opacity)
                }
                if let stepped {
                    StepMarks(phases: layout.phases, stepped: stepped.agent, head: head, agentChats: agentChats, lead: chat.id)
                }
            }
            .frame(height: Self.headHeight)
            if let stepped {
                AgentSurface(stepped: stepped)
                    .frame(height: max(floor - top - Self.headHeight - Self.labelsGap, 0))
                    .transition(.opacity)
            } else {
                phases(layout, steps: steps, scrolls: scrolls, hops: hops)
                    .frame(maxHeight: scrolls ? max(room, 0) : nil, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        // Stepped into an agent, the lead's transcript under it keeps the top it had.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .local).maxY } action: { if model.stage.stepped[chat.id] == nil { foot($0) } }
        .onChange(of: agentIDs, initial: true) { agentChats = model.agentChats(of: chat) }
        // The trails of the agents at work are read while the stage is up, and no longer.
        .onChange(of: watched, initial: true) { model.watchSteps(watched, for: watcher) }
        .onDisappear {
            foot(nil)
            model.watchSteps([], for: watcher)
        }
    }

    /// An agent of a later phase whose task took words from what agents of the phase before it
    /// returned, drawn from their first steps until its third: the script's own words into the
    /// first phase never are.
    struct Hop: Equatable {
        /// The recipient's phase, from 0.
        let phase: Int
        let recipient: String
        let sources: [String]
        let task: String
        let well: AttributedString
    }

    static func hops(_ groups: [(phase: String, agents: [WorkflowRun.Agent])], stage: StageModel, chats: [String: Chat]) -> [Hop] {
        groups.indices.dropFirst().flatMap { index -> [Hop] in
            let before = groups[index - 1].agents.filter { $0.state == .done }
            guard !before.isEmpty else { return [] }
            return groups[index].agents.compactMap { agent -> Hop? in
                guard agent.state == .running, let id = agent.id, let chat = chats[id] else { return nil }
                let trail = stage.trail(for: chat.id)
                guard !trail.settled, let task = trail.task else { return nil }
                var sources: [String] = []
                var runs: [Range<String.Index>] = []
                for source in before {
                    guard let sourceID = source.id, let result = stage.results[sourceID] ?? chats[sourceID]?.agentResult else { continue }
                    let found = stage.runs(id, task: task, source: sourceID, result: result)
                    guard !found.isEmpty else { continue }
                    sources.append(sourceID)
                    runs += found.task
                }
                guard !sources.isEmpty else { return nil }
                runs.sort { $0.lowerBound < $1.lowerBound }
                return Hop(phase: index, recipient: id, sources: sources, task: task, well: Handoff.well(task, runs: runs))
            }
        }
    }

    @ViewBuilder
    private func phases(_ layout: StageLayout, steps: Int, scrolls: Bool, hops: [Hop]) -> some View {
        let wells = Dictionary(hops.map { ($0.recipient, $0.well) }) { first, _ in first }
        let handed = hops.reduce(into: [String: String]()) { handed, hop in
            for source in hop.sources { handed[source] = handed[source].map { $0 + "\n" + hop.task } ?? hop.task }
        }
        let content = HStack(alignment: .top, spacing: 0) {
            ForEach(Array(layout.phases.enumerated()), id: \.element.name) { index, phase in
                if index > 0 { Color.clear.frame(width: layout.gutters[index], height: 1) }
                PhaseColumn(phase: phase, steps: steps, head: head, agentChats: agentChats, cwd: chat.cwd,
                            wells: wells, handed: handed, lead: chat.id)
            }
        }
        .overlayPreferenceValue(CardBounds.self) { bounds in
            GeometryReader { proxy in
                HopsDrawing(hops: hops, frames: bounds.mapValues { proxy[$0] })
            }
        }
        .animation(Motion.move, value: layout.widths)
        if scrolls {
            ScrollView { content }.scrollIndicators(.never)
        } else {
            content
        }
    }
}

/// One phase: its label, and its agents' cards side by side while each has 240pt, else stacked.
private struct PhaseColumn: View {
    let phase: StageLayout.Phase
    let steps: Int
    let head: Head
    let agentChats: [String: Chat]
    let cwd: String
    /// The task each recipient of a hop opens in its well.
    let wells: [String: AttributedString]
    /// The task each source of a hop handed its words to.
    let handed: [String: String]
    /// The thread whose stage it is.
    let lead: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: StageLayout.labelGap) {
            Text(phase.name)
                .font(Type.secondary)
                .foregroundStyle(phase.state == .ahead ? Ink.faint : Ink.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: StageLayout.labelHeight)
                .padding(.leading, StageLayout.labelInset)
            if phase.sideBySide {
                HStack(alignment: .top, spacing: StageLayout.spacing) { cards }
            } else {
                VStack(alignment: .leading, spacing: StageLayout.spacing) { cards }
            }
        }
        .frame(width: phase.width, alignment: .leading)
    }

    private var cards: some View {
        ForEach(Array(phase.agents.enumerated()), id: \.offset) { _, agent in
            StageCard(agent: agent, chat: agent.id.flatMap { agentChats[$0] }, ray: agent.id.flatMap { head.agentRays[$0] },
                      color: MarkPalette.color(for: head.agent), steps: steps, collapsed: phase.collapsed, cwd: cwd,
                      well: agent.id.flatMap { wells[$0] }, handed: agent.id.flatMap { handed[$0] }, lead: lead)
        }
    }
}

/// An agent on the stage: its mark and label, and under them what it's doing now, the first line
/// of what it returned, or why it failed. No word says its state; its tint and its mark do.
private struct StageCard: View {
    @Environment(AppModel.self) private var model
    let agent: WorkflowRun.Agent
    /// Its thread, which its trail and its result are kept by.
    let chat: Chat?
    /// The ray it holds on the run's mark while it works.
    let ray: Int?
    let color: Color
    /// How many of its last calls it shows.
    let steps: Int
    /// Its head row alone, in a finished phase of a narrow column.
    let collapsed: Bool
    let cwd: String
    /// Its task, in a well under its head while it takes in what the phase before returned.
    let well: AttributedString?
    /// The task that took its words, while that hop is drawn.
    let handed: String?
    /// The thread whose stage it is.
    let lead: UUID
    @Environment(\.stageSpace) private var space

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                StageMark(state: agent.state, ray: ray, color: color)
                    .frame(width: 14, height: 14)
                    .stageMatched(agent.id.map { StageMark.matchID($0) } ?? "", in: agent.id == nil ? nil : space)
                Text(agent.label)
                    .font(Type.mono)
                    .foregroundStyle(agent.state == .queued ? Ink.faint : agent.state == .running ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
            }
            .frame(height: StageLayout.cardHead)
            if !collapsed, let well {
                Text(well)
                    .font(Type.secondary)
                    .lineLimit(StageLayout.wellLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, StageLayout.wellPadding.height)
                    .padding(.horizontal, StageLayout.wellPadding.width)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                    .padding(.top, StageLayout.wellGap)
                    .transition(.opacity)
            }
            if !collapsed {
                switch agent.state {
                case .running where steps > 0:
                    TrailLines(trail: chat.map { model.stage.trail(for: $0.id) }, fallback: fallback, steps: steps, cwd: cwd)
                        .padding(.top, StageLayout.trailGap)
                case .done:
                    line(chat?.agentResult)
                case .failed:
                    line(agent.error ?? chat?.agentResult)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.top, StageLayout.cardTop)
        .padding(.horizontal, StageLayout.cardSide)
        .padding(.bottom, StageLayout.cardBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // What grows into the agent's surface as the stage steps into it.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(tint))
                .stageMatched(agent.id.map { AgentSurface.matchID($0) } ?? "", in: agent.id == nil ? nil : space)
        }
        .anchorPreference(key: CardBounds.self, value: .bounds) { bounds in agent.id.map { [$0: bounds] } ?? [:] }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        // A click steps into the agent, and with ⌥ opens its thread beside.
        .onTapGesture {
            guard let chat else { return }
            if NSEvent.modifierFlags.contains(.option) { model.openBeside(chat) } else { model.step(into: chat, of: lead) }
        }
        .help(agent.label)
        .animation(Motion.fade, value: agent.state)
        .animation(Motion.fade, value: well == nil)
        .animation(Motion.fade, value: handed == nil)
    }

    @ViewBuilder
    private func line(_ text: String?) -> some View {
        if let text {
            Text(handed.map { Handoff.source(text, task: $0) } ?? AttributedString(text))
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, StageLayout.resultGap)
                .transition(.opacity)
        }
    }

    /// The snapshot's last call, for an agent whose own transcript hasn't been read yet, in the
    /// words its trail would have for it.
    private var fallback: String? {
        guard let tool = agent.lastTool else { return nil }
        let key: String? = switch ToolKind(claude: tool) {
        case .run: "command"
        case .read, .edit, .write: "file_path"
        case .search: "pattern"
        default: nil
        }
        let input: JSON = key.flatMap { key in agent.lastDetail.map { [key: .string($0)] } } ?? [:]
        return ToolSummary.line(for: ToolCall(toolUseId: "", name: tool, input: input), cwd: cwd)
    }

    private var tint: Double {
        switch agent.state {
        case .running: 0.05
        case .done, .failed: 0.035
        case .queued: 0.025
        }
    }

}

/// An agent's mark on the stage, by its state: its own ray turning while it works, a dot once it's
/// over, faint while it waits its turn.
private struct StageMark: View {
    let state: WorkflowRun.Agent.State
    /// The ray it holds on the run's mark while it works.
    let ray: Int?
    let color: Color

    static func matchID(_ agent: String) -> String { "mark:" + agent }

    var body: some View {
        switch state {
        case .running:
            RaysMark(slots: ray.map { [$0] } ?? [], turning: ray != nil, restingOpacity: 0.16,
                     colors: ray.map { [$0: color] } ?? [:])
        case .done:
            RaysMark(restingOpacity: 0.16, dotOpacity: 0.5)
        case .failed:
            RaysMark(restingOpacity: 0.16, dotColor: Ink.deleted)
        case .queued:
            RaysMark(restingOpacity: 0.10, dotOpacity: 0.18)
        }
    }
}

/// The run's agents as their marks on the head row while the stage is stepped into one, grouped by
/// phase: each a capsule to click across to, the one stepped into on the selected tint with its
/// label, which steps back out. Every mark's label is its hover.
private struct StepMarks: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let phases: [StageLayout.Phase]
    let stepped: String
    let head: Head
    let agentChats: [String: Chat]
    let lead: UUID

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(phases.filter { !$0.agents.isEmpty }.enumerated()), id: \.element.name) { _, phase in
                HStack(spacing: 2) {
                    ForEach(Array(phase.agents.enumerated()), id: \.offset) { _, agent in
                        capsule(agent)
                    }
                }
            }
        }
    }

    private func capsule(_ agent: WorkflowRun.Agent) -> some View {
        let selected = agent.id == stepped
        let chat = agent.id.flatMap { agentChats[$0] }
        return HStack(spacing: 9) {
            StageMark(state: agent.state, ray: agent.id.flatMap { head.agentRays[$0] }, color: MarkPalette.color(for: head.agent))
                .frame(width: 14, height: 14)
                .stageMatched(agent.id.map { StageMark.matchID($0) } ?? "", in: agent.id == nil ? nil : space)
            if selected {
                // Gone at once from the capsule left and in once the new one has its room, so
                // two labels never read over each other on the way.
                Text(agent.label)
                    .font(Type.mono)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)), removal: .identity))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, selected ? 11 : 7)
        .frame(height: 28)
        .background {
            if selected { Capsule().fill(Surface.selected) }
        }
        .contentShape(Capsule())
        .onTapGesture {
            guard let chat else { return }
            if NSEvent.modifierFlags.contains(.option) {
                model.openBeside(chat)
            } else {
                model.step(into: selected ? nil : chat, of: lead)
            }
        }
        .help(agent.label)
    }
}

/// The agent a stage is stepped into, on a surface of its own grown out of its card: its thread's
/// transcript, read-only, its task in a well at its top. The composer under it stays the lead's.
private struct AgentSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let stepped: StageModel.Stepped

    static func matchID(_ agent: String) -> String { "card:" + agent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .stageMatched(Self.matchID(stepped.agent), in: space)
            // Across to another agent, one transcript goes before the next comes, so no line is
            // read over another.
            if let conversation = model.conversations[stepped.thread] {
                TranscriptView(conversation: conversation, cwd: conversation.chat.cwd, active: false, stepped: true)
                    .id(stepped.thread)
                    .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)), removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
    }
}

/// A running agent's last calls, the one it's on in ink and up to three before it fading under it.
/// A view of its own over its trail alone, so a call coming in draws these lines and nothing else.
private struct TrailLines: View {
    let trail: StageModel.Trail?
    let fallback: String?
    let steps: Int
    let cwd: String

    private static let inks: [Double] = [0.92, 0.55, 0.38, 0.24]

    var body: some View {
        let all = trail?.steps ?? []
        let first = trail?.first ?? 0
        let shown: [(id: Int, words: AttributedString)] = all.isEmpty
            ? fallback.map { [(id: -1, words: AttributedString($0))] } ?? []
            : all.enumerated().suffix(steps).reversed().map { index, step in
                (first + index, Self.words(step, cwd: cwd, last: index == all.count - 1))
            }
        VStack(alignment: .leading, spacing: StageLayout.stepGap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { place, step in
                Text(step.words)
                    .font(place == 0 ? Type.body : Type.secondary)
                    .foregroundStyle(Color.white.opacity(Self.inks[min(place, Self.inks.count - 1)]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
            }
        }
        // A fade's length and not the spring's: with four agents at work a call lands every
        // quarter second or so, and a spring still settling under the next kept frames coming.
        .animation(Motion.fade, value: shown.map(\.id))
    }

    /// A call as the transcript says it, with a file's folder after its name in faint ink: "Read
    /// Cache.swift Sources/Store". A call before the last is over, so a command reads "Ran".
    static func words(_ step: StageModel.Step, cwd: String, last: Bool) -> AttributedString {
        let call = ToolCall(toolUseId: "", name: step.tool, input: step.input, result: last ? nil : "")
        let line = ToolSummary.line(for: call, cwd: cwd)
        guard let path = ToolSummary.path(for: call) else { return AttributedString(line) }
        let shown = ToolSummary.relative(path, to: cwd)
        let folder = (shown as NSString).deletingLastPathComponent
        guard line.hasSuffix(shown), !folder.isEmpty else { return AttributedString(line) }
        var words = AttributedString(String(line.dropLast(shown.count)) + (shown as NSString).lastPathComponent + " ")
        var faint = AttributedString(folder)
        faint.foregroundColor = Ink.faint
        words.append(faint)
        return words
    }
}

/// Each card's bounds, by its agent's id, for the wires of a hop.
private struct CardBounds: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A wire of a hop, a curve leaving and arriving level.
struct Wire: Equatable {
    let from: CGPoint
    let to: CGPoint

    var path: Path {
        var path = Path()
        path.move(to: from)
        let (one, two) = controls
        path.addCurve(to: to, control1: one, control2: two)
        return path
    }

    func point(at t: CGFloat) -> CGPoint {
        let (one, two) = controls
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * from.x + b * one.x + c * two.x + d * to.x, y: a * from.y + b * one.y + c * two.y + d * to.y)
    }

    private var controls: (CGPoint, CGPoint) {
        let half = (to.x - from.x) / 2
        return (CGPoint(x: from.x + half, y: from.y), CGPoint(x: to.x - half, y: to.y))
    }
}

/// The hops of a stage, each phase's in its gutter: the script's node at the middle of its sources,
/// a wire in from each and one out to each recipient, drawn under nothing and over no text.
private struct HopsDrawing: View {
    let hops: [RunStage.Hop]
    let frames: [String: CGRect]

    static let node: CGFloat = 26
    /// Where a wire meets its recipient, under the top of its card.
    static let landing: CGFloat = 26

    struct Wiring: Identifiable {
        let id: Int
        let node: CGPoint
        let ins: [Wire]
        let outs: [(recipient: String, wire: Wire)]
    }

    var body: some View {
        let wirings = Dictionary(grouping: hops, by: \.phase).keys.sorted().compactMap { wiring($0) }
        ZStack(alignment: .topLeading) {
            ForEach(wirings) { wiring in
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for wire in wiring.ins {
                            context.stroke(wire.path, with: .linearGradient(Gradient(colors: [.white.opacity(0.06), .white.opacity(0.34)]),
                                                                            startPoint: wire.from, endPoint: wire.to), lineWidth: 1.5)
                        }
                        for out in wiring.outs {
                            context.stroke(out.wire.path, with: .linearGradient(Gradient(colors: [.white.opacity(0.40), .white.opacity(0.14)]),
                                                                                startPoint: out.wire.from, endPoint: out.wire.to), lineWidth: 1.5)
                        }
                    }
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .overlay {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(0.7))
                        }
                        .frame(width: Self.node, height: Self.node)
                        .position(wiring.node)
                    ForEach(wiring.outs, id: \.recipient) { out in
                        SparkRun(recipient: out.recipient, wire: out.wire)
                    }
                }
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(Motion.fade, value: wirings.map(\.id))
    }

    private func wiring(_ phase: Int) -> Wiring? {
        let into = hops.filter { $0.phase == phase }
        let sources = Set(into.flatMap(\.sources)).compactMap { frames[$0] }
        let recipients = into.compactMap { hop in frames[hop.recipient].map { (hop.recipient, $0) } }
        guard !sources.isEmpty, let edge = recipients.map(\.1.minX).min(), let out = sources.map(\.maxX).max() else { return nil }
        let node = CGPoint(x: (out + edge) / 2, y: sources.map(\.midY).reduce(0, +) / CGFloat(sources.count))
        let half = Self.node / 2
        return Wiring(
            id: phase, node: node,
            ins: sources.map { Wire(from: CGPoint(x: $0.maxX, y: $0.midY), to: CGPoint(x: node.x - half, y: node.y)) },
            // A recipient beside another in its phase would have its wire cross that card, so only
            // those on the phase's leading edge take one.
            outs: recipients.filter { $0.1.minX <= edge + 1 }.map { recipient, frame in
                (recipient, Wire(from: CGPoint(x: node.x + half, y: node.y), to: CGPoint(x: frame.minX, y: frame.minY + Self.landing)))
            })
    }
}

/// The one thing on the stage that travels: a spark along a hop's wire to its recipient, once,
/// as the hop lands. Reduce Motion leaves it out.
private struct SparkRun: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let recipient: String
    let wire: Wire
    @State private var t: CGFloat = 0
    @State private var shown = false

    var body: some View {
        Spark(wire: wire, t: t)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !reduceMotion, model.stage.sparked.insert(recipient).inserted else { return }
                shown = true
                // After the gutter has opened under it.
                withAnimation(.easeOut(duration: 0.6).delay(0.28)) { t = 1 }
            }
    }
}

private struct Spark: View, Animatable {
    let wire: Wire
    var t: CGFloat

    nonisolated var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    var body: some View {
        RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 6)
            .frame(width: 12, height: 12)
            // Gone as it arrives.
            .opacity(min(1, (1 - t) * 6))
            .position(wire.point(at: t))
    }
}

/// Where the stage's phases go across its width, and how tall it is: a live phase shares what the
/// others leave, up to 400pt a card; a finished one is 250pt; one not reached is its label's width.
struct StageLayout: Equatable {
    enum State: Equatable {
        case live, finished, ahead
    }

    struct Phase: Equatable {
        let name: String
        let agents: [WorkflowRun.Agent]
        let state: State
        let width: CGFloat
        let sideBySide: Bool
        let collapsed: Bool
    }

    static let gutter: CGFloat = 34
    /// A gutter a hop is drawn in, wide enough for the script's node and its wires.
    static let wideGutter: CGFloat = 72
    static let spacing: CGFloat = 10
    static let card: CGFloat = 400
    static let leastCard: CGFloat = 240
    static let leastNarrow: CGFloat = 160
    static let finished: CGFloat = 250
    /// A finished phase in a column under 560pt, its cards their head rows.
    static let collapsedFinished: CGFloat = 150
    static let labelHeight: CGFloat = 16
    static let labelInset: CGFloat = 14
    static let labelGap: CGFloat = 10
    static let cardTop: CGFloat = 13
    static let cardSide: CGFloat = 14
    static let cardBottom: CGFloat = 14
    static let cardHead: CGFloat = 16
    static let trailGap: CGFloat = 11
    static let stepGap: CGFloat = 5
    static let resultGap: CGFloat = 10
    static let wellGap: CGFloat = 11
    static let wellPadding = CGSize(width: 12, height: 10)
    static let wellLines = 8
    /// A line of body type and one of secondary, as Text lays them out.
    static let bodyLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14)))
    static let secondaryLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12.5)))

    let phases: [Phase]
    /// The space before each phase, none before the first.
    let gutters: [CGFloat]
    /// How much each recipient's well adds to its card, by its agent's id.
    let wells: [String: CGFloat]

    var widths: [CGFloat] { phases.map(\.width) + gutters }

    /// `wide` names the phases a hop goes into, whose gutter widens; `wells` the tasks shown in wells.
    init(groups: [(phase: String, agents: [WorkflowRun.Agent])], width: CGFloat, narrow: Bool,
         wide: Set<Int> = [], wells: [String: String] = [:]) {
        gutters = groups.indices.map { $0 == 0 ? 0 : wide.contains($0) ? Self.wideGutter : Self.gutter }
        let states: [State] = groups.map { group in
            if group.agents.isEmpty { return .ahead }
            return group.agents.allSatisfy { $0.state == .done || $0.state == .failed } ? .finished : .live
        }
        let fixed: [CGFloat?] = zip(groups, states).map { group, state in
            switch state {
            case .ahead: ceil(Self.labelWidth(group.phase)) + Self.labelInset
            case .finished: narrow ? Self.collapsedFinished : Self.finished
            case .live: nil
            }
        }
        let live = states.count { $0 == .live }
        let left = width - fixed.compactMap { $0 }.reduce(0, +) - gutters.reduce(0, +)
        // Narrow, a live phase takes what's left down to a stacked card of 160pt.
        let share = live == 0 ? 0 : max(left / CGFloat(live), narrow ? Self.leastNarrow : Self.leastCard)
        phases = zip(groups, zip(states, fixed)).map { group, entry in
            let (state, fixed) = entry
            let count = CGFloat(max(group.agents.count, 1))
            var width = fixed ?? min(share, count * Self.card + (count - 1) * Self.spacing)
            // A finished phase stacks its cards, a result line each, in its 250pt.
            let sideBySide = state == .live && (width - (count - 1) * Self.spacing) / count >= Self.leastCard
            if state == .live, !sideBySide { width = min(width, Self.card) }
            return Phase(name: group.phase, agents: group.agents, state: state, width: width, sideBySide: sideBySide,
                         collapsed: narrow && state == .finished)
        }
        var heights: [String: CGFloat] = [:]
        for phase in phases where !phase.collapsed {
            let count = CGFloat(phase.agents.count)
            let card = phase.sideBySide ? (phase.width - (count - 1) * Self.spacing) / count : phase.width
            let inside = card - Self.cardSide * 2 - Self.wellPadding.width * 2
            for agent in phase.agents {
                guard let id = agent.id, let task = wells[id] else { continue }
                let text = (task as NSString).boundingRect(with: CGSize(width: inside, height: .greatestFiniteMagnitude),
                                                           options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                           attributes: [.font: NSFont.systemFont(ofSize: 12.5)]).height
                heights[id] = Self.wellGap + Self.wellPadding.height * 2 + min(ceil(text), Self.secondaryLine * CGFloat(Self.wellLines))
            }
        }
        self.wells = heights
    }

    /// The layout for `width`, narrow when the phases wouldn't fit across it otherwise: three phases
    /// in a column beside another thread don't at 250pt a finished one.
    static func fitted(groups: [(phase: String, agents: [WorkflowRun.Agent])], width: CGFloat, narrow: Bool,
                       wide: Set<Int>, wells: [String: String]) -> StageLayout {
        let layout = StageLayout(groups: groups, width: width, narrow: narrow, wide: wide, wells: wells)
        guard !narrow, layout.widths.reduce(0, +) > width else { return layout }
        return StageLayout(groups: groups, width: width, narrow: true, wide: wide, wells: wells)
    }

    static func labelWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
    }

    /// The phases' height, labels and cards, with each running card showing `steps` calls.
    func height(steps: Int) -> CGFloat {
        phases.map { phase in
            let cards = phase.agents.map { agent in
                Self.cardHeight(agent, steps: steps, collapsed: phase.collapsed) + (agent.id.flatMap { wells[$0] } ?? 0)
            }
            guard !cards.isEmpty else { return Self.labelHeight }
            let stacked = phase.sideBySide ? cards.max() ?? 0 : cards.reduce(0, +) + Self.spacing * CGFloat(cards.count - 1)
            return Self.labelHeight + Self.labelGap + stacked
        }.max() ?? 0
    }

    /// The most calls a running card shows with the phases inside `room`: four, then fewer before
    /// anything scrolls.
    func steps(within room: CGFloat) -> Int {
        (0...4).reversed().first { height(steps: $0) <= room } ?? 0
    }

    static func cardHeight(_ agent: WorkflowRun.Agent, steps: Int, collapsed: Bool) -> CGFloat {
        let head = cardTop + cardHead + cardBottom
        guard !collapsed else { return head }
        switch agent.state {
        case .running where steps > 0:
            return head + trailGap + bodyLine + CGFloat(steps - 1) * (stepGap + secondaryLine)
        case .done, .failed:
            return head + resultGap + secondaryLine
        default:
            return head
        }
    }
}

/// The run in the transcript while it works, in its card's place: its mark, its name and a chevron
/// that points up at the stage while it's open. A click opens or folds the stage.
struct RunLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let call: ToolCall
    let head: Head
    let thread: UUID

    static func matchID(_ run: String) -> String { "run:" + run }

    var body: some View {
        let open = model.stage.shown[thread] == call.toolUseId
        let script = call.input["script"]?.string ?? ""
        let name = head.run?.name ?? call.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        Button {
            model.stage.toggle(call.toolUseId, in: thread)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    RaysMark(slots: Set(head.rays), turning: !head.rays.isEmpty, colors: MarkPalette.colors(of: head))
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                // Folded, they're here for the stage's head to grow out of; while it's up, its head has them.
                .stageMatched(open ? "line:" + call.toolUseId : Self.matchID(call.toolUseId), in: space)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.faint)
                    .rotationEffect(.degrees(open ? -90 : 0))
            }
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(Motion.move, value: open)
    }
}

extension View {
    /// Matched across the column's space.
    @ViewBuilder
    func stageMatched(_ id: String, in space: Namespace.ID?) -> some View {
        if let space {
            matchedGeometryEffect(id: id, in: space)
        } else {
            self
        }
    }
}

/// A workflow call in the transcript: its line while it runs, which the stage grows out of and
/// folds back into, and its card once it's over.
struct WorkflowRow: View {
    let call: ToolCall
    let thread: UUID?
    @Environment(Heads.self) private var heads: Heads?

    var body: some View {
        if let thread, let head = heads?.list.first(where: { $0.call == call.toolUseId && $0.kind == .workflow && !$0.ending }) {
            RunLine(call: call, head: head, thread: thread)
        } else {
            WorkflowCard(call: call)
        }
    }
}

/// Tells the stage of a run as it comes on the glass, from a view of its own, so the transcript
/// never reads the thread's heads.
struct StageCue: View {
    @Environment(AppModel.self) private var model
    let heads: Heads
    let thread: UUID
    /// The transcript is followed to its end.
    let following: Bool

    var body: some View {
        Color.clear.onChange(of: heads.liveWorkflow?.call, initial: true) { _, run in
            if let run { model.stage.cue(run, in: thread, grow: following) }
        }
    }
}
