import SwiftUI

/// A thread's mark as its heads light it: the dot while its main loop works, and each agent's
/// ray. The drawer's rows and the title capsule draw it at the same size.
struct ThreadMark: View {
    let conversation: Conversation
    /// Turning and pulsing only where someone can see it.
    var moving = true
    var focus: RaysMark.Focus?

    var body: some View {
        let lit = conversation.heads.lit
        RaysMark(slots: lit, focus: focus, turning: moving && !lit.isEmpty, waiting: moving && conversation.waitingAsk != nil,
                 restingOpacity: 0.28, dotOpacity: conversation.running ? 0.92 : 0.28)
    }
}

/// ⌘I: what each head in the thread is doing, grown out of the title capsule the way ⌘K is. The
/// main loop first, then each head as it came: an agent on its own ray, a workflow with its
/// beads, a command with its last line. Stop is on each row under the pointer, and the row under
/// the pointer brightens its rays in the header's mark.
struct HeadsSurface: View {
    @Environment(AppModel.self) private var model
    let island: Namespace.ID
    @State private var hovered: String?
    /// Rows come in one after another as the surface opens, clockwise like the mark's rays.
    @State private var shown = false

    static let width: CGFloat = 560
    private static let tallest: CGFloat = 420
    static let main = "main"
    /// The mark the capsule holds, which moves into the header as the surface grows.
    static let mark = "mark"

    var body: some View {
        if let chat = model.chat, let conversation = model.currentConversation {
            let heads = conversation.heads
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ThreadMark(conversation: conversation, focus: focus(in: heads))
                        .frame(width: 18, height: 18)
                        .matchedGeometryEffect(id: HeadsSurface.mark, in: island)
                    Text(chat.title)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(tally(heads))
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .contentTransition(.numericText())
                        .animation(Motion.fade, value: tally(heads))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                ScrollView {
                    VStack(spacing: 2) {
                        MainRow(conversation: conversation, cwd: chat.cwd, hovered: $hovered)
                            .arriving(0, shown: shown)
                        ForEach(Array(heads.list.enumerated()), id: \.element.id) { index, head in
                            HeadRow(head: head, chat: chat, hovered: $hovered)
                                .arriving(index + 1, shown: shown)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: Self.tallest)
                .fixedSize(horizontal: false, vertical: true)
            }
            .onAppear { shown = true }
        }
    }

    private func focus(in heads: Heads) -> RaysMark.Focus? {
        guard let hovered else { return nil }
        if hovered == Self.main { return .dot }
        return heads.list.first { $0.id == hovered }.map { .rays(Set($0.rays)) }
    }

    /// "2 agents, 1 command", or the main loop alone.
    private func tally(_ heads: Heads) -> String {
        let live = heads.list.filter { !$0.ending }
        let agents = live.count { $0.kind == .agent }
        let workflows = live.count { $0.kind == .workflow }
        let commands = live.count { $0.kind == .command }
        let others = live.count { $0.kind == .other }
        let parts = [(agents, "agent", "agents"), (workflows, "workflow", "workflows"), (commands, "command", "commands"), (others, "task", "tasks")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        return parts.isEmpty ? "Main loop only" : parts.joined(separator: ", ")
    }
}

/// The main loop: the dot alone lit, and what it's on.
private struct MainRow: View {
    @Environment(AppModel.self) private var model
    let conversation: Conversation
    let cwd: String
    @Binding var hovered: String?

    var body: some View {
        let step = conversation.mainStep(cwd: cwd)
        HeadLine(id: HeadsSurface.main, hovered: $hovered, stop: conversation.running ? { model.stop() } : nil) {
            RaysMark(restingOpacity: 0.16, dotOpacity: conversation.running ? 0.92 : 0.3)
        } title: {
            Text("Main loop")
                .font(Type.body)
                .foregroundStyle(conversation.running ? Ink.primary : Ink.secondary)
        } detail: {
            StepText(step: step)
        } trailing: {
            EmptyView()
        }
    }
}

private struct HeadRow: View {
    @Environment(AppModel.self) private var model
    let head: Head
    let chat: Chat
    @Binding var hovered: String?
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeadLine(id: head.id, hovered: $hovered, stop: head.ending ? nil : { model.stop(head, in: chat) }) {
                icon
            } title: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    if let type = head.type, type != "general-purpose" {
                        Text(type)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                    }
                }
            } detail: {
                detail
            } trailing: {
                HStack(spacing: 10) {
                    if let tools = head.tools, tools > 0 {
                        Text("\(tools) \(tools == 1 ? "tool" : "tools")")
                            .contentTransition(.numericText(value: Double(tools)))
                    }
                    if let tokens = head.tokens, tokens > 0 {
                        Text(tokens.formatted(.number.notation(.compactName)))
                            .contentTransition(.numericText(value: Double(tokens)))
                    }
                    Text(head.startedAt, style: .timer)
                        .monospacedDigit()
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
            }
            .onTapGesture {
                guard head.kind == .workflow, head.run != nil else { return }
                withAnimation(Motion.fade) { open.toggle() }
            }
            if open, let run = head.run {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(run.agents.enumerated()), id: \.offset) { _, agent in
                        AgentLine(agent: agent)
                    }
                }
                .padding(.leading, 44)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        // A head that ended has let its ray go; its row dims, then goes and the list closes up.
        .opacity(head.ending ? 0.35 : 1)
        .animation(Motion.fade, value: head.ending)
    }

    private var title: String {
        if head.kind == .workflow, let name = head.run?.name { return name }
        return head.label.isEmpty ? "Task" : head.label
    }

    @ViewBuilder
    private var icon: some View {
        switch head.kind {
        case .command:
            Text("$")
                .font(Type.mono)
                .foregroundStyle(Ink.secondary)
        case .agent, .workflow, .other:
            RaysMark(slots: head.ending ? [] : Set(head.rays), restingOpacity: 0.16, dotOpacity: 0.28)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch head.kind {
        case .command:
            Text(head.line ?? " ")
                .font(Type.mono)
                .foregroundStyle(Ink.faint)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .animation(Motion.fade, value: head.line)
        case .workflow:
            if let run = head.run {
                HStack(spacing: 10) {
                    Text(WorkflowCard.status(run, groups: WorkflowRun.groups(run.agents, planned: [], reported: run.phases)))
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .lineLimit(1)
                        .fixedSize()
                    Beads(agents: run.agents)
                }
            } else {
                StepText(step: nil)
            }
        case .agent, .other:
            StepText(step: head.step)
        }
    }
}

/// A tool and what it's on, "Read · App/Heads.swift", cross-fading as it moves on.
private struct StepText: View {
    let step: Head.Step?

    var body: some View {
        let text = step.map { [ToolSummary.name($0.tool), $0.detail].compactMap { $0 }.joined(separator: " · ") } ?? "Starting…"
        Text(text)
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentTransition(.opacity)
            .animation(Motion.fade, value: text)
    }
}

/// One row: a mark or a `$`, a title over what it's doing, counts at the end, and Stop in their
/// place under the pointer.
private struct HeadLine<Icon: View, Title: View, Detail: View, Trailing: View>: View {
    let id: String
    @Binding var hovered: String?
    let stop: (() -> Void)?
    @ViewBuilder let icon: Icon
    @ViewBuilder let title: Title
    @ViewBuilder let detail: Detail
    @ViewBuilder let trailing: Trailing

    var body: some View {
        let under = hovered == id
        HStack(spacing: 10) {
            icon
                .frame(width: 14, height: 14)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                trailing.opacity(under && stop != nil ? 0 : 1)
                if under, let stop {
                    Button("Stop", action: stop)
                        .buttonStyle(.plain)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Surface.selected, in: .capsule)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(under ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(Motion.fade) { hovered = inside ? id : (hovered == id ? nil : hovered) }
        }
    }
}

private extension View {
    /// Comes in after the glass has started to grow, each row 40ms after the one before, the
    /// way the mark lights its rays.
    func arriving(_ index: Int, shown: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : -4)
            .animation(Motion.fade.delay(0.08 + Double(min(index, 8)) * 0.04), value: shown)
    }
}

extension AppModel {
    func toggleHeads() {
        withAnimation(Motion.move) {
            if headsShown { headsShown = false } else if chat != nil { openInIsland(.heads) }
        }
    }

    func closeHeads() {
        guard headsShown else { return }
        withAnimation(Motion.move) { headsShown = false }
    }

    /// The engine tells what each head is doing only while its thread's surface is open.
    func watchHeads() {
        let wanted = headsShown ? chat?.id : nil
        guard wanted != headsWatched else { return }
        if let old = headsWatched {
            Task { _ = try? await engine.request("heads.watch", ["threadId": .string(old.uuidString), "on": false]) }
        }
        headsWatched = wanted
        if let wanted {
            Task { _ = try? await engine.request("heads.watch", ["threadId": .string(wanted.uuidString), "on": true]) }
        }
    }

    func stop(_ head: Head, in chat: Chat) {
        Task {
            do {
                _ = try await engine.request("task.stop", ["threadId": .string(chat.id.uuidString), "taskId": .string(head.id)])
            } catch {
                say(error.localizedDescription)
            }
        }
    }
}
