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
/// nor the column does: nothing at all while the stage is folded.
private struct StageSlot: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let chat: Chat
    let active: Bool
    let size: CGSize
    let foot: (CGFloat?) -> Void
    /// The call that started the run shown, read once as it's called up, so the transcript's items
    /// changing never draws the stage again.
    @State private var call: ToolCall?
    /// The run was over when its stage was called up, which gives every phase an equal share.
    @State private var reopened = false

    var body: some View {
        let shown = model.stage.shown[chat.id]
        let lane = model.stage.lanes[chat.id] ?? []
        let live = conversation.heads.liveWorkflow
        // Called up by the column's line, the stage still has the run at work's phases first.
        let key = shown == StageModel.laneKey ? live?.call : shown
        let head = live.flatMap { $0.call == key ? $0 : nil }
        // Over, the run is as it last was: in this launch, as the engine last told of it, which
        // can come after its head has gone; before, as the store has it.
        let run = head?.run ?? key.flatMap { conversation.heads.finished[$0] } ?? call?.workflow
        let workflow = key != nil && key == call?.toolUseId && (head != nil || run != nil)
        let up = shown != nil && (workflow || !lane.isEmpty)
        ZStack(alignment: .top) {
            if up {
                RunStage(head: head, run: run, call: workflow ? call : nil, lane: lane, heads: conversation.heads, equal: reopened, chat: chat, active: active,
                         width: size.width, top: RunStage.top(active: active), cap: size.height - RunStage.underneath, floor: size.height - RunStage.gap, foot: foot)
                    .transition(.opacity)
            }
        }
        // The transcript takes its room back as the fold begins, not once the cards have faded.
        .onChange(of: up) { if !up { foot(nil) } }
        .onChange(of: key, initial: true) {
            call = key.flatMap(conversation.call)
            reopened = key != nil && head == nil
        }
        .onChange(of: live?.call) { old, now in
            // Its run over, its stage folds into its line a moment later.
            if let old, now == nil { model.stage.ended(old, in: chat.id) }
        }
    }
}

/// A workflow at work, on the column's glass above the lead's transcript: the run's mark and name,
/// then its phases left to right, each with its agents' cards, which say by their tint and their
/// mark how each agent is and show what it's doing now. What the thread set going besides a
/// workflow is one column of the same cards after the phases, or alone on the transcript's column.
/// It has no surface of its own.
struct RunStage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    /// The run's head while it works, nil once it's over.
    let head: Head?
    let run: WorkflowRun?
    /// The Workflow call that started it, for the phases its script plans and its name; nil for a
    /// stage of what the thread set going besides a workflow.
    let call: ToolCall?
    /// What the thread set going besides a workflow, in the order it started.
    let lane: [LaneCard]
    /// The thread's heads, whose commands' last lines their cards show.
    let heads: Heads
    /// Every phase on an equal share, for a run called up again after it was over.
    let equal: Bool
    let chat: Chat
    /// The column has the keyboard, so the oldest ask's Allow takes Return.
    let active: Bool
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
    /// The column's threads, looked up as its cards come.
    @State private var laneChats: [UUID: Chat] = [:]
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
    /// The column alone starts its cards this far under the head row's top, at y 64.
    static let laneDrop: CGFloat = 2

    var body: some View {
        let script = call?.input["script"]?.string ?? ""
        let agents = Self.told(run?.agents ?? [], stage: model.stage, chats: agentChats)
        let groups = call == nil ? [] : WorkflowRun.groups(agents, planned: WorkflowRun.plannedPhases(in: script), reported: run?.phases ?? [])
        let agentIDs = (run?.agents ?? []).compactMap(\.id)
        let stepped = model.stage.stepped[chat.id]
        // Stepped into an agent, no card shows a trail.
        let watched = stepped != nil ? [] : followed(groups)
        // A command's last lines come from the engine only while a card shows them.
        let commands = stepped == nil && lane.contains { $0.kind == .command && $0.working }
        let laneThreads = lane.compactMap(\.thread)
        Group {
            if let call {
                workflow(call, groups: groups, stepped: stepped)
            } else {
                column(stepped: stepped)
            }
        }
        .padding(.top, top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        // Stepped into an agent, the lead's transcript under it keeps the top it had.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .local).maxY } action: { if model.stage.stepped[chat.id] == nil { foot($0) } }
        .onChange(of: agentIDs, initial: true) { agentChats = model.agentChats(of: chat) }
        .onChange(of: laneThreads, initial: true) {
            laneChats = laneThreads.reduce(into: [:]) { chats, id in chats[id] = laneChats[id] ?? model.chat(withID: id) }
        }
        // The trails of the agents at work are read while the stage is up, and no longer.
        .onChange(of: watched, initial: true) { model.watchSteps(watched, for: watcher) }
        .onChange(of: commands, initial: true) { model.watchLaneHeads(chat.id, commands) }
        .onDisappear {
            foot(nil)
            model.watchSteps([], for: watcher)
            model.watchLaneHeads(chat.id, false)
        }
    }

    /// The run's agents, each one whose transcript has the reply that ended its turn done, ahead of
    /// the run's next snapshot.
    static func told(_ agents: [WorkflowRun.Agent], stage: StageModel, chats: [String: Chat]) -> [WorkflowRun.Agent] {
        agents.map { agent in
            guard agent.state == .running, let chat = agent.id.flatMap({ chats[$0] }), stage.trail(for: chat.id).done else { return agent }
            var done = agent
            done.state = .done
            return done
        }
    }

    /// The agents at work whose transcripts their trails are read from: the run's, and the column's subagents.
    private func followed(_ groups: [(phase: String, agents: [WorkflowRun.Agent])]) -> Set<UUID> {
        let running = groups.flatMap(\.agents).filter { $0.state == .running }
        let agents: [Chat] = running.compactMap { agent in agent.id.flatMap { agentChats[$0] } }
        let subagents: [Chat] = lane.filter { $0.kind == .subagent && $0.working }.compactMap { card in card.thread.flatMap { laneChats[$0] } }
        return Set((agents + subagents).filter { $0.agentTranscript != nil }.map(\.id))
    }

    /// The run's head row and its phases, with the column after them, or the agent stepped into.
    @ViewBuilder
    private func workflow(_ call: ToolCall, groups: [(phase: String, agents: [WorkflowRun.Agent])], stepped: StageModel.Stepped?) -> some View {
        let script = call.input["script"]?.string ?? ""
        let name = run?.name ?? call.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        let rays = head?.agentRays ?? [:]
        let color = MarkPalette.color(for: head?.agent ?? chat.providerID)
        let inset: CGFloat = width < 900 ? 20 : 32
        let hops = Self.hops(groups, stage: model.stage, chats: agentChats)
        let lead = model.conversations[chat.id]
        let asks = Self.asks(lead?.waitingAsks ?? [])
        // Not while a block is open: Return typed there mustn't answer the card.
        let listening = active && model.openShell == nil ? lead?.waitingAsk?.requestId : nil
        let across = width - inset * 2
        // The column beside the phases, a gutter after them.
        let laneWidth = lane.isEmpty ? 0 : min(StageLayout.card, (across * 0.34).rounded(.down))
        // A hop's gutter stays open until its well has folded; the well's room goes as it folds.
        let layout = StageLayout.fitted(groups: groups, width: across - (lane.isEmpty ? 0 : StageLayout.gutter + laneWidth), narrow: width < 560, equal: equal,
                                        wide: Set(hops.map(\.phase)), wells: hops.filter { !$0.folded }.reduce(into: [:]) { $0[$1.recipient] = $1.well },
                                        asks: asks.mapValues { $0.call.shown("command") ?? "" })
        let room = cap - top - Self.headHeight - Self.labelsGap
        let beside = lane.isEmpty ? { (_: Int) in CGFloat(0) } : { StageLayout.labelHeight + StageLayout.labelGap + LaneLayout.height(lane, steps: $0) }
        let steps = (0...4).reversed().first { max(layout.height(steps: $0), beside($0)) <= room } ?? 0
        // Past the cap with no call left to drop, the cards scroll.
        let scrolls = max(layout.height(steps: 0), beside(0)) > room
        VStack(alignment: .leading, spacing: Self.labelsGap) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    RaysMark(slots: Set(head?.rays ?? []), turning: !(head?.rays ?? []).isEmpty, colors: head.map(MarkPalette.colors(of:)) ?? [:])
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                .stageMatched(RunLine.matchID(call.toolUseId), in: space)
                Spacer(minLength: 8)
                // Stepped in, the marks keep the row's end and Stop comes in beside them.
                if let head, stepped == nil || hovering {
                    Button("Stop workflow") { model.stopWorkflow(head.id, of: chat.id) }
                        .buttonStyle(.action(small: true))
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                        .help("Stops every agent of this workflow")
                        .transition(.opacity)
                }
                if let stepped {
                    StepMarks(phases: layout.phases, lane: lane, laneChats: laneChats, stepped: stepped.agent, rays: rays, color: color,
                              agentChats: agentChats, lead: chat.id, asking: Set(asks.keys))
                }
            }
            .frame(height: Self.headHeight)
            if let stepped {
                AgentSurface(stepped: stepped, ask: asks[stepped.agent], lead: chat, listens: asks[stepped.agent].map { $0.requestId == listening } ?? false)
                    .frame(height: max(floor - top - Self.headHeight - Self.labelsGap, 0))
                    .transition(.opacity)
            } else {
                phases(layout, steps: steps, scrolls: scrolls, hops: hops, asks: asks, listening: listening, rays: rays, color: color, laneWidth: laneWidth)
                    .frame(maxHeight: scrolls ? max(room, 0) : nil, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
            }
        }
        .padding(.horizontal, inset)
    }

    /// The column alone on the transcript's column from y 64, with no label and no head row; the
    /// head row comes only while it's stepped into a card, its marks alone.
    @ViewBuilder
    private func column(stepped: StageModel.Stepped?) -> some View {
        let inset: CGFloat = width < 900 ? 20 : 32
        if let stepped {
            VStack(alignment: .leading, spacing: Self.labelsGap) {
                HStack(spacing: 8) {
                    Spacer(minLength: 8)
                    StepMarks(phases: [], lane: lane, laneChats: laneChats, stepped: stepped.agent, rays: [:], color: Ink.primary,
                              agentChats: [:], lead: chat.id, asking: [])
                }
                .frame(height: Self.headHeight)
                AgentSurface(stepped: stepped, ask: nil, lead: chat, listens: false)
                    .frame(height: max(floor - top - Self.headHeight - Self.labelsGap, 0))
                    .transition(.asymmetric(insertion: .opacity, removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
            .padding(.horizontal, inset)
        } else {
            let room = cap - top - Self.laneDrop
            let steps = (0...4).reversed().first { LaneLayout.height(lane, steps: $0) <= room } ?? 0
            let scrolls = LaneLayout.height(lane, steps: 0) > room
            let cards = LaneColumn(cards: lane, steps: steps, lead: chat, chats: laneChats, heads: heads)
                .frame(width: min(Column.width, width - Column.margin * 2))
            Group {
                if scrolls {
                    ScrollView { cards }
                        .scrollIndicators(.never)
                        .frame(height: max(room, 0))
                } else {
                    cards
                }
            }
            .padding(.top, Self.laneDrop)
            .frame(maxWidth: .infinity)
            // Back from a card stepped into, the cards come once its surface has gone, so no line is read over another.
            .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.12)), removal: .opacity.animation(.easeOut(duration: 0.1))))
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
        /// The recipient's third call has landed: its well's words fade, its wires fade and its
        /// sources' lines brighten again, while its gutter waits for the well to have gone.
        let settled: Bool
        /// Then the well's room closes.
        let folded: Bool
    }

    /// The oldest ask each workflow agent has waiting, by its id: the one its card shows.
    static func asks(_ waiting: [PendingAsk]) -> [String: PendingAsk] {
        waiting.reduce(into: [:]) { asks, ask in
            guard ask.staged, let id = ask.agentID, asks[id] == nil else { return }
            asks[id] = ask
        }
    }

    static func hops(_ groups: [(phase: String, agents: [WorkflowRun.Agent])], stage: StageModel, chats: [String: Chat]) -> [Hop] {
        groups.indices.dropFirst().flatMap { index -> [Hop] in
            let before = groups[index - 1].agents.filter { $0.state == .done }
            guard !before.isEmpty else { return [] }
            return groups[index].agents.compactMap { agent -> Hop? in
                guard agent.state == .running, let id = agent.id, let chat = chats[id] else { return nil }
                let trail = stage.trail(for: chat.id)
                guard !trail.closed, let task = trail.task else { return nil }
                var sources: [String] = []
                var runs: [Range<String.Index>] = []
                for source in before {
                    guard let sourceID = source.id,
                          let result = stage.results[sourceID] ?? chats[sourceID].flatMap({ stage.trail(for: $0.id).result ?? $0.agentResult })
                    else { continue }
                    let found = stage.runs(id, task: task, source: sourceID, result: result)
                    guard !found.isEmpty else { continue }
                    sources.append(sourceID)
                    runs += found.task
                }
                guard !sources.isEmpty else { return nil }
                runs.sort { $0.lowerBound < $1.lowerBound }
                return Hop(phase: index, recipient: id, sources: sources, task: task, well: Handoff.well(task, runs: runs), settled: trail.settled, folded: trail.folded)
            }
        }
    }

    @ViewBuilder
    private func phases(_ layout: StageLayout, steps: Int, scrolls: Bool, hops: [Hop], asks: [String: PendingAsk], listening: String?,
                        rays: [String: Int], color: Color, laneWidth: CGFloat) -> some View {
        let wells = Dictionary(hops.map { ($0.recipient, $0.well) }) { first, _ in first }
        let faded = Set(hops.filter(\.settled).map(\.recipient))
        let folded = Set(hops.filter(\.folded).map(\.recipient))
        let handed = hops.filter { !$0.settled }.reduce(into: [String: String]()) { handed, hop in
            for source in hop.sources { handed[source] = handed[source].map { $0 + "\n" + hop.task } ?? hop.task }
        }
        let content = HStack(alignment: .top, spacing: 0) {
            ForEach(Array(layout.phases.enumerated()), id: \.element.name) { index, phase in
                if index > 0 { Color.clear.frame(width: layout.gutters[index], height: 1) }
                PhaseColumn(phase: phase, steps: steps, rays: rays, color: color, agentChats: agentChats, cwd: chat.cwd,
                            wells: wells, faded: faded, folded: folded, handed: handed, asks: asks, listening: listening, lead: chat.id)
            }
            // What the thread set going besides the run, unlabelled, its cards level with the phases'.
            if !lane.isEmpty {
                Color.clear.frame(width: StageLayout.gutter, height: 1)
                LaneColumn(cards: lane, steps: steps, lead: chat, chats: laneChats, heads: heads)
                    .padding(.top, StageLayout.labelHeight + StageLayout.labelGap)
                    .frame(width: laneWidth, alignment: .leading)
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
    /// The ray each agent at work holds on the run's mark, by its id.
    let rays: [String: Int]
    let color: Color
    let agentChats: [String: Chat]
    let cwd: String
    /// The task each recipient of a hop opens in its well.
    let wells: [String: AttributedString]
    /// The recipients whose wells' words have faded, and those whose wells' room has closed.
    let faded: Set<String>
    let folded: Set<String>
    /// The task each source of a hop handed its words to.
    let handed: [String: String]
    /// The ask each agent waits on, by its id.
    let asks: [String: PendingAsk]
    /// The ask Return answers.
    let listening: String?
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
            // One layout either way, so cards going from side by side to stacked as their phase
            // finishes move to their places rather than fade out over the next phase's cards.
            let layout = phase.sideBySide ? AnyLayout(HStackLayout(alignment: .top, spacing: StageLayout.spacing))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: StageLayout.spacing))
            layout { cards }
        }
        .frame(width: phase.width, alignment: .leading)
    }

    private var cards: some View {
        ForEach(Array(phase.agents.enumerated()), id: \.offset) { _, agent in
            StageCard(agent: agent, chat: agent.id.flatMap { agentChats[$0] }, ray: agent.id.flatMap { rays[$0] },
                      color: color, steps: steps, collapsed: phase.collapsed, cwd: cwd,
                      well: agent.id.flatMap { wells[$0] }, faded: agent.id.map(faded.contains) ?? false, folded: agent.id.map(folded.contains) ?? false, handed: agent.id.flatMap { handed[$0] },
                      ask: agent.id.flatMap { asks[$0] }, listening: listening, lead: lead)
                // A card coming into a phase waits for the phases to have sprung to their new
                // widths, so it never fades in over a card still at its old one.
                .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.28)), removal: .opacity))
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
    /// Its well folds away: its words fade, then its room closes over them.
    let faded: Bool
    let folded: Bool
    /// The task that took its words, while that hop is drawn.
    let handed: String?
    /// What it waits on you for, under its trail.
    let ask: PendingAsk?
    /// The ask Return answers.
    let listening: String?
    /// The thread whose stage it is.
    let lead: UUID
    @Environment(\.stageSpace) private var space

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                StageMark(state: agent.state, ray: ray, color: color, asking: ask != nil)
                    .frame(width: 14, height: 14)
                    .stageMatched(agent.id.map { StageMark.matchID($0) } ?? "", in: agent.id == nil ? nil : space)
                Text(agent.label)
                    .font(Type.mono)
                    .foregroundStyle(agent.state == .queued ? Ink.faint : agent.state == .running ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
            }
            .frame(height: StageLayout.cardHead)
            if !collapsed, let well {
                // The trail stays laid out under it, so folding only closes the room above the trail.
                WellText(text: well, lines: StageLayout.wellLines)
                    .padding(.vertical, StageLayout.wellPadding.height)
                    .padding(.horizontal, StageLayout.wellPadding.width)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
                    .opacity(faded ? 0 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(height: folded ? 0 : nil, alignment: .top)
                    .clipped()
                    .padding(.top, folded ? 0 : StageLayout.wellGap)
                    .transition(.opacity)
            }
            if !collapsed {
                switch agent.state {
                case .running where steps > 0 || ask != nil:
                    // An ask coming or answered changes the card under its head at once: what was
                    // there goes before the rest comes, in the same place, so no line is read over another.
                    ZStack(alignment: .topLeading) {
                        working
                            .id(ask?.requestId)
                            .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                    }
                    // What goes doesn't hang past the card as it closes up.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .transition(Self.swap)
                case .done:
                    line(chat?.agentResult ?? chat.flatMap { model.stage.trail(for: $0.id).result }.flatMap(AppModel.replyLine))
                case .failed:
                    line(agent.error ?? chat?.agentResult)
                default:
                    EmptyView()
                }
            }
        }
        // A card narrowing as its phase finishes keeps what's leaving inside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .padding(.top, StageLayout.cardTop)
        .padding(.horizontal, StageLayout.cardSide)
        .padding(.bottom, StageLayout.cardBottom)
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
        .animation(Motion.fade, value: ask?.requestId)
    }

    /// A running agent's trail, and what it asks under it, faded, while it waits on you.
    @ViewBuilder
    private var working: some View {
        let trail = chat.map { model.stage.trail(for: $0.id) }
        // No room is kept for a trail before its first call has landed.
        let any = !(trail?.steps.isEmpty ?? true) || ask == nil && fallback != nil
        VStack(alignment: .leading, spacing: 0) {
            if steps > 0, any, ask == nil || !TrailLines.before(ask, in: trail?.steps ?? []).isEmpty {
                TrailLines(trail: trail, fallback: ask == nil ? fallback : nil, steps: steps, cwd: cwd, asked: ask)
                    .padding(.top, StageLayout.trailGap)
            }
            if let ask {
                AskForm(ask: ask, cwd: cwd, thread: lead, listens: ask.requestId == listening, titled: false)
                    .padding(.top, StageLayout.askGap)
            }
        }
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
                .transition(Self.swap)
        }
    }

    /// The trail giving way to the result as the agent ends, or the other way: what was there goes
    /// before the rest comes, so no line is read over another.
    private static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)),
                                                       removal: .opacity.animation(.easeOut(duration: 0.1)))

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
        return ToolSummary.line(for: ToolCall(toolUseId: "", name: tool, input: input), cwd: cwd, past: true)
    }

    private var tint: Double {
        switch agent.state {
        case .running: ask == nil ? 0.05 : 0.07
        case .done, .failed: 0.035
        case .queued: 0.025
        }
    }

}

/// An agent's mark on the stage, by its state: its own ray turning while it works, a dot once it's
/// over, faint while it waits its turn.
struct StageMark: View {
    let state: WorkflowRun.Agent.State
    /// The ray it holds on the run's mark while it works.
    let ray: Int?
    let color: Color
    /// It waits on you, which its dot pulses for.
    var asking = false
    /// Stopped before it was done, which its dot says fainter.
    var stopped = false

    static func matchID(_ agent: String) -> String { "mark:" + agent }

    var body: some View {
        switch state {
        case .done where stopped:
            RaysMark(restingOpacity: 0.16, dotOpacity: 0.28)
        case .running:
            RaysMark(slots: ray.map { [$0] } ?? [], turning: ray != nil, waiting: asking, restingOpacity: 0.16,
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
    /// What the thread set going besides the run, one group after the phases'.
    var lane: [LaneCard] = []
    var laneChats: [UUID: Chat] = [:]
    let stepped: String
    let rays: [String: Int]
    let color: Color
    let agentChats: [String: Chat]
    let lead: UUID
    /// The agents waiting on you, whose marks pulse.
    let asking: Set<String>

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Array(phases.filter { !$0.agents.isEmpty }.enumerated()), id: \.element.name) { _, phase in
                HStack(spacing: 2) {
                    ForEach(Array(phase.agents.enumerated()), id: \.offset) { _, agent in
                        capsule(agent)
                    }
                }
            }
            if !lane.isEmpty {
                HStack(spacing: 2) {
                    ForEach(lane) { card in
                        capsule(card)
                    }
                }
            }
        }
    }

    private func capsule(_ card: LaneCard) -> some View {
        let chat = card.thread.flatMap { laneChats[$0] }
        let key = card.key(chat)
        let selected = key != nil && key == stepped
        return HStack(spacing: 9) {
            LaneMark(card: card, state: card.shown(chat))
                .frame(width: 14, height: 14)
                .stageMatched(key.map { StageMark.matchID($0) } ?? "", in: key == nil ? nil : space)
            if selected {
                Text(card.label)
                    .font(card.kind == .command ? Type.mono : LaneCard.labelFont)
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
        .help(card.label)
    }

    private func capsule(_ agent: WorkflowRun.Agent) -> some View {
        let selected = agent.id == stepped
        let chat = agent.id.flatMap { agentChats[$0] }
        return HStack(spacing: 9) {
            StageMark(state: agent.state, ray: agent.id.flatMap { rays[$0] }, color: color,
                      asking: agent.id.map(asking.contains) ?? false)
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
struct AgentSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let stepped: StageModel.Stepped
    /// What the agent waits on you for, under its transcript.
    let ask: PendingAsk?
    /// The thread whose stage it is, which the ask is answered in.
    let lead: Chat
    let listens: Bool

    static func matchID(_ agent: String) -> String { "card:" + agent }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .stageMatched(Self.matchID(stepped.agent), in: space)
            VStack(spacing: 0) {
                // Across to another agent, one transcript goes before the next comes, so no line is
                // read over another.
                if let conversation = model.conversations[stepped.thread] {
                    TranscriptView(conversation: conversation, cwd: conversation.chat.cwd, active: false, stepped: true)
                        .id(stepped.thread)
                        .transition(.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)), removal: .opacity.animation(.easeOut(duration: 0.1))))
                }
                if let ask {
                    AskForm(ask: ask, cwd: lead.cwd, thread: lead.id, listens: listens, titled: false)
                        .column()
                        .padding(.vertical, StageLayout.cardSide)
                        .id(ask.requestId)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: ask?.requestId)
        }
    }
}

/// A running agent's last calls, the one it's on in ink and up to three before it fading under it.
/// A view of its own over its trail alone, so a call coming in draws these lines and nothing else.
struct TrailLines: View {
    let trail: StageModel.Trail?
    let fallback: String?
    let steps: Int
    let cwd: String
    /// What the agent waits on you for: the call it holds is the ask's to show, and the calls
    /// before it fade under the question.
    var asked: PendingAsk? = nil

    static let inks: [Double] = [0.92, 0.55, 0.38, 0.24]

    var body: some View {
        let all = Self.before(asked, in: trail?.steps ?? [])
        let first = trail?.first ?? 0
        let inks = asked == nil ? Self.inks : Array(Self.inks.dropFirst())
        let shown: [(id: Int, words: AttributedString)] = all.isEmpty
            ? fallback.map { [(id: -1, words: AttributedString($0))] } ?? []
            : all.enumerated().suffix(min(steps, inks.count)).reversed().map { index, step in
                (first + index, Self.words(step, cwd: cwd))
            }
        VStack(alignment: .leading, spacing: StageLayout.stepGap) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { place, step in
                Text(step.words)
                    .font(place == 0 && asked == nil ? Type.body : Type.secondary)
                    .foregroundStyle(Color.white.opacity(inks[min(place, inks.count - 1)]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // In once the lines under it have moved down out of its way.
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).animation(Motion.fade.delay(0.1)), removal: .opacity))
            }
        }
        // As tall as the lines it shows, so the oldest going doesn't make the card taller for a
        // moment, which moved the lead's transcript under the stage with every call.
        .frame(height: StageLayout.trailHeight(shown.count, first: asked == nil), alignment: .top)
        // The oldest leaves under the trail's foot; the newest comes in from above whole.
        .mask(Rectangle().padding(.top, -8))
        // A fade's length and not the spring's: with four agents at work a call lands every
        // quarter second or so, and a spring still settling under the next kept frames coming.
        .animation(Motion.fade, value: shown.map(\.id))
    }

    /// The calls before the one an ask holds, which the agent's transcript has before it's answered.
    static func before(_ ask: PendingAsk?, in steps: [StageModel.Step]) -> [StageModel.Step] {
        guard let ask, let last = steps.last, last.tool == ask.tool, last.input == ask.input else { return steps }
        return Array(steps.dropLast())
    }

    /// A call as the transcript says it, with a file's folder after its name in faint ink: "Read
    /// Cache.swift Sources/Store". A command reads "Ran" on every line, the one it's on too, so
    /// the trail keeps one tense and nothing on a card reads as asked of you.
    static func words(_ step: StageModel.Step, cwd: String) -> AttributedString {
        words(ToolCall(toolUseId: "", name: step.tool, input: step.input), cwd: cwd)
    }

    static func words(_ call: ToolCall, cwd: String) -> AttributedString {
        let line = ToolSummary.line(for: call, cwd: cwd, past: true)
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
        /// Every hop into its phase has settled, so it fades.
        let settled: Bool

        /// Where it's drawn, which changes as the cards it joins move.
        var points: [CGFloat] {
            [node.x, node.y] + (ins + outs.map(\.wire)).flatMap { [$0.from.x, $0.from.y, $0.to.x, $0.to.y] }
        }
    }

    /// The cards' bounds are where the cards end up, not where they are while they spring: so the
    /// wires come only once the cards have been still for a spring's length, and go at once when
    /// the cards move again.
    @State private var still: [CGFloat]?

    var body: some View {
        let wirings = Dictionary(grouping: hops, by: \.phase).keys.sorted().compactMap { wiring($0) }
        let points = wirings.flatMap(\.points)
        let shown = still == points
        ZStack(alignment: .topLeading) {
            // Something always here, so the wait below runs while no wire is drawn.
            Color.clear
            ForEach(shown ? wirings : []) { wiring in
                WiringView(wiring: wiring)
                    .transition(.identity)
            }
        }
        .allowsHitTesting(false)
        .task(id: points) {
            guard !points.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(320))
            if !Task.isCancelled { still = points }
        }
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
            },
            settled: into.allSatisfy(\.settled))
    }
}

/// A phase's hop drawn: its wires, the script's node and the spark. It fades in as it comes and
/// out as its hop settles; moved, it's gone at once, since its place is the cards' old one.
private struct WiringView: View {
    let wiring: HopsDrawing.Wiring
    @State private var appeared = false

    var body: some View {
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
                .frame(width: HopsDrawing.node, height: HopsDrawing.node)
                .position(wiring.node)
            ForEach(wiring.outs, id: \.recipient) { out in
                SparkRun(recipient: out.recipient, wire: out.wire)
            }
        }
        .opacity(appeared && !wiring.settled ? 1 : 0)
        .onAppear { withAnimation(Motion.fade) { appeared = true } }
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
                // The wires come once the gutter has opened under them.
                withAnimation(.easeOut(duration: 0.6)) { t = 1 }
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
    /// From an asking card's trail to its ask, and from the command's well to its answers.
    static let askGap: CGFloat = 12
    static let answersGap: CGFloat = 10
    static let answersHeight: CGFloat = 30
    /// The most of a command an ask's well shows before it scrolls: eight lines of mono.
    static let askTallest = ceil(NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12.5, weight: .regular))) * 8
    /// A line of body type and one of secondary, as Text lays them out.
    static let bodyLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14)))
    static let secondaryLine = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12.5)))

    let phases: [Phase]
    /// The space before each phase, none before the first.
    let gutters: [CGFloat]
    /// How much each recipient's well adds to its card, by its agent's id.
    let wells: [String: CGFloat]
    /// How much each asking agent's ask adds to its card, by its id.
    let asks: [String: CGFloat]

    var widths: [CGFloat] { phases.map(\.width) + gutters }

    /// `equal` gives every phase reached an equal share, for a run called up again once over;
    /// `wide` names the phases a hop goes into, whose gutter widens; `wells` the tasks shown in
    /// wells; `asks` the commands the agents asking wait on you to run.
    init(groups: [(phase: String, agents: [WorkflowRun.Agent])], width: CGFloat, narrow: Bool, equal: Bool = false,
         wide: Set<Int> = [], wells: [String: AttributedString] = [:], asks: [String: String] = [:]) {
        gutters = groups.indices.map { $0 == 0 ? 0 : wide.contains($0) ? Self.wideGutter : Self.gutter }
        let states: [State] = groups.map { group in
            if group.agents.isEmpty { return .ahead }
            return group.agents.allSatisfy { $0.state == .done || $0.state == .failed } ? .finished : .live
        }
        let fixed: [CGFloat?] = zip(groups, states).map { group, state in
            switch state {
            case .ahead: ceil(Self.labelWidth(group.phase)) + Self.labelInset
            case .finished: equal ? nil : narrow ? Self.collapsedFinished : Self.finished
            case .live: nil
            }
        }
        let shared = fixed.count { $0 == nil }
        let left = width - fixed.compactMap { $0 }.reduce(0, +) - gutters.reduce(0, +)
        // Narrow, a live phase takes what's left down to a stacked card of 160pt.
        let share = shared == 0 ? 0 : equal ? max(left / CGFloat(shared), 0) : max(left / CGFloat(shared), narrow ? Self.leastNarrow : Self.leastCard)
        phases = zip(groups, zip(states, fixed)).map { group, entry in
            let (state, fixed) = entry
            let count = CGFloat(max(group.agents.count, 1))
            var width = fixed ?? (equal ? share : min(share, count * Self.card + (count - 1) * Self.spacing))
            // A finished phase stacks its cards, a result line each, in its 250pt; on equal shares
            // any phase sits its cards side by side while each has 240pt.
            let sideBySide = (state == .live || equal && state == .finished) && (width - (count - 1) * Self.spacing) / count >= Self.leastCard
            if state == .live, !sideBySide, !equal { width = min(width, Self.card) }
            return Phase(name: group.phase, agents: group.agents, state: state, width: width, sideBySide: sideBySide,
                         collapsed: narrow && state == .finished)
        }
        var heights: [String: CGFloat] = [:]
        var asked: [String: CGFloat] = [:]
        for phase in phases where !phase.collapsed {
            let count = CGFloat(phase.agents.count)
            let card = phase.sideBySide ? (phase.width - (count - 1) * Self.spacing) / count : phase.width
            let inside = card - Self.cardSide * 2 - Self.wellPadding.width * 2
            func tall(_ text: String, _ font: NSFont) -> CGFloat {
                ceil((text as NSString).boundingRect(with: CGSize(width: inside, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
            }
            for agent in phase.agents {
                guard let id = agent.id else { continue }
                if let task = wells[id] {
                    heights[id] = Self.wellGap + Self.wellPadding.height * 2 + WellText.height(task, width: inside, lines: Self.wellLines)
                }
                if let command = asks[id] {
                    let well = min(tall(command, .monospacedSystemFont(ofSize: 12.5, weight: .regular)), Self.askTallest)
                    asked[id] = Self.askGap + Self.wellPadding.height * 2 + well + Self.answersGap + Self.answersHeight
                }
            }
        }
        self.wells = heights
        self.asks = asked
    }

    /// The layout for `width`, narrow when the phases wouldn't fit across it otherwise: three phases
    /// in a column beside another thread don't at 250pt a finished one. A run whose every phase
    /// is over takes equal shares first, which keep each card's result line.
    static func fitted(groups: [(phase: String, agents: [WorkflowRun.Agent])], width: CGFloat, narrow: Bool, equal: Bool = false,
                       wide: Set<Int>, wells: [String: AttributedString], asks: [String: String] = [:]) -> StageLayout {
        let layout = StageLayout(groups: groups, width: width, narrow: narrow, equal: equal, wide: wide, wells: wells, asks: asks)
        guard !narrow, layout.widths.reduce(0, +) > width else { return layout }
        if !equal, !layout.phases.contains(where: { $0.state == .live }) {
            let shared = StageLayout(groups: groups, width: width, narrow: false, equal: true, wide: wide, wells: wells, asks: asks)
            if shared.phases.allSatisfy({ $0.state != .finished || $0.width >= Self.leastNarrow }) { return shared }
        }
        return StageLayout(groups: groups, width: width, narrow: true, equal: equal, wide: wide, wells: wells, asks: asks)
    }

    static func labelWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width
    }

    /// The phases' height, labels and cards, with each running card showing `steps` calls.
    func height(steps: Int) -> CGFloat {
        phases.map { phase in
            let cards = phase.agents.map { agent in
                // An asking card's trail is the calls before the one it asks about, three at most.
                let ask = phase.collapsed ? nil : agent.id.flatMap { asks[$0] }
                return Self.cardHeight(agent, steps: ask == nil ? steps : min(steps, 3), collapsed: phase.collapsed)
                    + (agent.id.flatMap { wells[$0] } ?? 0) + (ask ?? 0)
            }
            guard !cards.isEmpty else { return Self.labelHeight }
            let stacked = phase.sideBySide ? cards.max() ?? 0 : cards.reduce(0, +) + Self.spacing * CGFloat(cards.count - 1)
            return Self.labelHeight + Self.labelGap + stacked
        }.max() ?? 0
    }

    /// The height of a trail of `lines`, its first in body type when `first`, or of a command's in mono.
    static func trailHeight(_ lines: Int, first: Bool = true, mono: Bool = false) -> CGFloat {
        guard lines > 0 else { return 0 }
        let gaps = CGFloat(lines - 1) * stepGap
        if mono { return CGFloat(lines) * LaneLayout.monoLine + gaps }
        return (first ? bodyLine : secondaryLine) + CGFloat(lines - 1) * secondaryLine + gaps
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

/// A workflow call in the transcript: its mark and name, how long it took once it's over, and a
/// chevron that points up at the stage while it's open. A click opens or folds the stage, which
/// grows out of the line and folds back into it.
struct RunLine: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let call: ToolCall
    /// The run's head while it works.
    let head: Head?
    /// The thread it's in, nil where no stage can be called up.
    let thread: UUID?
    /// What a click does in place of opening or folding the stage here: ⌘⇧I's opens the thread.
    var opens: (() -> Void)?

    static func matchID(_ run: String) -> String { "run:" + run }

    var body: some View {
        // On ⌘⇧I it points the way the thread is, never up at a stage that isn't there.
        let open = opens == nil && thread.map { model.stage.shown[$0] == call.toolUseId } ?? false
        // Folded, an agent asking on its card pulses the line's mark.
        let asking = head != nil && !open && thread.flatMap { model.conversations[$0] }?.waitingAsks.contains(where: \.staged) == true
        let script = call.input["script"]?.string ?? ""
        let run = head?.run ?? call.workflow
        let name = run?.name ?? call.input["name"]?.string ?? WorkflowRun.plannedName(in: script) ?? "Workflow"
        let rays = head?.rays ?? []
        Button {
            if let opens {
                opens()
            } else if let thread {
                model.stage.toggle(call.toolUseId, in: thread)
            }
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    RaysMark(slots: Set(rays), turning: !rays.isEmpty, waiting: asking, colors: head.map(MarkPalette.colors(of:)) ?? [:])
                        .frame(width: 16, height: 16)
                    Text(name)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                }
                // Folded, they're here for the stage's head to grow out of; while it's up, its head has them.
                .stageMatched(open ? "line:" + call.toolUseId : Self.matchID(call.toolUseId), in: space)
                if head == nil, let took = run?.took {
                    Text(took)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .transition(.opacity)
                }
                if thread != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                        .rotationEffect(.degrees(open ? -90 : 0))
                }
            }
            .frame(height: 22)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(thread == nil)
        .animation(Motion.move, value: open)
        .animation(Motion.fade, value: head == nil)
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

/// A workflow call in the transcript, its line reading the thread's heads in a view of its own so
/// the transcript never does.
struct WorkflowRow: View {
    let call: ToolCall
    let thread: UUID?
    @Environment(Heads.self) private var heads: Heads?

    var body: some View {
        RunLine(call: call, head: heads?.list.first { $0.call == call.toolUseId && $0.kind == .workflow && !$0.ending }, thread: thread)
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
