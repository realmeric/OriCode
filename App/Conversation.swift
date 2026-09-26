import Foundation
import Observation
import SwiftData
import SwiftUI

struct Hunk: Hashable {
    let oldStart: Int
    let newStart: Int
    let lines: [String]
}

struct ToolCall: Hashable {
    let toolUseId: String
    let name: String
    let input: JSON
    var result: String?
    var isError = false
    var patch: [Hunk]?
    /// A Workflow call's run, as the engine last told of it.
    var workflow: WorkflowRun?

    static let edits: Set<String> = ["Edit", "MultiEdit", "Write"]

    var isEdit: Bool { Self.edits.contains(name) }
}

struct PendingAsk: Hashable {
    enum State: Hashable {
        case waiting
        case allowed
        case denied
        case cancelled
    }

    let requestId: String
    let kind: String
    let tool: String
    let input: JSON
    let options: JSON?
    var state: State = .waiting
    /// The call it holds, whose line waits with it.
    var toolUseId: String?
}

/// A command run from the composer's shell prompt, as the thread keeps it: what it printed, raw,
/// and how much of that Claude hasn't read.
struct ShellRun: Hashable {
    let command: String
    let folder: String
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int32?
    var output = Data()
    /// How many of its last lines Claude hasn't read, counted from the end because a relaunch
    /// rebuilds the terminal from the end of the output; -1 for all of them, as until it's read.
    var unread = -1
    /// False for a block the model never reads: one running the thread's own session in Claude
    /// Code, whose screen is the conversation itself.
    var forModel = true

    var body: JSON {
        var body: [String: JSON] = [
            "event": "shell", "command": .string(command), "folder": .string(folder),
            "startedAt": .number(startedAt.timeIntervalSince1970), "output": .string(output.base64EncodedString()),
            "unread": .number(Double(unread)),
        ]
        if let endedAt { body["endedAt"] = .number(endedAt.timeIntervalSince1970) }
        if let exitCode { body["exitCode"] = .number(Double(exitCode)) }
        if !forModel { body["forModel"] = .bool(false) }
        return .object(body)
    }

    init(command: String, folder: String, startedAt: Date = .now) {
        self.command = command
        self.folder = folder
        self.startedAt = startedAt
    }

    init(_ body: JSON) {
        command = body["command"]?.string ?? ""
        folder = body["folder"]?.string ?? ""
        startedAt = Date(timeIntervalSince1970: body["startedAt"]?.double ?? 0)
        endedAt = body["endedAt"]?.double.map(Date.init(timeIntervalSince1970:))
        exitCode = body["exitCode"]?.int.map(Int32.init)
        output = body["output"]?.string.flatMap { Data(base64Encoded: $0) } ?? Data()
        // A block stored by an earlier build counts how many characters Claude read, and one read
        // at all had nearly always been read after it ended.
        unread = body["unread"]?.int ?? ((body["sentUpTo"]?.int ?? -1) < 0 ? -1 : 0)
        forModel = body["forModel"]?.bool ?? true
    }
}

struct TurnFooter: Hashable {
    let durationMs: Double
    let costUSD: Double
    let stopReason: String
    var files = 0
    var added = 0
    var deleted = 0
}

/// A message sent while a turn runs, until Claude takes it up. It isn't part of the conversation
/// yet, so it's kept apart from the items and out of the store.
struct WaitingMessage: Identifiable, Hashable {
    let id: UUID
    /// What's sent and shown: what was typed, or for images alone the question put with them.
    let text: String
    /// What was typed, which is what goes back to the composer if the message never runs.
    let typed: String
    let images: [ImageAttachment]
    let previews: [Data]
    let written = Date.now
}

enum Item: Identifiable, Hashable {
    /// `midTurn` is a message Claude took up in the middle of a turn, which doesn't start one.
    case user(id: UUID, text: String, images: [Data] = [], midTurn: Bool = false)
    case text(id: UUID, text: String)
    case thinking(id: UUID, text: String)
    case tool(id: UUID, call: ToolCall)
    case ask(id: UUID, ask: PendingAsk)
    case footer(id: UUID, footer: TurnFooter)
    case note(id: UUID, text: String)
    /// One of the plan's limits refused a turn: when it resets, and which limit it was.
    case limited(id: UUID, resetsAt: Date, window: String?)
    /// A command run from the composer's shell prompt.
    case shell(id: UUID, run: ShellRun)

    var id: UUID {
        switch self {
        case .user(let id, _, _, _), .text(let id, _), .thinking(let id, _), .tool(let id, _), .ask(let id, _),
             .footer(let id, _), .note(let id, _), .limited(let id, _, _), .shell(let id, _):
            id
        }
    }
}

/// One thread's transcript: the stored events replayed into items, then kept current
/// from the engine's live events. Streaming text lands in one event per assistant
/// message, updated in place.
@MainActor
@Observable
final class Conversation {
    private(set) var items: [Item] = []
    private(set) var running = false
    /// Subagents, commands and workflows out for this thread, as the engine last listed them.
    let heads = Heads()
    /// "Can't reach Claude…" while the CLI retries; a live line, never stored.
    private(set) var retrying: String?
    /// Fast mode as the CLI last reported it: on, off or cooldown, and why it can't be on.
    /// What the thread's own CLI says it runs at, once it has started: the level (nil when the
    /// model has none) and whether Ultracode came on.
    private(set) var appliedEffort: String??
    private(set) var appliedUltracode: Bool?
    /// Whether the CLI that gave that reading was started as Ultracode.
    private(set) var askedUltracode = false
    /// The level read while the thread picked none, and for which model: where Default really
    /// lands, project settings included, which the engine's first reading with the user's
    /// settings alone can't know.
    private(set) var defaultReading: (model: String?, level: String?)?
    private(set) var turn = 0
    /// Asks that were waiting on you when OriCode quit, by request id. They stay up, and the turn
    /// with them; the CLI that asked is gone, so an answer resumes the session instead.
    private(set) var askedBeforeQuit: Set<String> = []
    /// Messages sent into the running turn that Claude hasn't taken up yet, oldest first.
    private(set) var waiting: [WaitingMessage] = []
    /// Messages written while the turn ran, in the order they'll go. Kept in memory like the
    /// composer's draft, so a quit loses them. Every change to it is animated here, a turn's end
    /// included, so the composer's glass and its place in the window move with the lines.
    private(set) var queue: [QueuedMessage] = []
    /// Messages that won't go out after all, queued or sent into the turn, oldest first.
    private(set) var handedBack: [QueuedMessage] = []
    /// The turn ended with messages still waiting, and the next one, theirs, starts at once.
    private var nextFollows = false
    /// Whether an error came in since the turn started, which makes it one that failed.
    private var failed = false
    private let chat: Chat
    private let context: ModelContext
    private var seq = 0
    private var open: (item: Int, event: Event, kind: String)?
    private var unsaved = false
    /// Each command's event, updated when it ends and when Claude reads it.
    private var shellEvents: [UUID: Event] = [:]
    /// Each workflow's one event, by its task, written again as it moves.
    private var workflowEvents: [String: Event] = [:]

    init(chat: Chat, context: ModelContext) {
        self.chat = chat
        self.context = context
        for event in chat.events.sorted(by: { $0.seq < $1.seq }) {
            seq = max(seq, event.seq + 1)
            turn = max(turn, event.turn)
            guard let body = try? JSONDecoder().decode(JSON.self, from: event.payload) else { continue }
            if event.kind == "shell" { shellEvents[event.id] = event }
            if event.kind == "workflow", let taskId = body["taskId"]?.string { workflowEvents[taskId] = event }
            apply(event.kind, body, id: event.id)
        }
        open = nil
        endWorkflows(saving: false)
        // Asks and tool calls from an earlier launch will never finish; the engine that ran them is
        // gone. A quit in the middle of the last turn is the exception: what it was waiting on you
        // for is still up, with the call it holds.
        let lastSent = items.lastIndex(where: \.startsTurn) ?? -1
        for index in items.indices {
            guard case .ask(let id, var ask) = items[index], ask.state == .waiting else { continue }
            if chat.quitMidTurn, index > lastSent {
                askedBeforeQuit.insert(ask.requestId)
            } else {
                ask.state = .cancelled
                items[index] = .ask(id: id, ask: ask)
            }
        }
        running = waitingAfterQuit
        finishOpenTools(except: waitingCalls)
    }

    /// When the thread goes on by itself, once the session limit that stopped it resets.
    var resumeAt: Date? {
        chat.resumeAt
    }

    /// The latest limit's line, the one a waiting thread waits out.
    var lastLimit: UUID? {
        items.last { if case .limited = $0 { true } else { false } }?.id
    }

    /// The thread won't go on by itself after all.
    func cancelResume() {
        chat.resumeAt = nil
        unsaved = true
        flush()
    }

    /// Whether the thread is waiting on you from before a quit, with no CLI behind it.
    var waitingAfterQuit: Bool {
        !askedBeforeQuit.isEmpty
    }

    /// The calls the asks from before a quit hold.
    private var waitingCalls: Set<String> {
        Set(items.compactMap { item in
            if case .ask(_, let ask) = item, askedBeforeQuit.contains(ask.requestId) { ask.toolUseId } else { nil }
        })
    }

    /// The oldest ask still waiting, which is the one Return and Esc answer.
    var waitingAsk: PendingAsk? {
        for item in items {
            if case .ask(_, let ask) = item, ask.state == .waiting { return ask }
        }
        return nil
    }

    /// Whether it has anything the composer mustn't lose by letting the conversation go.
    var holdsMessages: Bool {
        !waiting.isEmpty || !queue.isEmpty || !handedBack.isEmpty
    }

    func userSent(_ text: String, previews: [Data] = [], id: UUID = UUID()) {
        turn += 1
        running = true
        failed = false
        chat.started = true
        chat.quitMidTurn = false
        chat.resumeAt = nil
        if !chat.titleIsCustom, turn == 1 || chat.title == Chat.untitled {
            chat.title = Chat.title(from: text)
        }
        recordUser(text, previews: previews, midTurn: false, id: id)
    }

    private func recordUser(_ text: String, previews: [Data], midTurn: Bool, id: UUID) {
        var body: [String: JSON] = ["event": "user", "text": .string(text)]
        if !previews.isEmpty { body["images"] = .array(previews.map { .string($0.base64EncodedString()) }) }
        if midTurn { body["midTurn"] = true }
        record("user", .object(body), id: id)
    }

    /// A message sent while a turn runs. It shows under the transcript, waiting, until Claude
    /// takes it up.
    func sentIntoTurn(_ text: String, typed: String? = nil, images: [ImageAttachment]) -> WaitingMessage {
        let message = WaitingMessage(id: UUID(), text: text, typed: typed ?? text, images: images, previews: images.compactMap(\.preview))
        waiting.append(message)
        return message
    }

    /// Claude took a waiting message up: into the running turn, where it lands after everything
    /// so far with Claude's reply after it, or as a turn of its own. It keeps its id, so its
    /// bubble stays where it is.
    func taken(_ id: UUID, newTurn: Bool) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let message = waiting.remove(at: index)
        if newTurn {
            nextFollows = false
            userSent(message.text, previews: message.previews, id: message.id)
        } else {
            recordUser(message.text, previews: message.previews, midTurn: true, id: message.id)
        }
    }

    /// A waiting message that will never run, cancelled or lost with the engine, goes back to
    /// the composer as it was typed, its images with it.
    func handBack(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let message = waiting.remove(at: index)
        handBack([QueuedMessage(id: message.id, text: message.typed, images: message.images, written: message.written)])
        // Nothing is left for the turn that was to follow.
        if nextFollows, waiting.isEmpty {
            nextFollows = false
            running = false
        }
    }

    func handBackAll() {
        for message in waiting { handBack(message.id) }
    }

    /// Everything still queued, and any messages given, goes back to the field instead of out:
    /// nothing is lost, and nothing goes out after Stop.
    func handBackQueue(with messages: [QueuedMessage] = []) {
        guard !messages.isEmpty || !queue.isEmpty else { return }
        handBack(messages + queue)
        withAnimation(Motion.fade) { queue = [] }
    }

    private func handBack(_ messages: [QueuedMessage]) {
        for message in messages {
            handedBack.insert(message, at: handedBack.firstIndex { $0.written > message.written } ?? handedBack.endIndex)
        }
    }

    /// What the composer takes back: nothing while a message sent into the turn still waits, so
    /// the ones a Stop cancels one at a time come back with the queue, in the order they were
    /// written.
    var returning: [QueuedMessage] {
        waiting.isEmpty ? handedBack : []
    }

    /// The composer showing this thread takes what was handed back.
    func takeHandedBack() -> [QueuedMessage] {
        let back = returning
        if !back.isEmpty { handedBack = [] }
        return back
    }

    func enqueue(_ text: String, images: [ImageAttachment] = []) {
        withAnimation(Motion.fade) { queue.append(QueuedMessage(text: text, images: images)) }
    }

    func removeQueued(_ id: QueuedMessage.ID) {
        withAnimation(Motion.fade) { queue.removeAll { $0.id == id } }
    }

    /// A queued message leaving the queue for the field, to be edited.
    func takeBack(_ id: QueuedMessage.ID) -> QueuedMessage? {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        return withAnimation(Motion.fade) { queue.remove(at: index) }
    }

    /// After a turn that ended by itself, the first queued message goes out through `send` and
    /// the rest wait for its turn to end; so do all of them while a message sent into the turn
    /// still waits to run. A background agent, command or workflow still out doesn't hold them:
    /// the CLI takes its report in when it comes, and a server left running would hold them for
    /// good. One `send` refuses, in a thread handed to the terminal for instance, goes back to the
    /// field with the rest, since no turn would run to send them.
    func sendNext(through send: (QueuedMessage) -> Bool) {
        guard !running, waiting.isEmpty, !queue.isEmpty else { return }
        let next = withAnimation(Motion.fade) { queue.removeFirst() }
        if !send(next) { handBackQueue(with: [next]) }
    }

    func sendFailed(_ message: String) {
        running = false
        handBackQueue()
        record("note", ["event": "note", "text": .string(message)])
    }

    func note(_ message: String) {
        record("note", ["event": "note", "text": .string(message)])
    }

    func receive(_ event: EngineEvent) {
        if event.name != "retrying" { retrying = nil }
        switch event.name {
        case "effort":
            let level = event.body["level"]?.string
            let asked = event.body["asked"]?.string
            appliedEffort = .some(level)
            appliedUltracode = event.body["ultracode"]?.bool ?? false
            askedUltracode = asked == Effort.ultracode
            if asked == nil { defaultReading = (chat.model, level) }
        case "heads":
            heads.update(event.body)
        case "retrying":
            let attempt = event.body["attempt"]?.int ?? 0
            let max = event.body["max"]?.int ?? 0
            retrying = "Can't reach Claude. Trying again, \(attempt) of \(max)…"
        case "turn.started":
            running = true
            // A turn nobody sent, a background agent reporting back, doesn't carry the last one's error.
            failed = false
            if let sessionId = event.body["sessionId"]?.string, chat.sessionId != sessionId {
                chat.sessionId = sessionId
                unsaved = true
            }
        case "text", "thinking":
            let delta = event.body["delta"]?.string ?? ""
            if let open, open.kind == event.name {
                let current = items[open.item]
                let text = (current.text ?? "") + delta
                items[open.item] = event.name == "text" ? .text(id: current.id, text: text) : .thinking(id: current.id, text: text)
                open.event.payload = (try? JSON.object(["event": .string(event.name), "delta": .string(text)]).data()) ?? Data()
                unsaved = true
            } else {
                record(event.name, ["event": .string(event.name), "delta": .string(delta)], keepOpen: true)
            }
        case "limited":
            // Refused by a limit, the turn didn't end by itself, and the queue's next would only be
            // refused too: it goes back to the field.
            failed = true
            record(event.name, event.body)
            if let resetsAt = event.body["resetsAt"]?.double.map({ Date(timeIntervalSince1970: $0 / 1000) }),
               Limit.resumes(window: event.body["window"]?.string, resetsAt: resetsAt) {
                // Refused again past the reset, a Mac's clock ahead of Claude's: a while longer.
                chat.resumeAt = resetsAt > .now ? resetsAt : .now.addingTimeInterval(300)
                flush()
            }
        case "session.lost":
            chat.sessionId = nil
            record("note", ["event": "note", "text": "The earlier session is gone, so this thread carries on in a new one."])
        case "compacted":
            chat.contextUsed = event.body["after"]?.int ?? 0
            record(event.name, event.body)
        case "tool.use", "tool.result", "ask", "ask.cancelled", "error":
            if event.name == "error" { failed = true }
            record(event.name, event.body)
        case "workflow":
            workflowChanged(event.body)
            heads.workflow(event.body)
        case "message.taken":
            if let id = event.body["messageId"]?.string.flatMap(UUID.init(uuidString:)) {
                taken(id, newTurn: event.body["newTurn"]?.bool ?? false)
            }
        case "message.cancelled":
            if let id = event.body["messageId"]?.string.flatMap(UUID.init(uuidString:)) { handBack(id) }
        case "turn.done":
            // Messages sent during the turn that it ended without taking up are the next turn's.
            nextFollows = !waiting.isEmpty && (event.body["waiting"]?.int ?? 0) > 0
            running = nextFollows
            if let sessionId = event.body["sessionId"]?.string { chat.sessionId = sessionId }
            chat.costUSD += event.body["costUSD"]?.double ?? 0
            if let used = event.body["context"]?["used"]?.int, used > 0 {
                chat.contextUsed = used
                chat.contextWindow = event.body["context"]?["window"]?.int ?? chat.contextWindow
            }
            record(event.name, event.body)
            if !QueuedMessage.endedByItself(event.body["stopReason"]?.string, failed: failed) { handBackQueue() }
            flush()
        default:
            break
        }
    }

    func answered(_ requestId: String, allow: Bool) {
        record("answer", ["event": "answer", "requestId": .string(requestId), "allow": .bool(allow)])
    }

    /// A command from the shell prompt starts: its block goes into the thread, which it starts if
    /// it hadn't, and is kept up to date by `shellEnded`.
    func shellStarted(_ run: ShellRun, id: UUID) {
        chat.started = true
        if !chat.titleIsCustom, chat.title == Chat.untitled { chat.title = Chat.title(from: run.command) }
        // A reply streaming meanwhile goes on in its own item, above the block, which is where
        // its event, written before the block's, puts it after a relaunch.
        let streaming = open
        shellEvents[id] = record("shell", run.body, id: id)
        open = streaming
    }

    /// A command's block as it stands now: ended, or read by Claude.
    func shellChanged(_ id: UUID, _ run: ShellRun) {
        guard let index = items.lastIndex(where: { $0.id == id }), let event = shellEvents[id] else { return }
        items[index] = .shell(id: id, run: run)
        event.payload = (try? run.body.data()) ?? event.payload
        unsaved = true
        flush()
    }

    /// A workflow's latest state: its one event, written again, and its call's card.
    private func workflowChanged(_ body: JSON) {
        guard let taskId = body["taskId"]?.string else { return }
        guard let event = workflowEvents[taskId] else {
            workflowEvents[taskId] = record("workflow", body)
            return
        }
        event.payload = (try? body.data()) ?? event.payload
        apply("workflow", body, id: event.id)
        unsaved = true
        flush()
    }

    /// Workflows the engine was running when it went, which went with it. Read back in at launch
    /// they're only shown stopped; the store has them stopped once an engine goes while they run.
    func endWorkflows(saving: Bool = true) {
        for event in workflowEvents.values {
            guard case .object(var body)? = try? JSONDecoder().decode(JSON.self, from: event.payload),
                  body["state"]?.string == "running"
            else { continue }
            body["state"] = "stopped"
            if saving {
                workflowChanged(.object(body))
            } else {
                apply("workflow", .object(body), id: event.id)
            }
        }
    }

    /// OriCode is quitting while the thread works, which isn't a stop: the thread is marked for the
    /// next launch, and what has streamed so far is written down. Working is what the mark shows,
    /// a turn running or a subagent or background command out, since the CLI that ran them goes too.
    func quitting() {
        guard working else { return }
        chat.quitMidTurn = true
        unsaved = true
        flush()
    }

    /// One of the asks from before a quit has its answer, which goes to the session in a message
    /// of its own. Any other still up is over, since Claude asks again for what it still needs,
    /// and so are the calls they held: Claude makes them again.
    func answeredAfterQuit(_ requestId: String, allow: Bool) {
        answered(requestId, allow: allow)
        settleAfterQuit(except: requestId)
    }

    /// Stop on a thread waiting from before a quit. Nothing runs to interrupt, so the turn ends
    /// here, the way a stopped one does.
    func stopAfterQuit() {
        guard waitingAfterQuit else { return }
        settleAfterQuit(except: nil)
        record("turn.done", ["event": "turn.done", "stopReason": "interrupted"])
        running = false
        handBackQueue()
    }

    private func settleAfterQuit(except answered: String?) {
        for requestId in askedBeforeQuit.sorted() where requestId != answered {
            record("ask.cancelled", ["event": "ask.cancelled", "requestId": .string(requestId)])
        }
        askedBeforeQuit = []
        chat.quitMidTurn = false
        finishOpenTools()
        flush()
    }

    /// Streaming deltas only touch objects in memory; the store is written here.
    func flush() {
        guard unsaved || context.hasChanges else { return }
        unsaved = false
        chat.updatedAt = .now
        try? context.save()
    }

    func stopped() {
        heads.clear()
        handBackQueue()
        guard running else { return }
        running = false
        nextFollows = false
        retrying = nil
        finishOpenTools()
        flush()
    }

    /// Tools that never got their result, because the turn was stopped or the engine went away,
    /// didn't happen: marked failed, so an edit shows as the failed line a denied one gets rather
    /// than a card with its change counted, and stays out of the turn's files.
    private func finishOpenTools(except waiting: Set<String> = []) {
        for index in items.indices {
            if case .tool(let id, var call) = items[index], call.result == nil, !waiting.contains(call.toolUseId) {
                call.result = ""
                call.isError = true
                items[index] = .tool(id: id, call: call)
            }
        }
    }

    @discardableResult
    private func record(_ kind: String, _ body: JSON, keepOpen: Bool = false, id: UUID? = nil) -> Event {
        let event = Event(turn: turn, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
        if let id { event.id = id }
        seq += 1
        context.insert(event)
        event.chat = chat
        unsaved = true
        open = nil
        apply(kind, body, id: event.id)
        if keepOpen, let last = items.indices.last { open = (last, event, kind) }
        if !keepOpen { flush() }
        return event
    }

    private func apply(_ kind: String, _ body: JSON, id: UUID) {
        switch kind {
        case "user":
            let images = body["images"]?.array?.compactMap { $0.string.flatMap { Data(base64Encoded: $0) } } ?? []
            items.append(.user(id: id, text: body["text"]?.string ?? "", images: images, midTurn: body["midTurn"]?.bool ?? false))
        case "text":
            items.append(.text(id: id, text: body["delta"]?.string ?? ""))
        case "thinking":
            items.append(.thinking(id: id, text: body["delta"]?.string ?? ""))
        case "tool.use":
            let call = ToolCall(toolUseId: body["toolUseId"]?.string ?? "", name: body["name"]?.string ?? "", input: body["input"] ?? .null)
            items.append(.tool(id: id, call: call))
        case "tool.result":
            let toolUseId = body["toolUseId"]?.string
            if let index = items.lastIndex(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
               case .tool(let itemId, var call) = items[index]
            {
                call.result = body["content"]?.string ?? ""
                call.isError = body["isError"]?.bool ?? false
                call.patch = body["patch"]?.array?.map { hunk in
                    Hunk(
                        oldStart: hunk["oldStart"]?.int ?? 0,
                        newStart: hunk["newStart"]?.int ?? 0,
                        lines: hunk["lines"]?.array?.compactMap(\.string) ?? [])
                }
                items[index] = .tool(id: itemId, call: call)
            }
        case "workflow":
            let toolUseId = body["toolUseId"]?.string
            if let index = items.lastIndex(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
               case .tool(let itemId, var call) = items[index]
            {
                call.workflow = WorkflowRun(body)
                items[index] = .tool(id: itemId, call: call)
            }
        case "ask":
            let ask = PendingAsk(
                requestId: body["requestId"]?.string ?? "",
                kind: body["kind"]?.string ?? "permission",
                tool: body["tool"]?.string ?? "",
                input: body["input"] ?? .null,
                options: body["options"],
                toolUseId: body["toolUseId"]?.string)
            items.append(.ask(id: id, ask: ask))
        case "answer", "ask.cancelled":
            let requestId = body["requestId"]?.string
            let state: PendingAsk.State = kind == "ask.cancelled" ? .cancelled : (body["allow"]?.bool == true ? .allowed : .denied)
            if let index = items.lastIndex(where: { if case .ask(_, let ask) = $0 { ask.requestId == requestId } else { false } }),
               case .ask(let itemId, var ask) = items[index], ask.state == .waiting
            {
                ask.state = state
                items[index] = .ask(id: itemId, ask: ask)
            }
        case "turn.done":
            var footer = TurnFooter(
                durationMs: body["durationMs"]?.double ?? 0,
                costUSD: body["costUSD"]?.double ?? 0,
                stopReason: body["stopReason"]?.string ?? "")
            var paths = Set<String>()
            for item in items.reversed() {
                if item.startsTurn { break }
                guard case .tool(_, let call) = item, call.isEdit, call.result != nil, !call.isError,
                      let diff = Diff.of(call, cwd: chat.cwd)
                else { continue }
                paths.insert(diff.path)
                footer.added += diff.added
                footer.deleted += diff.deleted
            }
            footer.files = paths.count
            items.append(.footer(id: id, footer: footer))
        case "error", "note":
            items.append(.note(id: id, text: body["message"]?.string ?? body["text"]?.string ?? ""))
        case "limited":
            let resetsAt = Date(timeIntervalSince1970: (body["resetsAt"]?.double ?? 0) / 1000)
            items.append(.limited(id: id, resetsAt: resetsAt, window: body["window"]?.string))
        case "shell":
            items.append(.shell(id: id, run: ShellRun(body)))
        case "compacted":
            let before = body["before"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            let after = body["after"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            items.append(.note(id: id, text: before.map { "Compacted from \($0) tokens to \(after ?? "less")." } ?? "Compacted the conversation."))
        default:
            break
        }
    }
}

extension Item {
    var text: String? {
        switch self {
        case .text(_, let text), .thinking(_, let text), .user(_, let text, _, _), .note(_, let text): text
        default: nil
        }
    }

    /// A message sent between turns, which starts one. One Claude took up mid-turn doesn't.
    var startsTurn: Bool {
        if case .user(_, _, _, let midTurn) = self { !midTurn } else { false }
    }
}
