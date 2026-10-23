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

/// A row of the screen of everything running: a thread, and how far under its top thread it sits.
struct OverviewRow: Identifiable {
    let chat: Chat
    let depth: Int

    var id: UUID { chat.id }
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

    /// The word the row draws: working and waiting are its mark's to show, turning or pulsing.
    var shown: String {
        state == .working || state == .waiting ? "" : word
    }

    /// At work or waiting on someone, which the row says in full ink.
    var live: Bool {
        state == .working || state == .waiting || state == .queued
    }
}

/// ⌘⇧I: every ask waiting on you, oldest first, then each project's plan and its threads that
/// have worked since OriCode opened, or work or wait now, each under the thread that opened it,
/// with where it stands and what it's on. It grows out of the title capsule like ⌘I, over both columns, and
/// stops above the composer, which still sends to the open thread. It reads what the app already
/// holds and asks the engine for nothing.
struct Overview: View {
    @Environment(AppModel.self) private var model
    /// How tall it may grow before its rows scroll.
    let tallest: CGFloat
    @State private var hovered: UUID?

    static let width: CGFloat = 640
    static let indent: CGFloat = 18

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
                                        OverviewLine(chat: row.chat, depth: row.depth, hovered: $hovered)
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
/// opens it and the screen goes.
private struct OverviewLine: View {
    @Environment(AppModel.self) private var model
    let chat: Chat
    let depth: Int
    @Binding var hovered: UUID?

    var body: some View {
        let status = model.status(of: chat)
        let under = hovered == chat.id
        let selected = chat.id == model.selectedChatID
        let child = depth > 0
        let working = status.state == .working
        let stops = under && working
        // A workflow's agent stops only with its workflow, which Claude Code stops whole.
        let stop = chat.agentStop
        HStack(spacing: 10) {
            mark(status)
                .frame(width: 14, height: 14)
                // The word at the row's end says it, to VoiceOver alone where the mark shows it.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(chat.title)
                    .font(Type.body)
                    .foregroundStyle(status.live || selected ? Ink.primary : Ink.secondary)
                    .opacity(child ? 0.8 : 1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let step = status.step {
                    Text(step)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
                if stops {
                    Button(stop) { model.stop(in: chat) }
                        .buttonStyle(.action(small: true))
                        .fixedSize()
                        .transition(.opacity)
                }
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * Overview.indent)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(
            selected ? (child ? Surface.quietSelected : Surface.selected) : under ? (child ? Surface.quietHover : Surface.hover) : .clear,
            in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { model.openFromOverview(chat, beside: NSEvent.modifierFlags.contains(.option)) }
        .onHover { inside in
            withAnimation(Motion.fade) { hovered = inside ? chat.id : (hovered == chat.id ? nil : hovered) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.openFromOverview(chat, beside: false) }
        .accessibilityActions {
            if working {
                Button(stop) { model.stop(in: chat) }
            }
        }
    }

    @ViewBuilder
    private func mark(_ status: OverviewStatus) -> some View {
        // Pulsing where the row reads Waiting: a worker's ask is its own row's, not its head's.
        if let conversation = model.conversations[chat.id], conversation.working || conversation.waitingAsk != nil {
            ThreadMark(conversation: conversation, waiting: status.state == .waiting)
        } else if chat.agentWorking {
            // A workflow's agent is a main loop of its own, with no rays.
            RaysMark(waiting: status.state == .waiting, restingOpacity: 0.28, dotColor: MarkPalette.color(for: chat.providerID))
        } else {
            RaysMark(restingOpacity: 0.16, dotOpacity: status.live ? 0.92 : 0.28)
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

    /// Each project's plan while a task of it isn't done or has changed since OriCode opened, and
    /// the threads the screen lists, each project's under its name in the projects' order: every
    /// thread that works, waits or has had a turn since OriCode opened, every workflow agent this
    /// launch has heard of, and the threads above each of them up to its top thread in the drawer;
    /// and the open thread's whole tree when it has one, since the drawer lists top threads alone.
    /// Top threads come in the drawer's order, each with the threads it opened under it in the
    /// order they were opened.
    var overview: [OverviewSection] {
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: Set<UUID> = []
        let topOf = topThreads
        if let selectedChatID, let top = topOf[selectedChatID] {
            let tree = all.filter { topOf[$0.id] == top }
            if tree.count > 1 { kept.formUnion(tree.map(\.id)) }
        }
        for chat in all where onOverview(chat) {
            var at: UUID? = chat.id
            while let id = at, byID[id] != nil, kept.insert(id).inserted {
                at = byID[id]?.openedBy
            }
        }
        let listed = all.filter { kept.contains($0.id) }
        let opened = Dictionary(grouping: listed.filter { $0.openedBy.map { byID[$0] != nil } == true }) { $0.openedBy! }
        func rows(_ chat: Chat, depth: Int) -> [OverviewRow] {
            let under = (opened[chat.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            return [OverviewRow(chat: chat, depth: depth)] + under.flatMap { rows($0, depth: depth + 1) }
        }
        let tops = Chat.inDrawerOrder(listed.filter { $0.openedBy.map { byID[$0] == nil } ?? true })
        return projects.compactMap { project in
            let mine = tops.filter { $0.project?.id == project.id }
            // As a thread is shown while it works or has worked since OriCode opened.
            let plan = ProjectPlan(project)
            let shown = plan.tasks.contains { $0.state != "done" || $0.updatedAt >= openedAt }
            return mine.isEmpty && !shown ? nil : OverviewSection(project: project, plan: shown ? plan : ProjectPlan([]), rows: mine.flatMap { rows($0, depth: 0) })
        }
    }

    /// Whether a thread is on the screen of its own accord.
    func onOverview(_ chat: Chat) -> Bool {
        if outcomes[chat.id] != nil || chat.resumeAt != nil { return true }
        if chat.agentState == "running" || chat.agentState == "queued" { return true }
        guard let conversation = conversations[chat.id] else { return false }
        return conversation.working || conversation.waitingAsk != nil || conversation.waitingAfterQuit
    }

    /// Where a thread stands and what it's on, from what the app already has: its conversation
    /// while it's in memory, a workflow agent's state and its workflow's latest snapshot, and
    /// how its latest turn in this launch ended.
    func status(of chat: Chat) -> OverviewStatus {
        if chat.agentID != nil {
            switch chat.agentState {
            // Its ask waits in the thread whose agent runs it, which the answer goes to.
            case "running" where chat.openedBy.flatMap({ conversations[$0] })?.waitingAsks.contains(where: { askers[$0.requestId]?.id == chat.id }) == true:
                return OverviewStatus(state: .waiting, step: nil)
            case "running": return OverviewStatus(state: .working, step: agentStep(chat) ?? "Starting…")
            case "queued": return OverviewStatus(state: .queued, step: nil)
            case "done": return OverviewStatus(state: .done, step: chat.agentResult)
            case "failed": return OverviewStatus(state: .failed, step: chat.agentResult)
            case "stopped": return OverviewStatus(state: .stopped, step: nil)
            default: return OverviewStatus(state: .idle, step: nil)
            }
        }
        let conversation = conversations[chat.id]
        // A worker's or subagent's ask is its own row's; the thread that runs it works on.
        // One a thread above answers first isn't waiting on you; the thread works on, asking it.
        if let conversation, conversation.waitingAfterQuit
            || conversation.waitingAsks.contains(where: { asker(of: $0) == nil && holder(of: $0.requestId) == nil }) {
            return OverviewStatus(state: .waiting, step: nil)
        }
        if let held = conversation?.waitingAsks.lazy.compactMap({ self.holder(of: $0.requestId) }).first {
            return OverviewStatus(state: .working, step: "Asking \(held.title)")
        }
        if let conversation, conversation.working {
            // With its turn over, only how far what it left running is, where that can tell.
            guard conversation.running else { return OverviewStatus(state: .working, step: goingOn(chat)) }
            let step = conversation.mainStep(cwd: chat.cwd)
            let line = [ToolSummary.name(step.tool), step.detail].compactMap { $0 }.joined(separator: " · ")
            return OverviewStatus(state: .working, step: [conversation.planStep, line].compactMap { $0 }.joined(separator: " · "))
        }
        if let resumeAt = chat.resumeAt {
            return OverviewStatus(state: .waiting, step: Limit.time(resumeAt))
        }
        // A plan it runs goes on while a task's thread works, which its line says over the turn's.
        let going = goingOn(chat)
        switch outcomes[chat.id]?.state {
        case .done: return OverviewStatus(state: .done, step: going ?? outcomes[chat.id]?.line)
        case .stopped: return OverviewStatus(state: .stopped, step: going ?? outcomes[chat.id]?.line)
        case .failed: return OverviewStatus(state: .failed, step: going ?? outcomes[chat.id]?.line)
        case nil: return OverviewStatus(state: .idle, step: going)
        }
    }

    /// A workflow agent's last tool, from its workflow's latest snapshot in the thread that runs it.
    /// A worker's step is its own transcript's, which comes as it works, and a subagent's the one
    /// ⌘I last heard for it in the thread that started it.
    private func agentStep(_ chat: Chat) -> String? {
        if chat.agentKind != nil {
            if let conversation = conversations[chat.id], conversation.running {
                let step = conversation.mainStep(cwd: chat.cwd)
                return [ToolSummary.name(step.tool), step.detail].compactMap { $0 }.joined(separator: " · ")
            }
            guard let parent = chat.openedBy, let task = chat.agentTask,
                  let step = conversations[parent]?.heads.list.first(where: { $0.id == task })?.step
            else { return nil }
            return [ToolSummary.name(step.tool), step.detail].compactMap { $0 }.joined(separator: " · ")
        }
        guard let parent = chat.openedBy, let task = chat.agentTask, let id = chat.agentID,
              let run = conversations[parent]?.heads.list.first(where: { $0.id == task })?.run,
              let agent = run.agents.first(where: { $0.id == id }),
              let tool = agent.lastTool
        else { return nil }
        return [ToolSummary.name(tool), agent.lastDetail].compactMap { $0 }.joined(separator: " · ")
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
