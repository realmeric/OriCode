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
    func nudge(_ asks: [String: AskInfo], threads: [String: ThreadInfo], locked: Bool = false) {
        guard let keys else { return }
        let waiting = Set(asks.values.map(\.id))
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
        guard !fresh.isEmpty else { return }
        guard locked || nudging else {
            // Seen while Meriç was at the Mac: not buzzed later for the same ask, except at a lock.
            passed.formUnion(fresh.map(\.id))
            return
        }
        for ask in fresh {
            let thread = threads[RecordName.thread(ask.thread)]
            let options = ask.questions.count == 1 && !ask.questions[0].multiple && ask.questions[0].options.count <= 3
                ? ask.questions[0].options.map(\.label) : []
            let info = NudgeInfo(kind: ask.isQuestion ? .question : .permission, title: thread?.title ?? "", body: ask.line,
                                 thread: ask.thread, ask: ask.id, options: options)
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
        nudge(snapshot.asks, threads: snapshot.threads, locked: true)
    }

    /// A turn's end in a thread the phone wrote to, its failure or a limit stopping it included,
    /// since that's the end the phone waits for: its reply's first line, with Reply on it. A turn
    /// ending in a thread written to from the Mac alone doesn't buzz the phone.
    func nudgeEnds(_ threads: [String: ThreadInfo]) {
        guard let keys else { return }
        for thread in threads.values where messaged.contains(thread.id) {
            let before = statuses[thread.id]
            statuses[thread.id] = thread.status
            guard before == .working || before == .asking, thread.status != .working, thread.status != .asking, Notify.current != .never else { continue }
            let line = thread.reply?.split(whereSeparator: \.isNewline).first.map(String.init) ?? (thread.status == .failed ? "Failed" : "Stopped")
            let info = NudgeInfo(kind: .reply, title: thread.title, body: line, thread: thread.id, ask: nil, options: [])
            guard let record = record(RecordType.nudge, RecordName.nudge("reply-\(UUID().uuidString)")),
                  (try? record.seal(info, key: keys.state)) != nil
            else { continue }
            put(record)
            // Once the phone has had it, it has done its work; the last few are kept.
            endNudges.append(record.recordID)
            while endNudges.count > 5 { delete(endNudges.removeFirst()) }
        }
    }
}
