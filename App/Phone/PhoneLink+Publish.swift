import CloudKit
import Foundation
import Link
import SwiftData

/// What the phone shows, read off what the drawer and the heads already derive, sealed and written
/// only where it changed: at once when an ask comes or goes, otherwise at most every two seconds.
/// Nothing is read on a timer; a change to what's read is what starts it.
extension PhoneLink {
    struct Snapshot: Equatable {
        var projects: [String: ProjectInfo] = [:]
        var threads: [String: ThreadInfo] = [:]
        var asks: [String: AskInfo] = [:]
    }

    static let window: Duration = .seconds(2)
    /// The latest threads the phone lists beside those at work, waiting or pinned.
    static let latest = 20
    static let replyLength = 4_000

    /// Starts watching, and writes everything once: the first write after a launch or a new state
    /// key, and what CloudKit holds that no longer is, deleted.
    func published(again: Bool = false) {
        guard running else { return }
        if again { sentBoxes = [:] }
        publishMac(.awake)
        watch()
    }

    private func watch() {
        guard running else { return }
        let snapshot = withObservationTracking {
            self.snapshot()
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
        write(snapshot)
    }

    /// Something the snapshot read changed: an ask that came or went goes out now, the rest within
    /// the window.
    private func changed() {
        guard running, writing == nil else { return }
        let asks = Set(model?.conversations.values.compactMap { $0.waitingAsk?.requestId } ?? [])
        let since = ContinuousClock.now - lastWrite
        if asks != Set(sentAsks) || since >= Self.window {
            watch()
        } else {
            writing = Task { [weak self] in
                try? await Task.sleep(for: Self.window - since)
                self?.writing = nil
                self?.watch()
            }
        }
    }

    private func write(_ snapshot: Snapshot) {
        guard let keys else { return }
        lastWrite = .now
        // Each thread's oldest ask, which is what `changed` compares to say one came or went.
        sentAsks = model?.conversations.values.compactMap { $0.waitingAsk?.requestId } ?? []
        pace(asking: !snapshot.asks.isEmpty, working: snapshot.threads.values.contains { $0.status == .working })
        var wrote = 0
        func written<Info: Encodable>(_ type: String, _ name: String, _ info: Info) {
            guard let data = try? Self.coder.encode(info), sentBoxes[name] != data, let record = record(type, name) else { return }
            try? record.seal(info, key: keys.state)
            put(record)
            sentBoxes[name] = data
            wrote += 1
        }
        for (name, info) in snapshot.projects { written(RecordType.project, name, info) }
        for (name, info) in snapshot.threads { written(RecordType.thread, name, info) }
        for (name, info) in snapshot.asks { written(RecordType.ask, name, info) }
        // What left the set, and what an earlier launch wrote that nothing holds now.
        let current = Set(snapshot.projects.keys).union(snapshot.threads.keys).union(snapshot.asks.keys)
        let held = Set(sentBoxes.keys).union(known.values.filter { Self.ours.contains($0.recordType) }.map(\.recordID.recordName))
        for name in held.subtracting(current) where name != RecordName.mac {
            sentBoxes[name] = nil
            delete(CKRecord.ID(recordName: name, zoneID: keys.zone))
            wrote += 1
        }
        if wrote > 0 { sendNow() }
    }

    /// The record types the Mac writes and deletes as the set changes.
    static let ours: Set<String> = [RecordType.project, RecordType.thread, RecordType.ask]

    static let coder: JSONEncoder = {
        let coder = JSONEncoder()
        coder.outputFormatting = .sortedKeys
        coder.dateEncodingStrategy = .millisecondsSince1970
        return coder
    }()

    // MARK: The snapshot

    /// Every project, for the phone's new thread; the threads at work, waiting, pinned or among the
    /// twenty latest, as the drawer lists them; and every ask waiting on you.
    func snapshot() -> Snapshot {
        guard let model else { return Snapshot() }
        var snapshot = Snapshot()
        let projects = model.projects
        let starting = model.selectedProjectID ?? Project.noFolderID
        for (order, project) in projects.enumerated() {
            snapshot.projects[RecordName.project(project.id)] = ProjectInfo(
                id: project.id, name: project.name, initials: project.isNoFolder ? "" : project.initials,
                color: project.isNoFolder ? nil : (project.colorIndex ?? 0) % ProjectColor.palette.count,
                starts: project.id == starting, order: order)
        }
        // A workflow's agent, a subagent or a worker has no row, as in the drawer's list: its asks
        // are the thread's that runs it.
        let listed = projects.flatMap(\.chats).filter { $0.started && !$0.archived && $0.agentID == nil }
        let latest = Set(listed.sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.latest).map(\.id))
        for chat in listed {
            let conversation = model.conversations[chat.id]
            if conversation?.working == true { seen.insert(chat.id) }
            guard chat.pinned || latest.contains(chat.id) || seen.contains(chat.id) || conversation?.waitingAsk != nil,
                  let project = chat.project
            else { continue }
            snapshot.threads[RecordName.thread(chat.id)] = thread(chat, in: project, conversation)
            for ask in conversation?.waitingAsks ?? [] {
                let asked = askedAt[ask.requestId] ?? .now
                askedAt[ask.requestId] = asked
                snapshot.asks[RecordName.ask(ask.requestId)] = Self.info(ask, thread: chat, agentName: model.providerInfo(ask.worker?.agent ?? chat.providerID).name, asked: asked)
            }
        }
        return snapshot
    }

    private func thread(_ chat: Chat, in project: Project, _ conversation: Conversation?) -> ThreadInfo {
        var status = ThreadStatus.idle
        var step: String?
        var rays: [Int: String] = [:]
        if let conversation {
            if conversation.waitingAsk != nil {
                status = .asking
            } else if conversation.working {
                status = .working
            } else if !conversation.endedByItself {
                status = Self.stopped(conversation) ? .stopped : .failed
            }
            if conversation.working {
                let main = conversation.mainStep(cwd: chat.cwd)
                step = conversation.planStep ?? [main.tool, main.detail].compactMap { $0 }.joined(separator: " ")
                rays = Dictionary(uniqueKeysWithValues: conversation.heads.lit.map { ($0, conversation.heads.rayAgents[$0] ?? chat.providerID) })
            }
        }
        return ThreadInfo(
            id: chat.id, project: project.id, title: chat.title, agent: chat.providerID, status: status, step: step, rays: rays,
            reply: reply(of: chat, conversation), pinned: chat.pinned, updated: chat.updatedAt)
    }

    /// The latest turn's last words, once the turn is over; while one runs, the turn before's.
    private func reply(of chat: Chat, _ conversation: Conversation?) -> String? {
        if let conversation {
            if !conversation.running {
                let items = conversation.items
                let turn = items.lastIndex(where: \.startsTurn) ?? items.startIndex
                let last = items[turn...].last { if case .text = $0 { true } else { false } }
                replies[chat.id] = last?.text.map { String($0.prefix(Self.replyLength)) } ?? replies[chat.id] ?? nil
            }
        } else if replies[chat.id] == nil {
            replies[chat.id] = Self.storedReply(of: chat.id, in: model?.context)
        }
        return replies[chat.id] ?? nil
    }

    /// The last reply of a thread whose transcript isn't in memory, read from its last text event alone.
    private static func storedReply(of id: UUID, in context: ModelContext?) -> String? {
        var last = FetchDescriptor<Event>(predicate: #Predicate { $0.chat?.id == id && $0.kind == "text" }, sortBy: [SortDescriptor(\.seq, order: .reverse)])
        last.fetchLimit = 1
        guard let event = try? context?.fetch(last).first, let body = try? JSONDecoder().decode(JSON.self, from: event.payload) else { return nil }
        return body["delta"]?.string.map { String($0.prefix(replyLength)) }
    }

    private static func stopped(_ conversation: Conversation) -> Bool {
        for item in conversation.items.reversed() {
            if case .footer(_, let footer) = item { return footer.stopReason == "interrupted" }
            if item.startsTurn { break }
        }
        return false
    }

    /// An ask as its card on the Mac words it.
    static func info(_ ask: PendingAsk, thread chat: Chat, agentName: String, asked: Date) -> AskInfo {
        let questions = (ask.options?.array ?? []).map { question in
            AskInfo.Question(
                text: question["question"]?.string ?? "", multiple: question["multiSelect"]?.bool ?? false,
                options: (question["options"]?.array ?? []).map { AskInfo.Option(label: $0["label"]?.string ?? "", detail: $0["description"]?.string) })
        }
        let path = ToolSummary.relative(ask.call.file ?? "", to: chat.cwd)
        let title: String
        var detail: String?
        var code = false
        switch ask.toolKind {
        case _ where ask.kind == "question":
            title = questions.first?.text ?? "A question"
        case .run:
            title = "Run a command?"
            detail = ask.call.shown("command")
            code = true
        case .edit:
            title = "Edit \(path)?"
        case .write:
            title = "Write \(path)?"
        case .planning:
            title = "Start on this plan?"
            detail = ask.input["plan"]?.string.map { String($0.prefix(1_200)) }
        case .fetch:
            title = "Fetch a page?"
            detail = ask.call.shown("url")
        default:
            title = "Use \(ask.tool)?"
            detail = ToolSummary.line(for: ask.call, cwd: chat.cwd)
        }
        return AskInfo(
            id: ask.requestId, thread: chat.id, kind: ask.kind == "question" ? "question" : "permission", title: title, detail: detail, code: code,
            choices: ask.choices.map { AskInfo.Choice(id: $0.id, name: $0.name, allows: $0.allows) },
            questions: questions,
            worker: ask.worker.map { "\(agentName)'s worker · \($0.label)" },
            asked: asked)
    }
}
