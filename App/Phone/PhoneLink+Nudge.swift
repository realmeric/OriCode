import AppKit
import CloudKit
import Link

/// What makes the phone buzz: a Nudge record for an ask, written only while Meriç is away from the
/// Mac, unless Settings › Phone says always or never, and deleted once its ask is settled.
extension PhoneLink {
    enum Notify: String, CaseIterable {
        case away, always, never

        static let key = "phoneNotify"

        static var current: Notify {
            UserDefaults.standard.string(forKey: key).flatMap(Notify.init) ?? .away
        }

        var title: String {
            switch self {
            case .away: "When you're away"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// What a notification says of an ask, finer than its card: what it wants, and the command,
    /// path or page it's on. A question's text stays whole, since a button's answer is keyed by it.
    struct Notice: Equatable {
        var kind: NudgeInfo.Kind
        var body: String

        init(kind: NudgeInfo.Kind, body: String) {
            self.kind = kind
            self.body = body
        }

        init(_ ask: PendingAsk, _ info: AskInfo, cwd: String) {
            let path = ToolSummary.relative(ask.call.file ?? "", to: cwd)
            let on = String((info.detail ?? info.title).prefix(NudgeInfo.bodyLength))
            switch ask.toolKind {
            case _ where info.isQuestion: self.init(kind: .question, body: info.line)
            case .run: self.init(kind: .run, body: on)
            case .edit: self.init(kind: .edit, body: path)
            case .write: self.init(kind: .write, body: path)
            case .planning: self.init(kind: .plan, body: on)
            case .fetch: self.init(kind: .fetch, body: on)
            default: self.init(kind: .permission, body: on)
            }
        }
    }

    /// Away: the screen locked, the display asleep, or no key or click for five minutes, read once
    /// now and never on a timer.
    static var away: Bool {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any], session["CGSSessionScreenIsLocked"] as? Bool == true { return true }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return true }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        return idle >= 300
    }

    private var nudging: Bool {
        switch Notify.current {
        case .always: true
        case .never: false
        case .away: Self.away
        }
    }

    /// New asks nudge when the phone should buzz now; asks gone take their nudges with them.
    func nudge(_ snapshot: Snapshot, locked: Bool = false) {
        guard let keys else { return }
        let asks = snapshot.asks
        let waiting = Set(asks.values.map(\.id)).union(snapshot.passes.values.map(\.id))
        for id in nudged.subtracting(waiting) {
            nudged.remove(id)
            delete(CKRecord.ID(recordName: RecordName.nudge(id), zoneID: keys.zone))
        }
        // An earlier launch's, for asks it took with it.
        for record in known.values where record.recordType == RecordType.nudge && !nudged.contains(RecordName.id(in: record.recordID.recordName))
            && !endNudges.contains(record.recordID) {
            delete(record.recordID)
        }
        let fresh = asks.values.filter { !nudged.contains($0.id) && !passed.contains($0.id) }
        let freshPasses = snapshot.passes.values.filter { !nudged.contains($0.id) && !passed.contains($0.id) }
        guard !fresh.isEmpty || !freshPasses.isEmpty else { return }
        guard locked || nudging else {
            // Seen while Meriç was at the Mac: not buzzed later for the same ask, except at a lock.
            passed.formUnion(fresh.map(\.id) + freshPasses.map(\.id))
            return
        }
        for pass in freshPasses {
            guard let record = record(RecordType.nudge, RecordName.nudge(pass.id)), (try? record.seal(Self.nudge(for: pass), key: keys.state)) != nil else { continue }
            put(record)
            nudged.insert(pass.id)
        }
        for ask in fresh {
            let notice = snapshot.notices[ask.id] ?? Notice(kind: ask.isQuestion ? .question : .permission, body: ask.line)
            let thread = snapshot.threads[RecordName.thread(ask.thread)]
            let options = ask.questions.count == 1 && !ask.questions[0].multiple && ask.questions[0].options.count <= 3
                ? ask.questions[0].options.map(\.label) : []
            let info = NudgeInfo(kind: notice.kind, title: thread?.title ?? "", body: notice.body,
                                 thread: ask.thread, ask: ask.id, options: options,
                                 project: thread.flatMap { snapshot.projects[RecordName.project($0.project)] }, agent: thread?.agent)
            guard let record = record(RecordType.nudge, RecordName.nudge(ask.id)), (try? record.seal(info, key: keys.state)) != nil else { continue }
            put(record)
            nudged.insert(ask.id)
        }
        sendNow()
    }

    /// The screen locked with asks waiting: those not buzzed yet buzz now.
    func screenLocked() {
        guard running, Notify.current != .never else { return }
        let snapshot = snapshot()
        passed = []
        nudge(snapshot, locked: true)
    }

    /// A turn's end, its failure or a limit stopping it included: its reply's first lines, with
    /// Reply on it, for a thread the phone wrote to, and while the phone should buzz, for any other
    /// thread nothing opened (NudgeInfo.endBuzzes). A Stop sent from the phone isn't news to it.
    func nudgeEnds(_ snapshot: Snapshot) {
        guard let keys else { return }
        for thread in snapshot.threads.values {
            let before = statuses[thread.id]
            statuses[thread.id] = thread.status
            guard before == .working || before == .asking, thread.status != .working, thread.status != .asking else { continue }
            guard stoppedHere.remove(thread.id) == nil, Notify.current != .never,
                  NudgeInfo.endBuzzes(wrote: messaged.contains(thread.id), opened: snapshot.opened.contains(thread.id), nudging: nudging)
            else { continue }
            let info = NudgeInfo(kind: thread.status == .failed ? .failed : thread.status == .stopped ? .stopped : .reply, title: thread.title,
                                 body: endWords(of: thread), thread: thread.id, ask: nil, options: [],
                                 project: snapshot.projects[RecordName.project(thread.project)], agent: thread.agent)
            guard let record = record(RecordType.nudge, RecordName.nudge("reply-\(UUID().uuidString)")),
                  (try? record.seal(info, key: keys.state)) != nil
            else { continue }
            put(record)
            // Once the phone has had it, it has done its work; the last few are kept.
            endNudges.append(record.recordID)
            while endNudges.count > 5 { delete(endNudges.removeFirst()) }
        }
    }

    /// A reply's first lines, or for a turn that ended short what it said as it did: its reply is
    /// the turn before's.
    private func endWords(of thread: ThreadInfo) -> String {
        guard thread.status != .idle else { return NudgeInfo.opening(of: thread.reply ?? "") }
        let items = model?.conversations[thread.id]?.items ?? []
        let turn = items.lastIndex(where: \.startsTurn) ?? items.startIndex
        let note = items[turn...].last { if case .note = $0 { true } else { false } }
        return NudgeInfo.opening(of: note?.text ?? "")
    }
}
