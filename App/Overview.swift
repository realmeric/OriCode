import SwiftUI

/// How a thread's latest turn in this launch went: nil while it runs, and once it's over, done,
/// stopped or failed, with the first line of its last reply.
struct Outcome: Equatable {
    enum State: String {
        case done, stopped, failed
    }

    var state: State?
    var line: String?
}

/// A row of the screen of everything running: a thread.
struct OverviewRow: Identifiable {
    let chat: Chat

    var id: UUID { chat.id }
}

/// What a thread set going, as the line its stage folds into: a workflow's run, or the calls that
/// started the cards of its column, "Started 2 agents, ran a command" or "Planned 4 tasks".
enum StageLine: Equatable {
    case run(ToolCall)
    case calls(String)
}

/// One project's plan and rows, under its badge and name.
struct OverviewSection: Identifiable {
    let project: Project
    var plan = ProjectPlan([])
    let rows: [OverviewRow]

    var id: UUID { project.id }
}

/// Where a thread stands, as the screen says it: its mark, a word, and what it's on.
struct OverviewStatus: Equatable {
    enum State: Equatable {
        case working, waiting, queued, done, stopped, failed, idle
    }

    let state: State
    let step: String?

    var word: String {
        switch state {
        case .working: "Working"
        case .waiting: "Waiting"
        case .queued: "Queued"
        case .done: "Done"
        case .stopped: "Stopped"
        case .failed: "Failed"
        case .idle: ""
        }
    }

    /// The word the row draws: working and waiting are its mark's to show, turning or pulsing,
    /// and done is a mark at rest. Queued, stopped and failed are what a mark can't say.
    var shown: String {
        state == .working || state == .waiting || state == .done ? "" : word
    }

    /// At work or waiting on someone, which the row says in full ink.
    var live: Bool {
        state == .working || state == .waiting || state == .queued
    }
}

/// ⌘⇧I: every ask waiting on you, oldest first, then each project's plan and its threads that
/// have worked since OriCode opened, or work or wait now, with where each stands and what it's on,
/// and under it the line of what it set going. It grows out of the title capsule like ⌘I, over both columns, and
/// stops above the composer, which still sends to the open thread. It reads what the app already
/// holds and asks the engine for nothing.
struct Overview: View {
    @Environment(AppModel.self) private var model
    /// How tall it may grow before its rows scroll.
    let tallest: CGFloat
    @State private var hovered: UUID?

    static let width: CGFloat = 640

    /// A row's word and the buttons that take its place under the pointer share one slot: what goes
    /// fades in the first half of Motion.fade's 0.18s, and what comes in the second, so the two
    /// are never drawn over each other.
    static func word(under: Bool) -> Animation {
        under ? .easeIn(duration: 0.09) : .easeOut(duration: 0.09).delay(0.09)
    }

    static let actions = ModeTiles.swap(0.09)

    var body: some View {
        let sections = model.overview
        let asks = model.waitingAsks
        // No title and no tally: the user called it, and each row's mark says how it stands.
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty, asks.isEmpty {
                Text("Nothing running")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            } else {
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if !asks.isEmpty {
                                AskQueue(asks: asks)
                            }
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        ProjectBadge(project: section.project)
                                        Text(section.project.isNoFolder ? Project.noFolderName : section.project.name)
                                            .font(Type.secondary)
                                            .foregroundStyle(Ink.secondary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    if !section.plan.tasks.isEmpty {
                                        PlanLines(plan: section.plan, hovered: $hovered)
                                            .padding(.bottom, section.rows.isEmpty ? 0 : 6)
                                    }
                                    ForEach(section.rows) { row in
                                        OverviewLine(chat: row.chat, hovered: $hovered)
                                    }
                                }
                            }
                        }
                        .padding(6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Never past the composer, which may stand in the middle of the window and grow up.
                    .frame(maxHeight: max(0, tallest))
                    .fixedSize(horizontal: false, vertical: true)
                    // A notification's ask, which may have come below the fold of a long queue.
                    // Once the rows are laid out: on the first pass the queue has no height yet.
                    .onAppear {
                        guard let ask = model.overviewAsk else { return }
                        DispatchQueue.main.async { scroller.scrollTo(ask, anchor: .top) }
                    }
                    .onChange(of: model.overviewAsk) { _, ask in
                        guard let ask else { return }
                        withAnimation(Motion.move) { scroller.scrollTo(ask, anchor: .top) }
                    }
                }
            }
        }
    }


}

/// A thread's row: its mark, its title over what it's on, and where it stands at the end, which
/// gives way to Stop under the pointer while it works, and VoiceOver has it as an action. A click
/// opens it and the screen goes. Under it, the line of what it set going, which opens it with its
/// stage up.
private struct OverviewLine: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    @Binding var hovered: UUID?

    var body: some View {
        let status = model.status(of: chat)
        let under = hovered == chat.id
        let selected = chat.id == model.selectedChatID
        let working = status.state == .working
        let stops = under && working
        let line = model.stageLine(of: chat)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                mark(status)
                    .frame(width: 14, height: 14)
                    // The word at the row's end says it, to VoiceOver alone where the mark shows it.
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.title)
                        .font(Type.body)
                        .foregroundStyle(status.live || selected ? Ink.primary : Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let step = status.step {
                        Text(step)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                ZStack(alignment: .trailing) {
                    Text(status.shown)
                        .accessibilityLabel(status.word)
                        .font(Type.secondary)
                        .foregroundStyle(status.live ? Ink.secondary : Ink.faint)
                        .fixedSize()
                        .opacity(stops ? 0 : 1)
                        .animation(Overview.word(under: stops), value: stops)
                    if stops {
                        Button("Stop") { model.stop(in: chat) }
                            .buttonStyle(.action(small: true))
                            .fixedSize()
                            .transition(Overview.actions)
                    }
                }
            }
            .padding(.vertical, 7)
            .contentShape(.rect)
            .onTapGesture { model.openFromOverview(chat, beside: NSEvent.modifierFlags.contains(.option)) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.openFromOverview(chat, beside: false) }
            .accessibilityActions {
                if working {
                    Button("Stop") { model.stop(in: chat) }
                }
            }
            if let line {
                OverviewStageLine(chat: chat, line: line)
                    .padding(.leading, 24)
                    .padding(.top, -2)
                    .padding(.bottom, 7)
            }
        }
        .padding(.horizontal, 8)
        .background(selected ? Surface.selected : under ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .onHover { inside in
            withAnimation(Motion.fade) { hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
        }
    }

    @ViewBuilder
    private func mark(_ status: OverviewStatus) -> some View {
        // Pulsing where the row reads Waiting: an ask of an agent it set going is in the queue above.
        if let conversation = model.conversations[chat.id], conversation.working || conversation.waitingAsk != nil {
            ThreadMark(conversation: conversation, waiting: status.state == .waiting)
        } else {
            RaysMark(restingOpacity: 0.16, dotOpacity: status.live ? 0.92 : 0.28)
        }
    }
}

/// The line under a row of what its thread set going: RunLine for a run, or the calls' words with
/// RunLine's chevron. A click opens the thread with its stage up, ⌥ beside.
private struct OverviewStageLine: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let line: StageLine

    var body: some View {
        let open = { model.openStage(of: chat, line: line, beside: NSEvent.modifierFlags.contains(.option)) }
        switch line {
        case .run(let call):
            let head = model.conversations[chat.id]?.heads.list.first { $0.call == call.toolUseId && $0.kind == .workflow && !$0.ending }
            RunLine(call: call, head: head, thread: chat.id, opens: open)
        case .calls(let words):
            Button(action: open) {
                HStack(spacing: 6) {
                    Text(words)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.faint)
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .frame(height: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

extension AppModel {
    func toggleOverview() {
        withAnimation(Motion.move) {
            if overviewShown {
                overviewShown = false
                overviewAsk = nil
            } else {
                openInIsland(.overview)
                // Tab's and @'s lists rise into the screen's place, and the composer under it keeps
                // the keyboard, which ⌘K or ⌘P going in the same turn would leave with nobody.
                composerMenu = false
            }
            // Going, from a question's Other field in the queue, it hands the keyboard back too.
            returnKeyboardSoon()
        }
    }

    func closeOverview() {
        guard overviewShown else { return }
        withAnimation(Motion.move) { overviewShown = false }
        overviewAsk = nil
    }

    /// A row's click: that thread opens, or with ⌥ comes beside the open one, and the screen goes.
    func openFromOverview(_ chat: Chat, beside: Bool) {
        if beside {
            openBeside(chat)
        } else {
            select(chat)
        }
        closeOverview()
    }

    /// A line's click: that thread opens with its stage up for what the line stands for.
    func openStage(of chat: Chat, line: StageLine, beside: Bool) {
        openFromOverview(chat, beside: beside)
        switch line {
        case .run(let call): stage.show(call.toolUseId, in: chat.id)
        case .calls: stage.show(StageModel.laneKey, in: chat.id)
        }
    }

    /// Each project's plan while a task of it isn't done or has changed since OriCode opened, and
    /// its threads that work, wait or have had a turn since OriCode opened, under its name in the
    /// projects' order, in the drawer's order and none under another: who opened whom is on each
    /// thread's stage. A workflow's agent, a subagent or a worker has no row. The same rows
    /// whichever thread is open.
    var overview: [OverviewSection] {
        let listed = Chat.inDrawerOrder(projects.flatMap(\.chats).filter { $0.started && !$0.archived && $0.agentID == nil && onOverview($0) })
        return projects.compactMap { project in
            let mine = listed.filter { $0.project?.id == project.id }
            // As a thread is shown while it works or has worked since OriCode opened.
            let plan = ProjectPlan(project)
            let shown = plan.tasks.contains { $0.state != "done" || $0.updatedAt >= openedAt }
            return mine.isEmpty && !shown ? nil : OverviewSection(project: project, plan: shown ? plan : ProjectPlan([]), rows: mine.map { OverviewRow(chat: $0) })
        }
    }

    /// Whether a thread is on the screen of its own accord.
    func onOverview(_ chat: Chat) -> Bool {
        if outcomes[chat.id] != nil || chat.resumeAt != nil { return true }
        guard let conversation = conversations[chat.id] else { return false }
        return conversation.working || conversation.waitingAsk != nil || conversation.waitingAfterQuit
    }

    /// The line a thread's stage folds into, read from its transcript as the store keeps it: the
    /// run at work, or the calls that started what else it has at work, or, with nothing at work,
    /// the latest run since its last message, which a click calls up again from the store. Nil
    /// when it set nothing going, and when what it set going besides a run has ended, whose cards
    /// have gone.
    func stageLine(of chat: Chat) -> StageLine? {
        guard let conversation = conversations[chat.id] else { return nil }
        if let call = conversation.heads.liveWorkflow?.call.flatMap(conversation.call) { return .run(call) }
        let cards = liveLane(of: conversation)
        if !cards.isEmpty {
            var calls: [ToolCall] = []
            var planned = false
            for case .tool(_, let call) in conversation.items.reversed() where call.startsCard && cards.contains(where: { $0.started(by: call) }) {
                // A plan's cards are its latest add_tasks call's.
                if call.oricodeTool == "add_tasks" {
                    if planned { continue }
                    planned = true
                }
                calls.insert(call, at: 0)
            }
            if !calls.isEmpty { return .calls(StageCallsRow.words(calls)) }
        }
        for item in conversation.items.reversed() {
            switch item {
            // The line a quit leaves isn't a message of the user's: the run before it is still the thread's latest.
            case .user(_, let text, _, false) where text != Self.quitLine: return nil
            case .tool(_, let call) where call.kind == .workflow && !call.isError: return .run(call)
            default: continue
            }
        }
        return nil
    }

    /// Where a thread stands and what it's on, from what the app already has: its conversation
    /// while it's in memory, and how its latest turn in this launch ended.
    func status(of chat: Chat) -> OverviewStatus {
        let conversation = conversations[chat.id]
        // An ask of a worker or a subagent is the queue's; the thread that runs it works on.
        // One a thread above answers first isn't waiting on you; the thread works on, asking it.
        if let conversation, conversation.waitingAfterQuit
            || conversation.waitingAsks.contains(where: { asker(of: $0) == nil && holder(of: $0.requestId) == nil }) {
            return OverviewStatus(state: .waiting, step: nil)
        }
        if let held = conversation?.waitingAsks.lazy.compactMap({ self.holder(of: $0.requestId) }).first {
            return OverviewStatus(state: .working, step: "Asking \(held.title)")
        }
        if let conversation, conversation.working {
            // With its turn over, what it left running is its stage's line.
            guard conversation.running else { return OverviewStatus(state: .working, step: nil) }
            let step = conversation.mainStep(cwd: chat.cwd) { self.chat(withID: $0)?.title }
            let line = Self.stepLine(step.tool, step.detail)
            return OverviewStatus(state: .working, step: [conversation.planStep, line.nonEmpty].compactMap { $0 }.joined(separator: " · ").nonEmpty)
        }
        if let resumeAt = chat.resumeAt {
            return OverviewStatus(state: .waiting, step: Limit.time(resumeAt))
        }
        switch outcomes[chat.id]?.state {
        // Finished is the mark at rest and the title; its reply is the thread's to read.
        case .done: return OverviewStatus(state: .done, step: nil)
        case .stopped: return OverviewStatus(state: .stopped, step: outcomes[chat.id]?.line)
        case .failed: return OverviewStatus(state: .failed, step: outcomes[chat.id]?.line)
        case nil: return OverviewStatus(state: .idle, step: nil)
        }
    }

    /// A step as a row says it: the tool and what it's on, "Read · two.txt", and a command alone.
    static func stepLine(_ tool: String, _ detail: String?) -> String {
        if tool == "Bash", let detail = detail?.nonEmpty { return detail }
        return [ToolSummary.name(tool), detail].compactMap { $0 }.joined(separator: " · ")
    }

    /// A turn starting or ending, which puts its thread on the screen of everything running and
    /// says how it ended there.
    func noteOutcome(_ event: EngineEvent, of chat: Chat) {
        switch event.name {
        case "turn.started":
            if outcomes[chat.id] != Outcome() { outcomes[chat.id] = Outcome() }
        case "turn.done":
            let stopReason = event.body["stopReason"]?.string
            let conversation = conversation(for: chat)
            let state: Outcome.State = conversation.endedByItself ? .done
                : stopReason == "interrupted" || stopReason == "engine_stopped" ? .stopped : .failed
            outcomes[chat.id] = Outcome(state: state, line: Self.turnLine(conversation))
        default:
            break
        }
    }

    /// The first line of what the latest turn wrote, or nil when it wrote nothing: a turn stopped
    /// in its first call doesn't say the turn before's reply.
    static func turnLine(_ conversation: Conversation) -> String? {
        let items = conversation.items
        let start = items.lastIndex(where: \.startsTurn).map { $0 + 1 } ?? items.startIndex
        return replyLine(items[start...].last { if case .text = $0 { true } else { false } }?.text)
    }
}
