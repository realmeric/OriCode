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
    let conversation: Conversation
    let chat: Chat
    let active: Bool
    @Namespace private var space
    /// Where the stage's lowest card ends, nil while it's folded.
    @State private var foot: CGFloat?
    @State private var size = CGSize.zero

    var body: some View {
        TranscriptView(conversation: conversation, cwd: chat.cwd, active: active, stageFoot: foot)
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
                RunStage(head: head, call: call, chat: chat, width: size.width,
                         top: RunStage.top(active: active), cap: size.height - RunStage.underneath, foot: foot)
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
    /// What the stage leaves the lead under it: 180pt of transcript and the 28pt between.
    static let underneath: CGFloat = 180 + 28
    static let headHeight: CGFloat = 28
    /// From the head row's foot to the phases' labels.
    static let labelsGap: CGFloat = 14

    var body: some View {
        let run = head.run
        let script = call?.input["script"]?.string ?? ""
        let groups = WorkflowRun.groups(run?.agents ?? [], planned: WorkflowRun.plannedPhases(in: script), reported: run?.phases ?? [])
        let name = run?.name ?? call?.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        let inset: CGFloat = width < 900 ? 20 : 32
        let layout = StageLayout(groups: groups, width: width - inset * 2, narrow: width < 560)
        let room = cap - top - Self.headHeight - Self.labelsGap
        let steps = layout.steps(within: room)
        // Past the cap with no call left to drop, the cards scroll.
        let scrolls = layout.height(steps: 0) > room
        let agentIDs = (run?.agents ?? []).compactMap(\.id)
        let watched = Set(groups.flatMap(\.agents).filter { $0.state == .running }.compactMap { $0.id.flatMap { agentChats[$0] } }
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
                Button("Stop workflow") { model.stopWorkflow(head.id, of: chat.id) }
                    .buttonStyle(.action(small: true))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .help("Stops every agent of this workflow")
            }
            .frame(height: Self.headHeight)
            phases(layout, steps: steps, scrolls: scrolls)
                .frame(maxHeight: scrolls ? max(room, 0) : nil, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
        }
        .padding(.horizontal, inset)
        .padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .local).maxY } action: { foot($0) }
        .onChange(of: agentIDs, initial: true) { agentChats = model.agentChats(of: chat) }
        // The trails of the agents at work are read while the stage is up, and no longer.
        .onChange(of: watched, initial: true) { model.watchSteps(watched, for: watcher) }
        .onDisappear {
            foot(nil)
            model.watchSteps([], for: watcher)
        }
    }

    @ViewBuilder
    private func phases(_ layout: StageLayout, steps: Int, scrolls: Bool) -> some View {
        let content = HStack(alignment: .top, spacing: 0) {
            ForEach(Array(layout.phases.enumerated()), id: \.element.name) { index, phase in
                if index > 0 { Color.clear.frame(width: StageLayout.gutter, height: 1) }
                PhaseColumn(phase: phase, steps: steps, head: head, agentChats: agentChats, cwd: chat.cwd)
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
                      color: MarkPalette.color(for: head.agent), steps: steps, collapsed: phase.collapsed, cwd: cwd)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                mark.frame(width: 14, height: 14)
                Text(agent.label)
                    .font(Type.mono)
                    .foregroundStyle(agent.state == .queued ? Ink.faint : agent.state == .running ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
            }
            .frame(height: StageLayout.cardHead)
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
        .background(Color.white.opacity(tint), in: .rect(cornerRadius: 14, style: .continuous))
        .help(agent.label)
        .animation(Motion.fade, value: agent.state)
    }

    @ViewBuilder
    private func line(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(Type.secondary)
                .foregroundStyle(Color.white.opacity(0.55))
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

    @ViewBuilder
    private var mark: some View {
        switch agent.state {
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
    static let spacing: CGFloat = 10
    static let card: CGFloat = 400
    static let leastCard: CGFloat = 240
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
    /// A line of body type and one of secondary, as Text lays them out.
    static let bodyLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14)))
    static let secondaryLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12.5)))

    let phases: [Phase]

    var widths: [CGFloat] { phases.map(\.width) }

    init(groups: [(phase: String, agents: [WorkflowRun.Agent])], width: CGFloat, narrow: Bool) {
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
        let left = width - fixed.compactMap { $0 }.reduce(0, +) - Self.gutter * CGFloat(max(groups.count - 1, 0))
        let share = live == 0 ? 0 : max(left / CGFloat(live), Self.leastCard)
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
    }

    static func labelWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
    }

    /// The phases' height, labels and cards, with each running card showing `steps` calls.
    func height(steps: Int) -> CGFloat {
        phases.map { phase in
            let cards = phase.agents.map { Self.cardHeight($0, steps: steps, collapsed: phase.collapsed) }
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
