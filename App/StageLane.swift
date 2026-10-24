import AppKit
import SwiftData
import SwiftUI

/// Something a thread set going besides a workflow, as a card in its stage's column: a Task
/// subagent, a worker its head sent out, a command it left running, a task its plan runs or a
/// thread it opened. Each is named by the words given for it, never the start of its task.
struct LaneCard: Identifiable, Equatable {
    enum Kind: Equatable {
        case subagent, worker, command, task, opened
    }

    enum State: Equatable {
        case queued, running, done, failed, stopped
    }

    /// The head's id, or the plan task's, or the opened thread's.
    let id: String
    let kind: Kind
    let label: String
    var state: State
    let startedAt: Date
    /// The call that started a subagent or a command.
    let call: String?
    /// The thread it is, which a click steps into; nil for a command, and for a subagent the
    /// engine hasn't told of yet.
    let thread: UUID?
    /// The agent it runs on, whose colour its mark's ray takes.
    let agent: String
    /// The ray it holds on the thread's mark, or for a thread its place on the column.
    let ray: Int?

    /// The system font's 13pt medium for a description or a title; a command's is mono.
    static let labelFont = Font.system(size: 13, weight: .medium)

    var working: Bool { state == .running || state == .queued }

    /// Whether `call` started it, which makes that call's line stand for its card.
    func started(by call: ToolCall) -> Bool {
        switch kind {
        case .subagent, .command: self.call == call.toolUseId
        case .worker: call.startedWorker == id
        case .task: call.oricodeTool == "add_tasks"
        case .opened: call.oricodeTool == "open_thread" && call.otherThread.id == thread
        }
    }

    /// What a stage stepped into it keeps: an agent's id for its thread, or the thread's own.
    func key(_ chat: Chat?) -> String? {
        guard let chat else { return nil }
        return chat.agentID ?? chat.id.uuidString
    }

    /// How it stands as drawn: a subagent or a worker that ended as its thread says it did.
    func shown(_ chat: Chat?) -> State {
        guard !working, kind == .subagent || kind == .worker, let chat else { return state }
        return switch chat.agentState {
        case "failed": .failed
        case "stopped": .stopped
        default: .done
        }
    }
}

extension Item {
    /// A call that set something going that has a card on the stage.
    var startsCard: Bool {
        if case .tool(_, let call) = self { call.startsCard } else { false }
    }
}

extension AppModel {
    /// What a thread set going that works now, as its column's cards: subagents its Task calls
    /// started and commands it sent to the background, each by the call in its transcript; the
    /// workers its head sent out; every task of a plan it runs while the plan goes on, done ones
    /// with their result; and the threads it opened while they work.
    func liveLane(of conversation: Conversation) -> [LaneCard] {
        let lead = conversation.chat
        var cards: [LaneCard] = []
        let heads = conversation.heads.list.filter { !$0.ending && ($0.kind == .agent || $0.kind == .command) }
        let chats = lead.project?.chats ?? []
        if !heads.isEmpty {
            let agents = chats.filter { $0.openedBy == lead.id && $0.agentID != nil }
            for head in heads {
                if head.worker {
                    let chat = agents.first { $0.agentKind == "worker" && $0.agentTask == head.id }
                    cards.append(LaneCard(id: head.id, kind: .worker, label: head.label, state: .running, startedAt: head.startedAt, call: nil,
                                          thread: chat?.id, agent: head.agent, ray: head.rays.first))
                    continue
                }
                // A head whose call isn't in this transcript is a workflow agent's, on its card.
                guard let id = head.toolUseId, let call = conversation.call(id) else { continue }
                if head.kind == .command {
                    let label = ToolSummary.firstLine(call.shown("command") ?? head.label)
                    cards.append(LaneCard(id: head.id, kind: .command, label: label, state: .running, startedAt: head.startedAt, call: id,
                                          thread: nil, agent: head.agent, ray: nil))
                } else {
                    let chat = agents.first { $0.agentID == head.id }
                    cards.append(LaneCard(id: head.id, kind: .subagent, label: head.label.nonEmpty ?? call.shown("description") ?? "Agent", state: .running,
                                          startedAt: head.startedAt, call: id, thread: chat?.id, agent: head.agent, ray: head.rays.first))
                }
            }
        }
        let tasks = runTasks(of: lead.id)
        let byID = tasks.isEmpty ? [:] : Dictionary(chats.map { ($0.id, $0) }) { first, _ in first }
        let stuck = tasks.contains { $0.state == "stuck" }
        // A plan goes on while a task works, or one waits on tasks that can still be done.
        if tasks.contains(where: { $0.state == "working" || $0.state == "open" && !stuck && !lead.planHeld }) {
            for task in tasks {
                let thread = task.thread.flatMap { byID[$0] }
                let state: LaneCard.State = switch task.state {
                case "working": .running
                case "done": .done
                case "stuck": .failed
                default: .queued
                }
                cards.append(LaneCard(id: task.id.uuidString, kind: .task, label: task.title, state: state,
                                      startedAt: thread?.createdAt ?? .distantFuture.addingTimeInterval(Double(task.number)), call: nil,
                                      thread: thread?.id, agent: task.agent ?? thread?.providerID ?? lead.providerID, ray: nil))
            }
        }
        let planned = Set(tasks.compactMap(\.thread))
        for chat in chats where chat.openedBy == lead.id && chat.agentID == nil && !planned.contains(chat.id) {
            guard conversations[chat.id]?.working == true else { continue }
            cards.append(LaneCard(id: chat.id.uuidString, kind: .opened, label: chat.title, state: .running, startedAt: chat.createdAt, call: nil,
                                  thread: chat.id, agent: chat.providerID, ray: nil))
        }
        // A thread holds no ray on its opener's mark, so it's given one by its place.
        return cards.enumerated().map { index, card in
            guard card.ray == nil, card.kind != .command else { return card }
            return LaneCard(id: card.id, kind: card.kind, label: card.label, state: card.state, startedAt: card.startedAt, call: card.call,
                            thread: card.thread, agent: card.agent, ray: index % RaysMark.rays)
        }
    }

    /// A task's or an opened thread's last reply, its first line: from its conversation when it's
    /// in memory, which has the reply before the store does, else read once off the main thread.
    func readReply(of thread: UUID) async {
        guard stage.replies[thread]?.nonEmpty == nil else { return }
        if let conversation = conversations[thread], let text = Self.lastText(in: conversation) {
            return stage.took(reply: Self.replyLine(text), of: thread)
        }
        let container = context.container
        let reply = await Task.detached(priority: .utility) { OtherThreads.lastReply(of: thread, in: ModelContext(container)) }.value
        stage.took(reply: Self.replyLine(reply), of: thread)
    }

    /// A stage showing a command's card wants its last lines, which the engine sends only while
    /// something watches the thread's heads.
    func watchLaneHeads(_ thread: UUID, _ on: Bool) {
        let changed = on ? laneHeads.insert(thread).inserted : laneHeads.remove(thread) != nil
        if changed { watchHeads() }
    }
}

/// Tells the stage what its thread set going besides a workflow as it comes and goes, from a view
/// of its own, so the transcript never reads the heads, the plan or the opened threads.
struct LaneCue: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    /// The transcript is followed to its end.
    let following: Bool

    var body: some View {
        Color.clear.onChange(of: model.liveLane(of: conversation), initial: true) { _, live in
            model.stage.lane(live, in: conversation.chat.id, grow: following)
        }
    }
}

/// How tall the column's cards are, for the stage's cap.
enum LaneLayout {
    static let monoLine = ceil(NSLayoutManager().defaultLineHeight(for: .monospacedSystemFont(ofSize: 12.5, weight: .regular)))

    static func height(_ cards: [LaneCard], steps: Int) -> CGFloat {
        guard !cards.isEmpty else { return 0 }
        return cards.map { cardHeight($0, steps: steps) }.reduce(0, +) + StageLayout.spacing * CGFloat(cards.count - 1)
    }

    static func cardHeight(_ card: LaneCard, steps: Int) -> CGFloat {
        let head = StageLayout.cardTop + StageLayout.cardHead + StageLayout.cardBottom
        switch card.state {
        case .running where steps > 0:
            if card.kind == .command {
                let lines = CGFloat(min(steps, 3))
                return head + StageLayout.trailGap + lines * monoLine + (lines - 1) * StageLayout.stepGap
            }
            return head + StageLayout.trailGap + StageLayout.bodyLine + CGFloat(steps - 1) * (StageLayout.stepGap + StageLayout.secondaryLine)
        case .done, .failed:
            return head + StageLayout.resultGap + StageLayout.secondaryLine
        default:
            return head
        }
    }
}

/// The column's cards, one under another in the order they started.
struct LaneColumn: View {
    let cards: [LaneCard]
    let steps: Int
    let lead: Chat
    let chats: [UUID: Chat]
    let heads: Heads

    var body: some View {
        VStack(alignment: .leading, spacing: StageLayout.spacing) {
            ForEach(cards) { card in
                LaneCardView(card: card, chat: card.thread.flatMap { chats[$0] }, steps: steps, lead: lead, heads: heads)
            }
        }
        .animation(Motion.move, value: cards.map(\.id))
    }
}

/// A card's mark: its ray turning while it works, a dot once it's over, faint while it waits; a
/// command's "$".
struct LaneMark: View {
    let card: LaneCard
    let state: LaneCard.State

    var body: some View {
        if card.kind == .command {
            Text("$")
                .font(Type.mono)
                .foregroundStyle(Ink.secondary)
        } else {
            let mark: WorkflowRun.Agent.State = switch state {
            case .queued: .queued
            case .running: .running
            case .done, .stopped: .done
            case .failed: .failed
            }
            StageMark(state: mark, ray: card.ray, color: MarkPalette.color(for: card.agent), stopped: state == .stopped)
        }
    }
}

/// One of the column's cards: its mark and label, and under them what it's doing now, the first
/// line of what it returned, or nothing while it waits. No word says its state.
private struct LaneCardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageSpace) private var space
    let card: LaneCard
    let chat: Chat?
    let steps: Int
    let lead: Chat
    let heads: Heads
    /// A command's last lines, kept past its head for its card's line once it ends.
    @State private var lines: [String] = []

    var body: some View {
        let state = card.shown(chat)
        let key = card.key(chat)
        let head = card.kind == .command || card.kind == .subagent ? heads.list.first { $0.id == card.id } : nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                LaneMark(card: card, state: state)
                    .frame(width: 14, height: 14)
                    .stageMatched(key.map { StageMark.matchID($0) } ?? "", in: key == nil ? nil : space)
                Text(card.label)
                    .font(card.kind == .command ? Type.mono : LaneCard.labelFont)
                    .foregroundStyle(state == .queued ? Ink.faint : state == .running ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: StageLayout.cardHead)
            switch state {
            case .running where steps > 0:
                trail(head)
                    .padding(.top, StageLayout.trailGap)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .transition(Self.swap)
            case .done, .failed:
                line(result)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .geometryGroup()
        .clipped()
        .padding(.top, StageLayout.cardTop)
        .padding(.horizontal, StageLayout.cardSide)
        .padding(.bottom, StageLayout.cardBottom)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(tint(state)))
                .stageMatched(key.map { AgentSurface.matchID($0) } ?? "", in: key == nil ? nil : space)
        }
        .contentShape(.rect(cornerRadius: 14, style: .continuous))
        // A click steps into its thread, and with ⌥ opens it beside.
        .onTapGesture {
            guard let chat else { return }
            if NSEvent.modifierFlags.contains(.option) { model.openBeside(chat) } else { model.step(into: chat, of: lead.id) }
        }
        .help(card.label)
        .animation(Motion.fade, value: state)
        .onChange(of: (head?.lines).flatMap { $0.isEmpty ? nil : $0 } ?? head?.line.map { [$0] } ?? [], initial: true) { _, now in
            if !now.isEmpty { lines = now }
        }
        .task(id: state == .done && (card.kind == .task || card.kind == .opened) ? card.thread : nil) {
            if let thread = card.thread, state == .done { await model.readReply(of: thread) }
        }
    }

    /// What it's on: a subagent's last calls from its transcript, a thread's from its own
    /// conversation, a command's last lines.
    @ViewBuilder
    private func trail(_ head: Head?) -> some View {
        switch card.kind {
        case .command:
            CommandTrail(lines: lines, steps: steps)
        case .subagent:
            TrailLines(trail: chat.map { model.stage.trail(for: $0.id) }, fallback: head?.step.map { [$0.tool, $0.detail].compactMap { $0 }.joined(separator: " ") },
                       steps: steps, cwd: lead.cwd)
        case .worker, .task, .opened:
            ThreadTrail(conversation: card.thread.flatMap { model.conversations[$0] }, steps: steps, cwd: lead.cwd)
        }
    }

    private var result: String? {
        switch card.kind {
        case .subagent, .worker: chat?.agentResult
        case .command: lines.last
        // Its conversation has the reply as the turn ends, before the store does.
        case .task, .opened: card.thread.flatMap { thread in
            model.conversations[thread].flatMap(AppModel.lastText).flatMap(AppModel.replyLine) ?? model.stage.replies[thread]?.nonEmpty
        }
        }
    }

    @ViewBuilder
    private func line(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(card.kind == .command ? Type.mono : Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                // Laid out at the card's width from its leading edge as the card springs to a
                // new one, never morphed from the old layout: that drew it centred, or cut
                // mid-word with its ellipsis left at the card's edge.
                .transaction { $0.animation = nil }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, StageLayout.resultGap)
                .transition(Self.swap)
        }
    }

    private static let swap = AnyTransition.asymmetric(insertion: .opacity.animation(Motion.fade.delay(0.1)),
                                                       removal: .opacity.animation(.easeOut(duration: 0.1)))

    private func tint(_ state: LaneCard.State) -> Double {
        switch state {
        case .running: 0.05
        case .done, .failed, .stopped: 0.035
        case .queued: 0.025
        }
    }
}

/// A thread's last calls from its own conversation, the one it's on in ink and up to three before
/// it fading under it. Its own view, so a call coming in draws these lines and nothing else.
private struct ThreadTrail: View {
    let conversation: Conversation?
    let steps: Int
    let cwd: String

    var body: some View {
        let calls = Self.last(conversation?.items ?? [], count: min(steps, TrailLines.inks.count))
        VStack(alignment: .leading, spacing: StageLayout.stepGap) {
            ForEach(Array(calls.enumerated()), id: \.element.id) { place, entry in
                Text(TrailLines.words(entry.call, cwd: cwd))
                    .font(place == 0 ? Type.body : Type.secondary)
                    .foregroundStyle(Color.white.opacity(TrailLines.inks[place]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)).animation(Motion.fade.delay(0.1)), removal: TrailLines.leaving))
            }
        }
        // As tall as the lines it shows: the oldest going leaves under the card's edge.
        .frame(height: StageLayout.trailHeight(calls.count), alignment: .top)
        .clipped()
        .animation(Motion.fade, value: calls.map(\.id))
    }

    /// Its last `count` calls, the latest first.
    static func last(_ items: [Item], count: Int) -> [(id: UUID, call: ToolCall)] {
        var found: [(id: UUID, call: ToolCall)] = []
        for item in items.reversed() {
            guard found.count < count else { break }
            if case .tool(let id, let call) = item, !ToolSummary.harness.contains(call.name) { found.append((id, call)) }
        }
        return found
    }
}

/// A command's last three lines of output, the latest in ink, in mono.
private struct CommandTrail: View {
    let lines: [String]
    let steps: Int

    var body: some View {
        let shown = Array(lines.suffix(min(steps, 3)).reversed())
        VStack(alignment: .leading, spacing: StageLayout.stepGap) {
            ForEach(Array(shown.enumerated()), id: \.offset) { place, line in
                Text(line)
                    .font(Type.mono)
                    .foregroundStyle(Color.white.opacity(TrailLines.inks[place]))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: StageLayout.trailHeight(shown.count, mono: true), alignment: .top)
        .clipped()
    }
}

/// A run of calls that set things going on the stage, or the one call: while any of its cards is
/// there, its words with RunLine's chevron, which opens or folds the stage and points up at the
/// cards while it's open. Once its cards have gone it's the row it always was.
struct StageCallsRow: View {
    @Environment(AppModel.self) private var model
    let items: [Item]
    let cwd: String
    let thread: UUID?
    var live = false
    var stream: LiveText?
    var lit: UUID?

    var body: some View {
        let calls = items.compactMap { item -> ToolCall? in
            if case .tool(_, let call) = item { call } else { nil }
        }
        let lane = thread.flatMap { model.stage.lanes[$0] } ?? []
        if let thread, lane.contains(where: { card in calls.contains(where: card.started(by:)) }) {
            let open = model.stage.shown[thread] != nil
            Button {
                if !model.stage.fold(thread) { model.stage.toggle(StageModel.laneKey, in: thread) }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.words(calls.filter(\.startsCard)))
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                        .rotationEffect(.degrees(open ? -90 : 0))
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .animation(Motion.move, value: open)
        } else if calls.count > 1 {
            ToolRunRow(items: items, cwd: cwd, thread: thread, live: live, stream: stream, lit: lit)
        } else if let call = calls.first {
            if call.oricodeTool != nil {
                ThreadToolLine(call: call, parent: thread)
            } else {
                ToolLine(call: call, cwd: cwd)
            }
        }
    }

    /// "Started 2 agents, ran a command", or one of OriCode's calls in its own words: "Planned 4 tasks".
    static func words(_ calls: [ToolCall]) -> String {
        if calls.count == 1, let call = calls.first, let words = ToolSummary.oricode(call) { return words }
        return ToolSummary.run(calls, starting: true)
    }
}
