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

/// One project's rows, under its badge and name.
struct OverviewSection: Identifiable {
    let project: Project
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

    /// At work or waiting on someone, which the row says in full ink.
    var live: Bool {
        state == .working || state == .waiting || state == .queued
    }
}

/// ⌘⇧I: every ask waiting on you, oldest first, then every project's threads that have worked
/// since OriCode opened, or work or wait now, each under the thread that opened it, with where it
/// stands and what it's on. It grows out of the title capsule like ⌘I, over both columns, and
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Everything running")
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                // In a narrow window the tally gives way, its first count and then all of it,
                // and never the name.
                let parts = tally(sections)
                ViewThatFits(in: .horizontal) {
                    Text(parts.joined(separator: ", ")).fixedSize()
                    Text(parts.first ?? "").fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if sections.isEmpty, asks.isEmpty {
                Text("No thread has worked since \(Build.name) opened.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
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
                                    ForEach(section.rows) { row in
                                        OverviewLine(chat: row.chat, depth: row.depth, hovered: $hovered)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Never past the composer, which may stand in the middle of the window and grow up.
                    .frame(maxHeight: max(0, tallest - 44))
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

    /// "2 working", "1 waiting" and "3 ended" across every project.
    private func tally(_ sections: [OverviewSection]) -> [String] {
        let states = sections.flatMap(\.rows).map { model.status(of: $0.chat).state }
        let working = states.count { $0 == .working }
        let waiting = states.count { $0 == .waiting || $0 == .queued }
        let ended = states.count { $0 == .done || $0 == .stopped || $0 == .failed }
        let parts = [(working, "working"), (waiting, "waiting"), (ended, "ended")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts
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
                // The word at the row's end says it.
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
                Text(status.word)
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

    /// A row's click: that thread opens, or with ⌥ comes beside the open one, unfolded in the
    /// drawer, and the screen goes.
    func openFromOverview(_ chat: Chat, beside: Bool) {
        if beside {
            openBeside(chat)
        } else {
            select(chat)
        }
        unfold(toShow: chat.id)
        closeOverview()
    }

    /// The threads the screen lists, each project's under its name in the projects' order: every
    /// thread that works, waits or has had a turn since OriCode opened, every workflow agent this
    /// launch has heard of, and the threads above each of them up to its top thread in the drawer.
    /// The tree is the drawer's: top threads in the drawer's order, each with the threads it
    /// opened under it in the order they were opened. A thread nothing above it has touched isn't
    /// listed; the drawer lists those.
    var overview: [OverviewSection] {
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept: Set<UUID> = []
        for chat in all where onOverview(chat) {
            var at: UUID? = chat.id
            while let id = at, byID[id] != nil, kept.insert(id).inserted {
                at = byID[id]?.openedBy
            }
        }
        guard !kept.isEmpty else { return [] }
        let listed = all.filter { kept.contains($0.id) }
        let opened = Dictionary(grouping: listed.filter { $0.openedBy.map { byID[$0] != nil } == true }) { $0.openedBy! }
        func rows(_ chat: Chat, depth: Int) -> [OverviewRow] {
            let under = (opened[chat.id] ?? []).sorted { $0.createdAt < $1.createdAt }
            return [OverviewRow(chat: chat, depth: depth)] + under.flatMap { rows($0, depth: depth + 1) }
        }
        let tops = listed.filter { $0.openedBy.map { byID[$0] == nil } ?? true }.sorted(by: Chat.drawerOrder)
        return projects.compactMap { project in
            let mine = tops.filter { $0.project?.id == project.id }
            return mine.isEmpty ? nil : OverviewSection(project: project, rows: mine.flatMap { rows($0, depth: 0) })
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
                return OverviewStatus(state: .waiting, step: "Waiting on you")
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
        if let conversation, conversation.waitingAfterQuit
            || conversation.waitingAsks.contains(where: { asker(of: $0) == nil }) {
            return OverviewStatus(state: .waiting, step: "Waiting on you")
        }
        if let conversation, conversation.working {
            let step = conversation.mainStep(cwd: chat.cwd)
            let line = [ToolSummary.name(step.tool), step.detail].compactMap { $0 }.joined(separator: " · ")
            return OverviewStatus(state: .working, step: [conversation.planStep, line].compactMap { $0 }.joined(separator: " · "))
        }
        if let resumeAt = chat.resumeAt {
            return OverviewStatus(state: .waiting, step: "Goes on at \(Limit.time(resumeAt))")
        }
        switch outcomes[chat.id]?.state {
        case .done: return OverviewStatus(state: .done, step: outcomes[chat.id]?.line)
        case .stopped: return OverviewStatus(state: .stopped, step: outcomes[chat.id]?.line)
        case .failed: return OverviewStatus(state: .failed, step: outcomes[chat.id]?.line)
        case nil: return OverviewStatus(state: .idle, step: nil)
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
        return oneLine(items[start...].last { if case .text = $0 { true } else { false } }?.text)
    }
}
