import CloudKit
import CryptoKit
import Foundation
import Link
import SwiftData

/// A thread's whole conversation for the phone, published only while a phone watches it. A phone
/// takes a lease with a command and says so again every minute; while one is live its thread's
/// newest pages are written at most every two seconds as they change, and earlier ones as the
/// phone asks for them. When the last lease on a thread ends, its pages leave iCloud. With no
/// lease nothing here runs and nothing waits: a change to the transcript is what starts a write,
/// and the one timer is for the end of the lease.
extension PhoneLink {
    /// A thread being watched: where its pages stand, for as long as a lease lasts and no longer.
    struct TalkBook {
        /// The items each finished page holds, oldest first.
        var finished: [Range<Int>] = []
        /// The earliest page a phone has asked for.
        var from: Int?
        /// A digest of each page written, by page, so a page written once isn't written again.
        var written: [Int: Data] = [:]
        /// The thread's items as read from its stored events, while it isn't in memory.
        var stored: [Item]?
        var reading = false
        var folding = false
        /// It changed during a fold, which is folded again after.
        var again = false
    }

    struct TalkState {
        var leases = Leases()
        var books: [UUID: TalkBook] = [:]
        var ending: Task<Void, Never>?
        var waiting: Task<Void, Never>?
        var lastWrite = ContinuousClock.now - .seconds(60)
        /// Where the requests stood when the first lease began, for the log of what rule 6 costs.
        var began: (at: ContinuousClock.Instant, requests: Int)?
    }

    /// A page's name for every page in iCloud, which `write` must not take for what left the set.
    var talkNames: Set<String> {
        Set(talk.books.flatMap { thread, book in book.written.keys.map { RecordName.talk(thread, page: $0) } })
    }

    // MARK: The lease

    func watched(_ thread: UUID, from: Int?, opening: Bool, by phone: String, said: Date) {
        guard talk.leases.take(thread, phone: phone, said: said) else { return }
        let new = talk.books[thread] == nil
        var book = talk.books[thread] ?? TalkBook()
        // Whatever the phone held went with its screen: what it asks for now goes out again.
        if opening {
            book.written = book.written.mapValues { _ in Data() }
            book.from = nil
        }
        if let from { book.from = min(book.from ?? from, from) }
        talk.books[thread] = book
        leasesChanged()
        if new || opening || from != nil { publishTalk() }
    }

    func unwatched(by phone: String, said: Date) {
        guard talk.leases.take(nil, phone: phone, said: said) else { return }
        leasesChanged()
    }

    /// Books with no lease left close, and the one timer is set for the next lease to lapse.
    private func leasesChanged() {
        talk.ending?.cancel()
        talk.ending = nil
        let left = talk.leases.threads
        for (thread, book) in talk.books where !left.contains(thread) {
            pageIDs(thread, book).forEach(delete)
            talk.books[thread] = nil
            Self.logger.notice("a lease ended, \(book.written.count) pages out of iCloud")
        }
        sendNow()
        if left.isEmpty, let began = talk.began {
            let seconds = (ContinuousClock.now - began.at).components.seconds
            let requests = (sync?.requests ?? 0) - began.requests
            Self.logger.notice("watched for \(seconds)s, \(requests) requests")
            talk.began = nil
        } else if talk.began == nil, !left.isEmpty {
            talk.began = (.now, sync?.requests ?? 0)
            Self.logger.notice("a phone is watching")
        }
        pace(asking: !sentAsks.isEmpty, working: model?.conversations.values.contains { $0.working } == true)
        guard let end = talk.leases.nextEnd else { return }
        talk.ending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            talk.leases.expire()
            leasesChanged()
        }
    }

    /// Asleep or closed: every lease is over, and these go straight out with the Mac's state.
    func endingTalk() -> [CKRecord.ID] {
        let pages = talk.books.flatMap { pageIDs($0, $1) }
        talk.ending?.cancel()
        talk.waiting?.cancel()
        talk = TalkState()
        return pages
    }

    /// Sealed again with a new key, or into a zone made again.
    func republishTalk() {
        talk.books = talk.books.mapValues { book in
            var book = book
            book.written = book.written.mapValues { _ in Data() }
            return book
        }
        publishTalk()
    }

    private func pageIDs(_ thread: UUID, _ book: TalkBook) -> [CKRecord.ID] {
        guard let keys else { return [] }
        return book.written.keys.map { CKRecord.ID(recordName: RecordName.talk(thread, page: $0), zoneID: keys.zone) }
    }

    // MARK: Publishing

    /// Reads every watched transcript, which is what its next change will be heard by, and writes
    /// what changed. Reading a transcript isn't copying it: `items` and `live` are only touched.
    private func publishTalk() {
        guard running else { return }
        talk.lastWrite = .now
        let threads = talk.leases.threads
        withObservationTracking {
            for thread in threads {
                guard let conversation = model?.conversations[thread] else { continue }
                _ = conversation.items
                _ = conversation.live.text
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.talkChanged() }
        }
        for thread in threads { publish(thread) }
    }

    private func talkChanged() {
        guard talk.waiting == nil, !talk.leases.threads.isEmpty else { return }
        let wait = Self.window - (ContinuousClock.now - talk.lastWrite)
        talk.waiting = Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard !Task.isCancelled, let self else { return }
            talk.waiting = nil
            publishTalk()
        }
    }

    /// Folded off the main thread, from a copy of the transcript: the Mac's frames aren't for this.
    private func publish(_ thread: UUID) {
        guard var book = talk.books[thread], let model, let chat = model.chat(withID: thread) else { return }
        guard !book.folding else {
            talk.books[thread]?.again = true
            return
        }
        let items: [Item]
        if let conversation = model.conversations[thread] {
            // In memory now, where it was read from the store: its items may stand apart from
            // those, so its pages are cut afresh, and written where they differ.
            if book.stored != nil {
                book.stored = nil
                book.finished = []
            }
            items = conversation.items
        } else if let stored = book.stored {
            items = stored
        } else {
            return readStored(thread)
        }
        // What the thread that opened this one told it is no message of the user's.
        let task = chat.openedBy == nil ? nil : items.first { if case .user = $0 { true } else { false } }?.id
        let written = Set(book.written.filter { !$0.value.isEmpty }.keys)
        let fold = TalkFold.Request(thread: thread, items: items, finished: book.finished, from: book.from, written: written, task: task, cwd: chat.cwd)
        book.folding = true
        book.again = false
        talk.books[thread] = book
        Task {
            let folded = await Task.detached(priority: .utility) { TalkFold.fold(fold) }.value
            took(folded, for: thread)
        }
    }

    private func took(_ folded: TalkFold.Result, for thread: UUID) {
        guard var book = talk.books[thread], let keys else { return }
        book.folding = false
        book.finished = folded.finished
        var wrote = false
        for page in folded.pages {
            guard let data = try? Self.coder.encode(page) else { continue }
            let digest = Data(SHA256.hash(data: data))
            guard book.written[page.index] != digest, let record = record(RecordType.thread, RecordName.talk(thread, page: page.index)) else { continue }
            try? record.seal(page, key: keys.state)
            put(record)
            book.written[page.index] = digest
            wrote = true
        }
        let again = book.again
        talk.books[thread] = book
        if wrote { sendNow() }
        if again { publish(thread) }
    }

    /// A thread that isn't in memory stays out of it: its events are read and folded on a context
    /// of their own, which a long thread would otherwise cost the main thread as a replay.
    private func readStored(_ thread: UUID) {
        guard talk.books[thread]?.reading == false, let container = model?.context.container else { return }
        talk.books[thread]?.reading = true
        Task {
            let items = await Task.detached(priority: .utility) {
                TalkFold.items(of: (try? StoredEvent.read(thread, from: ModelContext(container))) ?? [])
            }.value
            guard talk.books[thread] != nil else { return }
            talk.books[thread]?.reading = false
            talk.books[thread]?.stored = items
            publishTalk()
        }
    }
}

/// A transcript as the phone's lines, in pages. Nothing here reads the model, so it can run off
/// the main thread on a copy of the items.
enum TalkFold {
    struct Request: @unchecked Sendable {
        let thread: UUID
        let items: [Item]
        let finished: [Range<Int>]
        let from: Int?
        let written: Set<Int>
        let task: UUID?
        let cwd: String
    }

    struct Result: Sendable {
        var finished: [Range<Int>]
        var pages: [TalkPage]
    }

    /// A line, and what's needed to cut a page after it.
    struct Folded {
        let line: TalkLine
        /// Where the items after it start.
        let through: Int
        /// Whether its words can no longer change: nothing's still out on it, nothing waits.
        let settled: Bool
    }

    static let callLength = 160
    static let callsKept = 40

    /// Pages from where the finished ones end are cut again. A page goes among the finished once
    /// it's full, nothing in it can change and a page follows it, so what's folded each time is
    /// what the thread has said since. The pages that come back are those since then, and those
    /// asked for that weren't written yet.
    static func fold(_ request: Request) -> Result {
        var finished = request.finished
        var pages: [TalkPage] = []
        let start = finished.last?.upperBound ?? 0
        let lines = lines(of: request.items[min(start, request.items.count)...], task: request.task, cwd: request.cwd)
        let cuts = Talk.cut(lines.map(\.line))
        let firstNew = finished.count
        var next = firstNew
        var kept = start
        var open = false
        for (place, cut) in cuts.enumerated() {
            let page = lines[cut]
            if !open, place < cuts.count - 1, page.allSatisfy(\.settled), let last = page.last {
                finished.append(kept..<last.through)
                kept = last.through
            } else {
                open = true
            }
            pages.append(TalkPage(thread: request.thread, index: next, lines: page.map(\.line)))
            next += 1
        }
        let wanted = max(0, min(request.from ?? .max, next - Talk.openingPages))
        // Kept to the pages wanted, by a phone that hasn't read further up.
        pages.removeAll { $0.index < wanted }
        for index in wanted..<max(wanted, firstNew) where !request.written.contains(index) {
            let range = finished[index]
            let held = Self.lines(of: request.items[min(range.lowerBound, request.items.count)..<min(range.upperBound, request.items.count)], task: request.task, cwd: request.cwd)
            pages.append(TalkPage(thread: request.thread, index: index, lines: held.map(\.line)))
        }
        return Result(finished: finished, pages: pages)
    }

    /// The items as the transcript folds them, thinking left out: Settings can leave it out on the
    /// Mac, and the phone has less room still.
    static func lines(of items: ArraySlice<Item>, task: UUID?, cwd: String) -> [Folded] {
        let places = Dictionary(items.indices.map { (items[$0].id, $0) }, uniquingKeysWith: { $1 })
        let entries = TranscriptEntry.fold(items, thinking: false)
        return entries.enumerated().compactMap { index, entry in
            guard let line = line(of: entry, task: task, cwd: cwd) else { return nil }
            // The last entry can still grow: a reply streaming, a run going on.
            let settled = index < entries.count - 1 && settled(entry)
            return Folded(line: line, through: (places[entry.last.id] ?? items.endIndex - 1) + 1, settled: settled)
        }
    }

    private static func settled(_ entry: TranscriptEntry) -> Bool {
        let items: [Item]
        switch entry {
        case .item(let item): items = [item]
        case .run(let run): items = run
        }
        return items.allSatisfy { item in
            switch item {
            case .tool(_, let call): call.result != nil || call.isError
            case .ask(_, let ask): ask.state != .waiting
            default: true
            }
        }
    }

    private static func line(of entry: TranscriptEntry, task: UUID?, cwd: String) -> TalkLine? {
        switch entry {
        case .run(let run):
            let calls = run.compactMap { item -> ToolCall? in if case .tool(_, let call) = item { call } else { nil } }
            return TalkLine(
                id: entry.id.uuidString, kind: .tools, text: ToolSummary.run(calls), count: calls.count,
                calls: ToolRunRow.collapsed(run).prefix(callsKept).compactMap { item in
                    if case .tool(_, let call) = item { String(ToolSummary.line(for: call, cwd: cwd).prefix(callLength)) } else { nil }
                },
                failed: calls.count { $0.isError && !$0.stopped })
        case .item(let item):
            return line(of: item, task: task, cwd: cwd)
        }
    }

    private static func line(of item: Item, task: UUID?, cwd: String) -> TalkLine? {
        let id = item.id.uuidString
        switch item {
        case .user(let message, let text, let images, _):
            return TalkLine(id: id, kind: message == task ? .task : .mine, text: String(text.prefix(Talk.messageLength)), count: images.count)
        case .text(_, let text):
            guard !text.isEmpty else { return nil }
            return TalkLine(id: id, kind: .agent, text: bounded(text))
        case .tool(_, let call):
            // A plan shows on its card on the Mac, and a phone's thread has its step.
            guard call.kind != .plan else { return nil }
            return TalkLine(id: id, kind: .tools, text: String(ToolSummary.line(for: call, cwd: cwd).prefix(callLength)), count: 1, failed: call.isError && !call.stopped ? 1 : 0)
        case .ask(_, let ask):
            guard !ask.shownElsewhere else { return nil }
            return TalkLine(id: id, kind: .ask, text: ask.state == .waiting ? "" : ask.settledLine(cwd: cwd), ask: ask.requestId)
        case .note(_, let text):
            return TalkLine(id: id, kind: .note, text: bounded(text))
        case .limited:
            return TalkLine(id: id, kind: .note, text: "Stopped by a limit")
        case .shell(_, let run):
            return TalkLine(id: id, kind: .tools, text: String("Ran \(ToolSummary.firstLine(run.command))".prefix(callLength)), count: 1, failed: (run.exitCode ?? 0) != 0 ? 1 : 0)
        case .thinking, .footer, .nearLimit, .opened, .suggested, .act, .changed, .woke:
            return nil
        }
    }

    /// A reply cut where no record could carry it, and nowhere else.
    private static func bounded(_ text: String) -> String {
        text.utf8.count <= Talk.lineBytes ? text : String(text.prefix(Talk.lineBytes / 4))
    }

    /// A stored thread's items as a replay makes them, for what the phone draws, without the
    /// conversation a replay would make on the main thread. What an event adds to no line is left
    /// out; what ends a run of calls on the Mac ends it here.
    static func items(of events: [StoredEvent]) -> [Item] {
        var items: [Item] = []
        var calls: [String: Int] = [:]
        var asks: [String: Int] = [:]
        for event in events {
            guard let body = event.body else { continue }
            let id = event.id
            switch event.kind {
            case "user":
                let images = body["images"]?.array?.compactMap { $0.string.flatMap { Data(base64Encoded: $0) } } ?? []
                items.append(.user(id: id, text: body["text"]?.string ?? "", images: images, midTurn: body["midTurn"]?.bool ?? false))
            case "wake":
                items.append(.woke(id: id))
            case "text":
                items.append(.text(id: id, text: body["delta"]?.string ?? ""))
            case "tool.use":
                let name = body["name"]?.string ?? ""
                let call = ToolCall(toolUseId: body["toolUseId"]?.string ?? "", name: name, input: body["input"] ?? .null, declared: ToolKind(body["kind"], tool: name), view: body["view"] ?? .null)
                calls[call.toolUseId] = items.count
                items.append(.tool(id: id, call: call))
            case "tool.result":
                guard let index = body["toolUseId"]?.string.flatMap({ calls[$0] }), case .tool(let item, var call) = items[index] else { break }
                call.result = ""
                call.isError = body["isError"]?.bool ?? false
                items[index] = .tool(id: item, call: call)
            case "ask":
                let tool = body["tool"]?.string ?? ""
                let request = body["requestId"]?.string ?? ""
                asks[request] = items.count
                items.append(.ask(id: id, ask: PendingAsk(
                    requestId: request, kind: body["kind"]?.string ?? "permission", tool: tool, input: body["input"] ?? .null,
                    options: body["options"], state: .cancelled, toolUseId: body["toolUseId"]?.string,
                    declared: ToolKind(body["toolKind"], tool: tool), view: body["view"] ?? .null,
                    agentID: body["agentId"]?.string, staged: body["worker"] == nil && body["agentId"]?.string != nil)))
            case "answer":
                guard let index = body["requestId"]?.string.flatMap({ asks[$0] }), case .ask(let item, var ask) = items[index] else { break }
                ask.state = body["allow"]?.bool == true ? .allowed : .denied
                ask.answeredBy = body["by"]?.string
                items[index] = .ask(id: item, ask: ask)
            case "turn.done":
                items.append(.footer(id: id, footer: TurnFooter(durationMs: 0, costUSD: 0, stopReason: body["stopReason"]?.string ?? "")))
            case "error", "note":
                items.append(.note(id: id, text: body["message"]?.string ?? body["text"]?.string ?? ""))
            case "compacted":
                items.append(.note(id: id, text: "Compacted the conversation."))
            case "limited":
                items.append(.limited(id: id, resetsAt: .now, window: nil))
            case "shell":
                items.append(.shell(id: id, run: ShellRun(command: body["command"]?.string ?? "", folder: "")))
            case "thread.act", "thread.overlap", "thread.suggested", "head.changed":
                items.append(.suggested(id: id, title: "", prompt: ""))
            default:
                break
            }
        }
        return items
    }
}
