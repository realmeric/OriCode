import SwiftData
import SwiftUI

/// The agents a thread starts, as threads under it: a workflow's, each made as its workflow first
/// names it and kept up with each snapshot; a Task subagent of its own loop, made as the CLI starts
/// it; and a worker its head sends out on a ray. A workflow's agent's or a subagent's transcript is
/// read from Claude Code's copy while it's on the glass; a worker's comes as it works, since the
/// engine runs its session. Each is left folded with its result once it's over.
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
            // Every snapshot names each agent again, and a finished one's reply is read once.
            let result = chat.agentState == state && chat.agentResult != nil ? nil
                : state == "failed" ? Self.oneLine(agent["error"]?.string) : Self.replyLine(agent["result"]?.string)
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

    /// What the drawer's row says under the title: the first line, cut where the row would. An
    /// error is plain text and is kept as it came.
    static func oneLine(_ text: String?) -> String? {
        firstLine(text).map { String($0.prefix(200)) }
    }

    /// A reply's first line as `oneLine` gives it, in words, since its Markdown, a list's dash, a
    /// link's path or a bold's stars, isn't drawn there. Read from its first 600 characters, room
    /// for a link's path before the row's 200.
    static func replyLine(_ text: String?) -> String? {
        guard let line = firstLine(text)?.prefix(600) else { return nil }
        let unmarked = literal(line.replacing(/^(?:#{1,6}|[-*+>]|\d{1,3}[.)])\s+/, with: ""))
        let words = (try? AttributedString(markdown: unmarked, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))).map { String($0.characters) } ?? unmarked
        return String((words.isEmpty ? String(line) : words).prefix(200))
    }

    /// Underscores, and a star between two letters or digits, kept as written outside code spans:
    /// in a reply `__init__.py` and `2*3*4` are a file and a product, not emphasis.
    private static func literal(_ line: Substring) -> String {
        line.split(separator: "`", omittingEmptySubsequences: false).enumerated().map { index, part in
            guard index.isMultiple(of: 2) else { return String(part) }
            return String(part).replacing(/_|([[:alnum:]])\*(?=[[:alnum:]])/) { match in
                match.output.1.map { "\($0)\\*" } ?? "\\_"
            }
        }.joined(separator: "`")
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    }

    /// A subagent or a worker as the engine tells of it, `agent.thread`: made as it starts, and told
    /// each time it ends with what it returned. A worker messaged after it has finished starts again
    /// in the same thread.
    func syncAgent(of parent: Chat, _ body: JSON) {
        guard let project = parent.project, let id = body["agentId"]?.string else { return }
        let agent: Chat
        if let found = agentThreads[id].flatMap({ chat(withID: $0) }) ?? project.chats.first(where: { $0.openedBy == parent.id && $0.agentID == id }) {
            agent = found
        } else {
            agent = Chat(project: project, title: body["label"]?.string ?? "Agent", permissionMode: parent.permissionMode)
            agent.cwd = parent.cwd
            agent.provider = body["agent"]?.string ?? parent.provider
            agent.model = body["model"]?.string
            agent.started = true
            agent.titleIsCustom = true
            agent.openedBy = parent.id
            agent.agentID = id
            agent.agentKind = body["kind"]?.string
            agent.agentTask = body["task"]?.string ?? id
            agent.agentTranscript = body["transcript"]?.string
            context.insert(agent)
        }
        agentThreads[id] = agent.id
        // An ask it sent before the engine told of its thread is counted at it from here.
        for ask in conversations[parent.id]?.waitingAsks ?? [] where ask.agentID == id && askers[ask.requestId] == nil {
            askers[ask.requestId] = agent
        }
        let state = body["state"]?.string ?? "running"
        if agent.agentState != state { agent.agentState = state }
        // A turn ended with nothing said leaves no reply of an earlier turn behind.
        // A failed worker's result is its error, kept as it came.
        if body["result"] != nil { agent.agentResult = state == "failed" ? Self.oneLine(body["result"]?.string) : Self.replyLine(body["result"]?.string) }
        // A worker's turn that ended without its turn.done, its head's thread gone, ends here.
        if state != "running" { conversations[agent.id]?.stopped() }
        // Heard of in this launch, so the screen of everything running lists it.
        if outcomes[agent.id] == nil { outcomes[agent.id] = Outcome() }
        save()
        followAgents()
    }

    /// One of a worker's events, `worker.said`, kept in its thread as the thread's own: what its
    /// head asked of it as the user's message, one sent into its turn as one taken up mid-turn, the
    /// rest as a turn's.
    func workerSaid(_ body: JSON) {
        guard let id = body["agentId"]?.string, let agent = agentThreads[id].flatMap({ chat(withID: $0) }),
              let said = body["said"], let name = said["event"]?.string
        else { return }
        let conversation = conversation(for: agent)
        if name == "user", said["midTurn"]?.bool == true {
            conversation.sentIntoWorkerTurn(said["text"]?.string ?? "")
        } else if name == "user" {
            conversation.userSent(said["text"]?.string ?? "")
        } else {
            conversation.receive(EngineEvent(name: name, threadId: agent.id.uuidString, body: said))
        }
        if name == "user" || name == "turn.done" { holdWhileWorking() }
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

    /// The cards on the stage whose agents' last calls the engine reads, each from the end of its
    /// transcript; an agent's left out is no longer read. An agent that ends stops its own.
    func followSteps(_ wanted: Set<UUID>) {
        guard engineState == .ready else { return }
        for id in stage.followed.subtracting(wanted) {
            Task { _ = try? await engine.request("agent.follow", ["threadId": .string(id.uuidString), "path": "", "from": 0, "on": false, "steps": true]) }
        }
        var followed = stage.followed.intersection(wanted)
        for id in wanted.subtracting(stage.followed) {
            guard let path = chat(withID: id)?.agentTranscript else { continue }
            followed.insert(id)
            let params: JSON = ["threadId": .string(id.uuidString), "path": .string(path), "from": 0, "on": true, "steps": true]
            Task { _ = try? await engine.request("agent.follow", params) }
        }
        stage.followed = followed
    }

    /// A piece of an agent's transcript, taken only where the stored copy ends: a piece read twice,
    /// by a follow that ended and began again, would show twice. A read that comes in pieces is
    /// held until its last and shown and saved at once: each piece shown alone laid the whole
    /// transcript out again.
    func transcribed(_ body: JSON, into chat: Chat) {
        if body["gone"]?.bool == true, chat.agentRead == 0 {
            say("Transcript gone")
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

    /// An agent's Stop, through the thread that started it. A subagent and a worker stop alone.
    /// Claude Code stops a workflow whole: an agent's own stop says it worked and leaves the agent
    /// going. So a workflow agent's Stop is its workflow's, and its thread says so beside the button.
    func stopAgent(_ agent: Chat) {
        guard let parent = agent.openedBy, let task = agent.agentTask else { return }
        Task {
            do {
                _ = try await engine.request("task.stop", ["threadId": .string(parent.uuidString), "taskId": .string(task)])
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    /// Whether the workflow a thread's CLI runs, or the agent a thread is, or the workflow it's part
    /// of, is still at work. Archiving the thread would let its CLI go and the run with it, between
    /// agents as much as during one, and an agent's row taken away would come back with the next
    /// snapshot or event.
    func workflowRuns(in chat: Chat) -> Bool {
        guard let parent = chat.openedBy, let task = chat.agentTask else {
            return conversations[chat.id]?.heads.workflowRuns() == true
        }
        return chat.agentWorking || conversations[parent]?.heads.workflowRuns(task) == true
    }

    /// The agents under a thread that goes, which nothing else writes or reads.
    func agents(under chat: Chat) -> [Chat] {
        chat.project?.chats.filter { $0.openedBy == chat.id && $0.agentID != nil } ?? []
    }
}

extension Chat {
    var agentWorking: Bool { agentState == "running" }

    /// What a thread's Stop is called: a workflow's agent stops with its workflow. And what has to
    /// stop before an agent's row can go.
    var agentStop: String { agentID != nil && agentKind == nil ? "Stop workflow" : "Stop" }
    var agentStopFirst: String { agentKind == nil ? "its workflow" : "the agent" }

    /// The row's hover for a workflow agent: its result once it has one, and how it ended.
    var agentLine: String? {
        switch agentState {
        case "done": agentResult ?? "Done"
        case "failed": "Failed" + (agentResult.map { ": \($0)" } ?? "")
        case "stopped": "Stopped"
        default: nil
        }
    }
}

/// Where an agent's thread has its composer: it takes no messages, since only its workflow, its
/// opener's Task call or its head writes there. While it runs, Stop stops it, or for a workflow's
/// agent the workflow, which is as small a stop as Claude Code has there.
struct AgentBar: View {
    @Environment(AppModel.self) private var model
    let chat: Chat

    private var selected: Bool { chat.id == model.selectedChatID }

    var body: some View {
        // No words: with no field it shows that nothing is written here. A failed one says so,
        // with what it failed on as the hover.
        HStack(spacing: 12) {
            Text(chat.agentState == "failed" ? "Failed" : "")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(chat.agentLine ?? "")
            if chat.agentWorking {
                Button(chat.agentStop) { model.stopAgent(chat) }
                    .buttonStyle(ActionButtonStyle(small: true))
                    .help(chat.agentKind == nil ? "Stops every agent of this workflow" : "Stops this agent alone")
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
}
