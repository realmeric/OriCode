import SwiftData
import SwiftUI

/// A workflow's agents as threads under the thread that started it: each made as its workflow
/// first names it, kept up with each snapshot, its transcript read from Claude Code's copy while
/// it's on the glass, and left folded with its result once the run is over.
extension AppModel {
    /// The workflow's agents as its latest `workflow` event tells them. One still queued has no id
    /// yet and comes once it starts.
    func syncAgents(of parent: Chat, _ body: JSON) {
        guard let project = parent.project, let taskId = body["taskId"]?.string else { return }
        let run = body["state"]?.string ?? "running"
        let folder = body["transcriptDir"]?.string
        var kept: [String: Chat] = [:]
        for chat in project.chats where chat.openedBy == parent.id {
            if let id = chat.agentID { kept[id] = chat }
        }
        var changed = false
        for agent in body["agents"]?.array ?? [] {
            guard let id = agent["agentId"]?.string else { continue }
            let chat: Chat
            if let found = kept[id] {
                chat = found
            } else {
                chat = Chat(project: project, title: agent["label"]?.string ?? "Agent", permissionMode: parent.permissionMode)
                chat.cwd = parent.cwd
                chat.provider = parent.provider
                chat.started = true
                chat.titleIsCustom = true
                chat.openedBy = parent.id
                chat.agentID = id
                chat.agentTask = taskId
                context.insert(chat)
                kept[id] = chat
                changed = true
            }
            let state = Self.agentState(agent["state"]?.string, run: run)
            let result = Self.oneLine(state == "failed" ? agent["error"]?.string : agent["result"]?.string)
            let transcript = folder.map { "\($0)/agent-\(id).jsonl" }
            if chat.agentState != state { chat.agentState = state; changed = true }
            if let result, chat.agentResult != result { chat.agentResult = result; changed = true }
            if let transcript, chat.agentTranscript != transcript { chat.agentTranscript = transcript; changed = true }
            if let model = agent["model"]?.string, chat.model != model { chat.model = model; changed = true }
            // Heard of in this launch, so the screen of everything running lists it.
            if outcomes[chat.id] == nil { outcomes[chat.id] = Outcome() }
        }
        guard changed else { return }
        save()
        followAgents()
    }

    /// An agent's state for its thread: one the run left at work when it ended was stopped with it.
    static func agentState(_ state: String?, run: String) -> String {
        let state = state ?? "queued"
        guard run != "running", state == "queued" || state == "running" else { return state }
        return "stopped"
    }

    /// What the drawer's row says under the title: the first line, cut where the row would.
    static func oneLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).lazy.map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return String(line.prefix(200))
    }

    /// Agents a run was at work on when OriCode quit or its engine went: they went with it.
    func settleAgents() {
        let open = (try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.agentState == "running" || $0.agentState == "queued" }))) ?? []
        guard !open.isEmpty else { return }
        for chat in open {
            chat.agentState = "stopped"
            // Stopped by this launch, at its start or with the engine, so the screen lists it.
            outcomes[chat.id] = Outcome()
        }
        save()
    }

    /// The engine reads an agent's transcript only while its thread is on the glass, from where the
    /// thread's stored copy ends.
    func followAgents() {
        guard engineState == .ready else { return }
        let wanted = Set([selectedChatID, besideChatID].compactMap { $0 }.filter { chat(withID: $0)?.agentTranscript != nil })
        // A read cut off between its pieces starts again from the stored copy.
        for id in followed.symmetricDifference(wanted) { heldPieces[id] = nil }
        for id in followed.subtracting(wanted) {
            Task { _ = try? await engine.request("agent.follow", ["threadId": .string(id.uuidString), "path": "", "from": 0, "on": false]) }
        }
        for id in wanted.subtracting(followed) {
            guard let chat = chat(withID: id), let path = chat.agentTranscript else { continue }
            let params: JSON = ["threadId": .string(id.uuidString), "path": .string(path), "from": .number(Double(chat.agentRead)), "on": true]
            Task { _ = try? await engine.request("agent.follow", params) }
        }
        followed = wanted
    }

    /// A piece of an agent's transcript, taken only where the stored copy ends: a piece read twice,
    /// by a follow that ended and began again, would show twice. A read that comes in pieces is
    /// held until its last and shown and saved at once: each piece shown alone laid the whole
    /// transcript out again.
    func transcribed(_ body: JSON, into chat: Chat) {
        if body["gone"]?.bool == true, chat.agentRead == 0 {
            say("Claude Code no longer keeps this agent's transcript")
            return
        }
        let held = heldPieces[chat.id]
        guard let from = body["from"]?.int, from == held?.offset ?? chat.agentRead, let offset = body["offset"]?.int else { return }
        let events = (held?.events ?? []) + (body["events"]?.array ?? [])
        guard body["more"]?.bool != true else {
            heldPieces[chat.id] = (offset, events)
            return
        }
        heldPieces[chat.id] = nil
        chat.agentRead = offset
        conversation(for: chat).transcribe(events)
    }

    /// Claude Code stops a workflow whole: an agent's own stop says it worked and leaves the agent
    /// going. So an agent's Stop is its workflow's, and its thread says so beside the button.
    func stopWorkflow(of agent: Chat) {
        guard let parent = agent.openedBy, let task = agent.agentTask else { return }
        Task {
            do {
                _ = try await engine.request("task.stop", ["threadId": .string(parent.uuidString), "taskId": .string(task)])
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    /// Whether the workflow a thread's CLI runs, or the one an agent's thread is part of, is still
    /// at work. Archiving the thread would let its CLI go and the run with it, between agents as
    /// much as during one, and an agent's row taken away would come back with the next snapshot.
    func workflowRuns(in chat: Chat) -> Bool {
        guard let parent = chat.openedBy, let task = chat.agentTask else {
            return conversations[chat.id]?.heads.workflowRuns() == true
        }
        return chat.agentWorking || conversations[parent]?.heads.workflowRuns(task) == true
    }

    /// The workflow agents under a thread that goes, which nothing else writes or reads.
    func agents(under chat: Chat) -> [Chat] {
        chat.project?.chats.filter { $0.openedBy == chat.id && $0.agentID != nil } ?? []
    }
}

extension Chat {
    var agentWorking: Bool { agentState == "running" }

    /// The row's second line for a workflow agent: its result once it has one, and how it ended.
    var agentLine: String? {
        switch agentState {
        case "done": agentResult ?? "Done"
        case "failed": "Failed" + (agentResult.map { ": \($0)" } ?? "")
        case "stopped": "Stopped"
        default: nil
        }
    }
}

/// Where a workflow agent's thread has its composer: it takes no messages, since only its
/// workflow writes there, and while it runs Stop stops the workflow, which is as small a stop as
/// Claude Code has.
struct AgentBar: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    private var selected: Bool { chat.id == model.selectedChatID }

    var body: some View {
        HStack(spacing: 12) {
            Text(words)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if chat.agentWorking {
                Button("Stop workflow") { model.stopWorkflow(of: chat) }
                    .buttonStyle(ActionButtonStyle(small: true))
                    .help("Stops every agent of this workflow")
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 48)
        .background(selected ? Surface.composer : Surface.hover, in: .rect(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Surface.composerEdge, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35)), lineWidth: 1)
                .allowsHitTesting(false)
        }
        // Where the composer would have stopped, so the review and a block's panel stop above it.
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { model.composer(for: chat).top = $0 }
        .simultaneousGesture(TapGesture().onEnded {
            if !selected { model.select(chat) }
        })
    }

    private var words: String {
        switch chat.agentState {
        case "running": "Only its workflow writes here. Claude Code can't stop one agent alone, so Stop stops the workflow."
        case "done": "Done. Only its workflow wrote here, and it takes no messages."
        case "failed": "Failed. Only its workflow wrote here, and it takes no messages."
        default: "Stopped with its workflow. It takes no messages."
        }
    }
}
