import Foundation
import Observation
import OSLog
import SwiftData
import SwiftUI

struct Hunk: Hashable {
    let oldStart: Int
    let newStart: Int
    let lines: [String]

    /// A patch as the engine sends it, `[{ oldStart, newStart, lines }]`.
    static func list(_ patch: JSON?) -> [Hunk]? {
        patch?.array?.map { hunk in
            Hunk(
                oldStart: hunk["oldStart"]?.int ?? 0,
                newStart: hunk["newStart"]?.int ?? 0,
                lines: hunk["lines"]?.array?.compactMap(\.string) ?? [])
        }
    }
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
    /// On the TodoWrite call that first wrote a plan, the plan as its latest call has it. A later
    /// call that carries the plan on has none, and no line of its own.
    var plan: Plan?
    /// What the call does. Apply sets it once from the event, or from Claude Code's name when the
    /// event says nothing, so neither the fold nor a line reads the names table per body.
    var declared: ToolKind?
    /// The arguments the app shows, in the words every agent's are told in: path, command,
    /// pattern, url, query, description, todos and patch. Claude's calls have none, and their
    /// input is read instead.
    var view: JSON = .null
    /// When its tool.use came, which for a command is when it began to run.
    var startedAt: Date?
    /// A command's own exit code, from an agent that sends one.
    var exitCode: Int?
    /// A command sent to the background, whose result says only where its output goes.
    var background = false
    /// How a background command ended, once that came: completed, failed or stopped.
    var ended: String?
    /// On a call that starts a subagent: whether what the subagent calls is kept under it.
    var keepsCalls = false
    /// The call Stop cut off, the turn's last, which didn't fail of itself.
    var stopped = false

    var kind: ToolKind { declared ?? ToolKind(claude: name) }

    var isEdit: Bool { kind == .edit || kind == .write }

    /// Whether the call is under a name Claude Code gives that kind, "Bash" or "Grep", rather
    /// than an agent's own title for it.
    var namedByClaude: Bool { ToolKind(claude: name) == kind }

    /// An argument the view names, or else Claude's input under the same key.
    func shown(_ key: String) -> String? {
        view[key]?.string ?? input[key]?.string
    }

    /// The file it's on, as given to the tool.
    var file: String? {
        view["path"]?.string ?? input["file_path"]?.string
    }
}

struct PendingAsk: Hashable {
    enum State: Hashable {
        case waiting
        case allowed
        case denied
        case cancelled
    }

    /// One of an agent's own answers to a permission ask: allow once, allow always, reject.
    struct Choice: Hashable {
        let id: String
        let name: String
        /// ACP's `allow_once`, `allow_always`, `reject_once` or `reject_always`.
        let kind: String
        /// What the agent does with it beyond this call, such as Cursor's allowlist.
        var help: String? = nil

        var allows: Bool { kind.hasPrefix("allow") }
    }

    let requestId: String
    let kind: String
    let tool: String
    let input: JSON
    let options: JSON?
    var state: State = .waiting
    /// The call it holds, whose line waits with it.
    var toolUseId: String?
    /// What the call asked about does, set in apply as a ToolCall's is.
    var declared: ToolKind?
    var view: JSON = .null
    /// The agent's own answers, when it gave them; Claude's asks have none.
    var choices: [Choice] = []
    /// The head's worker that asked, when one did.
    var worker: Worker?
    /// The worker, subagent or workflow agent that asked, by the id its thread keeps in
    /// `agentID`; nil when the thread's own loop did.
    var agentID: String?
    /// When it came, which orders the asks of every thread in the queue.
    var askedAt: Date = .distantPast
    /// The thread that answered it for the user, and why, when one did (K-296).
    var answeredBy: String?
    var answerReason: String?
    /// Each time a thread it went to first sent it up, oldest first.
    var passes: [Pass] = []

    /// A thread sending an ask up: to the thread above it, or to the user when `to` is nil.
    struct Pass: Hashable {
        let by: String
        let to: String?
        let reason: String
    }

    /// A worker as its ask names it: the agent it runs on and its task.
    struct Worker: Hashable {
        let agent: String
        let label: String
    }

    var toolKind: ToolKind { declared ?? ToolKind(claude: tool) }

    /// The app an agent asks to see and use, on an ask of the engine's own (K-290).
    var app: String? { tool == "Mac" ? input["app"]?.string : nil }

    /// What a menu tool would loosen, on an ask of the engine's own, which only the user answers (K-303).
    var loosening: String? { tool == "OriCode" ? input["change"]?.string : nil }

    /// The call it asks about, as a line would show it.
    var call: ToolCall {
        ToolCall(toolUseId: toolUseId ?? "", name: tool, input: input, declared: declared, view: view)
    }
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
    /// A limit getting close: how much of its window is used, when that resets, and when it was said.
    case nearLimit(id: UUID, window: String, used: Double, resetsAt: Date, said: Date)
    /// A command run from the composer's shell prompt.
    case shell(id: UUID, run: ShellRun)
    /// A thread this one opened ended its first turn: which, its name then, and whether the turn
    /// ended by itself; or a limit stopped it and it waits, until `resetsAt`, for `window` to reset.
    case opened(id: UUID, thread: UUID, title: String, finished: Bool, resetsAt: Date? = nil, window: String? = nil)
    /// A thread the agent suggested for something outside the task: the button's words, and the
    /// message a thread made from it would start on.
    case suggested(id: UUID, title: String, prompt: String)
    /// One thread opened, messaged or stopped another: the line both get, with the other thread,
    /// the line's words and what its hover says, the agent's reason among it.
    case act(id: UUID, thread: UUID, text: String, hover: String)
    /// The head moved itself to another model or level: where to, and the reason it gave.
    case changed(id: UUID, text: String, reason: String)
    /// A turn OriCode started on its own, a plan's ends told to the thread running it. Its prompt
    /// is the app's and draws nothing: the reply follows whatever came before.
    case woke(id: UUID)

    var id: UUID {
        switch self {
        case .user(let id, _, _, _), .text(let id, _), .thinking(let id, _), .tool(let id, _), .ask(let id, _),
             .footer(let id, _), .note(let id, _), .limited(let id, _, _), .nearLimit(let id, _, _, _, _), .shell(let id, _),
             .opened(let id, _, _, _, _, _), .suggested(let id, _, _), .act(let id, _, _, _), .changed(let id, _, _), .woke(let id):
            id
        }
    }
}

/// A stored event as a conversation replays it, read and decoded where the main thread
/// needn't wait for it.
struct StoredEvent: Sendable {
    let id: UUID
    let kind: String
    let turn: Int
    let seq: Int
    /// Nil for a payload that doesn't decode, which still counts for the turn and the order.
    let body: JSON?
    let createdAt: Date
    /// For the events a conversation writes again, a command's and a workflow's.
    let model: PersistentIdentifier?

    /// A thread's events in order, from any context: opening a thread reads them on a context of
    /// its own, off the main thread.
    nonisolated static func read(_ chatID: UUID, from context: ModelContext) throws -> [StoredEvent] {
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.chat?.id == chatID }, sortBy: [SortDescriptor(\.seq)])
        return try context.fetch(descriptor).map { event in
            StoredEvent(
                id: event.id, kind: event.kind, turn: event.turn, seq: event.seq,
                body: try? JSONDecoder().decode(JSON.self, from: event.payload), createdAt: event.createdAt,
                model: event.kind == "shell" || event.kind == "workflow" ? event.persistentModelID : nil)
        }
    }
}

/// The item a reply or its thinking is streaming into, and its text so far. Only that item's
/// view reads it, so a delta draws the reply and nothing else in the transcript.
@MainActor
@Observable
final class LiveText {
    fileprivate(set) var id: UUID?
    fileprivate(set) var text = ""
}

/// The display's frame, at which every thread's held deltas are shown at once: two replies
/// streaming side by side are laid out and committed once a frame, and not each at a moment of
/// its own that cuts the frame in two. Past the open thread's stream a frame does one costly
/// thing at most: the thread beside growing, or a reply's block made again. It runs only while
/// a delta is held or a block waits.
@MainActor
final class StreamClock: NSObject {
    static let shared = StreamClock()
    /// Ticks when told to, as a test does, and never by itself.
    private let manual: Bool
    private var link: CADisplayLink?
    private var waiting: [Conversation] = []
    /// Blocks waiting for a frame to be made again in, oldest first.
    private var makers: [(id: UUID, resume: CheckedContinuation<Void, Never>)] = []
    private var count = 0
    /// The frame each thread shown every other one was last shown in, while that's recent.
    private var shown: [ObjectIdentifier: Int] = [:]
    /// A frame already full before anything shows in it: the one after a block was made again,
    /// whose drawing spills into it, or the one a new row was added for.
    private var fullAt = Int.min

    init(manual: Bool = false) {
        self.manual = manual
        super.init()
        guard !manual else { return }
        // A link made on a display that's gone, or that the window has left, keeps the wrong
        // time or none, and what's held would wait for the next event recorded.
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
        }
    }

    func wait(for conversation: Conversation) {
        guard !waiting.contains(where: { $0 === conversation }) else { return }
        waiting.append(conversation)
        start()
    }

    /// Returns in a frame with room for a block to be made again in, one block a frame: made
    /// beside another stream growing, or with a block starting, it cost two frames.
    func frameToMake() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                makers.append((id, resume))
                start()
            }
        } onCancel: {
            Task { @MainActor in self.release(id) }
        }
    }

    /// A row was added to a transcript on screen, which costs the coming frame 10 ms.
    func fill() {
        fullAt = count + 1
    }

    func forget(_ conversation: Conversation) {
        waiting.removeAll { $0 === conversation }
        shown[ObjectIdentifier(conversation)] = nil
    }

    private func release(_ id: UUID) {
        guard let index = makers.firstIndex(where: { $0.id == id }) else { return }
        makers.remove(at: index).resume.resume()
    }

    private func start() {
        guard link == nil, !manual else { return }
        // The display the window is on, which mainWindow doesn't say while the app is in the
        // background. A view's own link would stop with its window, and a window can close
        // mid-stream.
        let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        guard let screen = window?.screen ?? NSScreen.main else {
            // No display to keep time by: everything at once.
            for conversation in waiting { conversation.showHeld() }
            waiting = []
            while !makers.isEmpty { makers.removeFirst().resume.resume() }
            return
        }
        let link = screen.displayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func restart() {
        guard let link else { return }
        link.invalidate()
        self.link = nil
        start()
    }

    @objc private func frame() {
        tick()
    }

    func tick() {
        count += 1
        // The open thread every frame. A block it starts fills the frame, as a row added and
        // what a block made again the frame before has left to draw already have; a block that
        // would start in a full frame waits for the next with room.
        var busy = fullAt == count
        for conversation in waiting where !conversation.everyOtherFrame() {
            if conversation.showHeld(startingAtMost: busy ? 0 : 1) { busy = true }
        }
        for conversation in waiting where conversation.everyOtherFrame() {
            let id = ObjectIdentifier(conversation)
            guard Self.besideShows(since: shown[id].map { count - $0 }, busy: busy) else { continue }
            conversation.showHeld(startingAtMost: busy ? 0 : 1)
            shown[id] = count
            busy = true
        }
        if !busy, !makers.isEmpty {
            makers.removeFirst().resume.resume()
            fullAt = count + 1
        }
        for conversation in waiting where !conversation.holds { conversation.caughtUp() }
        waiting.removeAll { !$0.holds }
        shown = shown.filter { count - $1 < 3 }
        guard waiting.isEmpty, makers.isEmpty else { return }
        link?.invalidate()
        link = nil
    }

    /// Whether the thread beside shows in this frame, last shown `since` frames ago: every other
    /// frame, a frame later when this one is full, and never later than the third.
    static func besideShows(since: Int?, busy: Bool) -> Bool {
        let since = since ?? 2
        return since >= 3 || since >= 2 && !busy
    }
}

/// One thread's transcript: the stored events replayed into items, then kept current
/// from the engine's live events. Streaming text lands in one event per assistant
/// message, updated in place.
@MainActor
@Observable
final class Conversation {
    /// Every item, the streaming one's text included. A delta changes that text without telling
    /// what reads `items`, which would lay the whole transcript out again for it: the streaming
    /// item's own view follows `live` instead.
    private(set) var items: [Item] {
        get {
            access(keyPath: \.items)
            return stored
        }
        set {
            withMutation(keyPath: \.items) { stored = newValue }
        }
        _modify {
            access(keyPath: \.items)
            _$observationRegistrar.willSet(self, keyPath: \.items)
            defer { _$observationRegistrar.didSet(self, keyPath: \.items) }
            yield &stored
        }
    }
    @ObservationIgnored private var stored: [Item] = []
    /// The text of the item still streaming, as it grows.
    let live = LiveText()
    /// Whether it has anything in it yet. Kept apart from `items`, so a view that only asks this
    /// isn't drawn again by every delta.
    private(set) var started = false
    /// The oldest ask still waiting, which is the one Return and Esc answer.
    private(set) var waitingAsk: PendingAsk?
    /// Every ask still waiting, oldest first, which the queue of everything waiting reads.
    private(set) var waitingAsks: [PendingAsk] = []
    private(set) var running = false
    /// Subagents, commands and workflows out for this thread, as the engine last listed them.
    let heads = Heads()
    /// What its session is estimated to have used in water, when Settings asks for that.
    let water = WaterMeter()
    /// What the head's workers have cost, which the thread's cost has in it and its own session
    /// never spent.
    private(set) var workerCost: Double = 0
    /// The edits workers brought into the thread's folder, which the review credits to their rays.
    private(set) var rayEdits: [RayEdit] = []
    /// What the head chose, oldest first: the workers it started and its own moves, with why.
    private(set) var choices: [HeadChoice] = []
    /// What each subagent called, by the call that started it. The transcript draws none of
    /// it; the review reads what a subagent ran and what it edited.
    @ObservationIgnored private(set) var under: [String: [ToolCall]] = [:]
    /// "Trying again, 1 of 10…" while the CLI retries, which the transcript puts after "Can't
    /// reach" and the agent; a live line, never stored.
    private(set) var retrying: String?
    /// Fast mode as the CLI last reported it: on, off or cooldown, and why it can't be on.
    /// What the thread's own CLI says it runs at, once it has started: the level (nil when the
    /// model has none) and whether Ultracode came on.
    private(set) var appliedEffort: String??
    private(set) var appliedUltracode: Bool?
    /// Whether the CLI that gave that reading was started as Ultracode.
    private(set) var askedUltracode = false
    /// Whether the thread's CLI has the Workflow tool, which workflows off in /config take away;
    /// nil until one has said.
    private(set) var workflowsAvailable: Bool?
    /// The level read while the thread picked none, and for which model: where Default really
    /// lands, project settings included, which the engine's first reading with the user's
    /// settings alone can't know.
    private(set) var defaultReading: (model: String?, level: String?)?
    private(set) var turn = 0
    /// Counts the messages sent by hand, from the field or a queued line's Send now, which bring
    /// the transcript to its end; one the queue sends by itself leaves what's being read alone.
    private(set) var handSent = 0
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
    /// Whether the latest turn ended by itself, neither stopped nor failed.
    private(set) var endedByItself = true
    /// What goes under a turn that's still running here, for its end: lines for threads this one
    /// opened whose first turn ended meanwhile, and the threads the turn suggested.
    @ObservationIgnored private var underTurn: [(kind: String, line: JSON)] = []
    /// Lines for the running turn written as it ends, ahead of its footer: asks it settled.
    @ObservationIgnored private var inTurn: [(kind: String, line: JSON)] = []
    /// The files this turn edited that another working thread of the project edited in its own
    /// turn, each with that thread, which wait_thread tells the thread waiting on this one.
    @ObservationIgnored private(set) var sameFiles: [SameFile] = []
    @ObservationIgnored private var writtenByCommands: Set<String> = []
    let chat: Chat
    private let context: ModelContext
    private var seq = 0
    @ObservationIgnored private var open: (item: Int, event: Event, kind: String)? {
        didSet {
            if let open { live.text = stored[open.item].text ?? "" }
            live.id = open?.event.id
        }
    }
    /// Deltas for the open item that haven't reached it yet: a stream reaches the view at the
    /// display's frame, once a frame at most.
    private var held = ""
    /// A reply's first deltas in the thread beside, waiting for a frame with room for its row.
    @ObservationIgnored private var opening: (kind: String, text: String)?
    /// Whether streaming text is shown every other frame, asked at each frame: so while the
    /// thread is drawn beside an open one that's working too, since two replies laid out in one
    /// frame don't fit it.
    @ObservationIgnored var everyOtherFrame: () -> Bool = { false }
    /// Whether the thread is on screen, where a block its reply starts costs a frame's room.
    @ObservationIgnored var drawn: () -> Bool = { true }
    /// The frame its deltas wait for.
    @ObservationIgnored var clock = StreamClock.shared
    private var shownAt = ContinuousClock.now
    private var unsaved = false
    /// Whether the open item's text is ahead of its event and of ⌘K's fold of it.
    @ObservationIgnored private var ahead = false
    /// When the open item's text was last put on its event, and how long a stream goes before it
    /// is again, which is the most of a reply a crash takes with it: the store saves what has
    /// changed on its own, and a delta alone changes nothing of the store's.
    @ObservationIgnored private var wroteAt = ContinuousClock.now
    @ObservationIgnored var keeps = Duration.seconds(2)
    /// ⌘K's index of what was said, kept up as messages and replies are written.
    private let said: MessageIndex?
    /// Where the pictures you send are kept in full. Nil keeps nothing, as in a test.
    let pictures: SentPictures?
    /// Each command's event, updated when it ends and when Claude reads it.
    private var shellEvents: [UUID: Event] = [:]
    /// Each workflow's one event, by its task, written again as it moves.
    private var workflowEvents: [String: Event] = [:]
    /// Claude's plan as its latest TodoWrite has it, and the item whose card shows it.
    private(set) var plan: Plan?
    private var planCard: UUID?

    convenience init(chat: Chat, context: ModelContext, said: MessageIndex? = nil, pictures: SentPictures? = nil) {
        let stored: [StoredEvent]
        do {
            stored = try StoredEvent.read(chat.id, from: context)
        } catch {
            // Made for an event or a send, which can't wait for a read that failed: the log keeps it.
            Logger(subsystem: "com.realmeric.oricode", category: "transcript")
                .error("Couldn't read transcript \(chat.id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stored = []
        }
        self.init(chat: chat, context: context, stored: stored, said: said, pictures: pictures)
    }

    init(chat: Chat, context: ModelContext, stored: [StoredEvent], said: MessageIndex? = nil, pictures: SentPictures? = nil) {
        self.chat = chat
        self.context = context
        self.said = said
        self.pictures = pictures
        for event in stored {
            seq = max(seq, event.seq + 1)
            turn = max(turn, event.turn)
            guard let body = event.body else { continue }
            if let model = event.model, let object = context.model(for: model) as? Event {
                if event.kind == "shell" { shellEvents[event.id] = object }
                if event.kind == "workflow", let taskId = body["taskId"]?.string { workflowEvents[taskId] = object }
            }
            apply(event.kind, body, id: event.id, at: event.createdAt)
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
        findWaitingAsk()
        running = waitingAfterQuit
        finishOpenTools(except: waitingCalls)
    }

    /// When the thread goes on by itself, once the limit that stopped it resets.
    var resumeAt: Date? {
        chat.resumeAt
    }

    /// The latest limit's card, the one a waiting thread waits out.
    var lastLimit: UUID? {
        latestLimit?.id
    }

    /// Which limit that was.
    var lastLimitWindow: String? {
        if case .limited(_, _, let window) = latestLimit { window } else { nil }
    }

    private var latestLimit: Item? {
        items.last { if case .limited = $0 { true } else { false } }
    }

    /// The call with this id, latest first.
    func call(_ toolUseId: String) -> ToolCall? {
        for item in items.reversed() {
            if case .tool(_, let call) = item, call.toolUseId == toolUseId { return call }
        }
        return nil
    }

    /// The footer under the thread's latest turn, where its water stands.
    var lastFooter: UUID? {
        items.last { if case .footer = $0 { true } else { false } }?.id
    }

    /// The limit that stopped the thread's latest turn, when one did.
    var turnLimit: (resetsAt: Date, window: String?)? {
        for item in items.reversed().drop(while: { if case .footer = $0 { true } else { $0.followsTurn } }) {
            if case .limited(_, let resetsAt, let window) = item { return (resetsAt, window) }
            if item.startsTurn { return nil }
            if case .footer = item { return nil }
        }
        return nil
    }

    /// The thread goes on by itself when the limit resets, whichever limit it is.
    func resume(at resetsAt: Date) {
        chat.resumeAt = resetsAt
        unsaved = true
        flush()
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

    /// Looked for again whenever an ask comes or goes, so what shows it isn't drawn again by
    /// every delta.
    private func findWaitingAsk() {
        let found = items.compactMap { item -> PendingAsk? in
            if case .ask(_, let ask) = item, ask.state == .waiting { ask } else { nil }
        }
        if found != waitingAsks { waitingAsks = found }
        if found.first != waitingAsk { waitingAsk = found.first }
    }

    /// Whether it has anything the composer mustn't lose by letting the conversation go.
    var holdsMessages: Bool {
        !waiting.isEmpty || !queue.isEmpty || !handedBack.isEmpty
    }

    func sentByHand() {
        handSent += 1
    }

    func userSent(_ text: String, previews: [Data] = [], id: UUID = UUID()) {
        turn += 1
        running = true
        failed = false
        chat.started = true
        // Written to again, it's a thread in use: back in the list.
        chat.archived = false
        chat.archivedWith = nil
        chat.quitMidTurn = false
        chat.resumeAt = nil
        if !chat.titleIsCustom, turn == 1 || chat.title == Chat.untitled {
            chat.title = Chat.title(from: text)
        }
        recordUser(text, previews: previews, midTurn: false, id: id)
    }

    /// A turn OriCode starts on its own with `text`, which is kept but never drawn.
    func woke(_ text: String) {
        turn += 1
        running = true
        failed = false
        chat.archived = false
        chat.archivedWith = nil
        chat.quitMidTurn = false
        chat.resumeAt = nil
        record("wake", ["event": "wake", "text": .string(text)])
    }

    /// A message a worker's head sent into its running turn, which doesn't start one.
    func sentIntoWorkerTurn(_ text: String) {
        recordUser(text, previews: [], midTurn: true, id: UUID())
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
        // Only the pictures with a preview show, so only they are kept, and in the bubble's order.
        let shown = images.compactMap { image in image.preview.map { (image: image, preview: $0) } }
        let message = WaitingMessage(id: UUID(), text: text, typed: typed ?? text, images: images, previews: shown.map { $0.preview })
        waiting.append(message)
        return message
    }

    /// Claude took a waiting message up: into the running turn, where it lands after everything
    /// so far with Claude's reply after it, or as a turn of its own. It keeps its id, so its
    /// bubble stays where it is.
    func taken(_ id: UUID, newTurn: Bool) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let message = waiting.remove(at: index)
        // Kept once it's part of the thread: one still waiting at a quit is gone, and its files
        // would have nothing to own them. Only the pictures with a preview show.
        let shown = message.previews.count == message.images.count ? message.images : message.images.filter { $0.preview != nil }
        pictures?.keep(shown, thread: chat.id, message: message.id)
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
            writeUnderTurn()
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

    /// The message that started a spent turn goes again in a new session: the thread works until
    /// that turn starts or its send fails.
    func resending() {
        running = true
        failed = false
    }

    func sendFailed(_ message: String) {
        running = false
        endedByItself = false
        handBackQueue()
        record("note", ["event": "note", "text": .string(message)])
        writeUnderTurn()
    }

    func note(_ message: String) {
        record("note", ["event": "note", "text": .string(message)])
    }

    /// How many turns have ended, which for a thread another opened says when its first has.
    var turnsEnded: Int {
        items.count { if case .footer = $0 { true } else { false } }
    }

    /// A thread this one opened ended its first turn: one stored line. A turn running here keeps
    /// its reply and its run of calls whole, so the line waits for that turn's end.
    func threadDone(_ thread: Chat, _ told: OpenedLine.Told) {
        let line = Self.threadDone(thread, told)
        guard !running else { return underTurn.append(("thread.done", line)) }
        record("thread.done", line)
    }

    private static func threadDone(_ thread: Chat, _ told: OpenedLine.Told) -> JSON {
        var line: [String: JSON] = ["event": "thread.done", "thread": .string(thread.id.uuidString), "title": .string(thread.title), "finished": .bool(told.finished)]
        if let waiting = told.waiting {
            line["resetsAt"] = .number(waiting.resetsAt.timeIntervalSince1970 * 1000)
            if let window = waiting.window { line["window"] = .string(window) }
        }
        return .object(line)
    }

    /// The same line for a thread whose transcript isn't in memory, written after its last event
    /// without reading the rest.
    static func threadDone(_ thread: Chat, _ told: OpenedLine.Told, unread chat: Chat, in context: ModelContext) {
        line("thread.done", threadDone(thread, told), unread: chat, in: context)
    }

    /// A line stored after a thread's last event, its transcript left unread.
    static func line(_ kind: String, _ line: JSON, unread chat: Chat, in context: ModelContext) {
        let id = chat.id
        var last = FetchDescriptor<Event>(predicate: #Predicate { $0.chat?.id == id }, sortBy: [SortDescriptor(\.seq, order: .reverse)])
        last.fetchLimit = 1
        let latest = try? context.fetch(last).first
        let event = Event(turn: latest?.turn ?? 0, seq: (latest?.seq ?? -1) + 1, kind: kind, payload: (try? line.data()) ?? Data())
        context.insert(event)
        event.chat = chat
        chat.updatedAt = .now
    }

    /// A line for something one thread did to another, here or to this one: stored now, or at the
    /// end of a turn running here, as a thread's finished first turn is.
    func threadAct(_ act: ThreadAct) {
        let line = act.json
        if !running {
            record("thread.act", line)
        } else if act.isAsk {
            // An ask settled belongs to the turn it was asked in, so its line goes above that turn's footer.
            inTurn.append(("thread.act", line))
        } else {
            underTurn.append(("thread.act", line))
        }
    }

    /// A line under the turn for a file this thread and another both edit, as threadAct's.
    func sameFile(_ same: SameFile) {
        if same.with == nil { sameFiles.append(same) }
        guard !running else { return underTurn.append(("thread.overlap", same.json)) }
        record("thread.overlap", same.json)
    }

    /// The file a call that just came back edited, from the thread's folder, or nil for a call
    /// that edits none or failed.
    func editedFile(_ toolUseId: String?) -> String? {
        guard let toolUseId, let item = items.last(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
              case .tool(_, let call) = item
        else { return nil }
        return Self.edited(call, cwd: chat.cwd)
    }

    /// The start of a command the thread's agent ran, for the call `toolUseId`.
    func commandStarted(_ toolUseId: String?) -> Date? {
        guard let toolUseId, let item = items.last(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
              case .tool(_, let call) = item, call.kind == .run
        else { return nil }
        return call.startedAt
    }

    /// Files a command of the running turn wrote, as git listed them.
    func commandWrote(_ paths: [String]) {
        writtenByCommands.formUnion(paths)
    }

    /// Every file the turn running here has edited, from the thread's folder: by an edit tool, or
    /// by a command as git told of it.
    var editedThisTurn: Set<String> {
        var paths = writtenByCommands
        for item in items.reversed() {
            if item.startsTurn { break }
            if case .tool(_, let call) = item, let path = Self.edited(call, cwd: chat.cwd) { paths.insert(path) }
        }
        return paths
    }

    private static func edited(_ call: ToolCall, cwd: String) -> String? {
        guard call.isEdit || call.kind == .delete || call.kind == .move, call.result != nil, !call.isError, let file = call.file else { return nil }
        return ToolSummary.relative(file, to: cwd)
    }

    private func writeInTurn() {
        for (kind, line) in inTurn { record(kind, line) }
        inTurn = []
    }

    private func writeUnderTurn() {
        writeInTurn()
        for (kind, line) in underTurn { record(kind, line) }
        underTurn = []
    }

    func receive(_ event: EngineEvent) {
        if event.name != "retrying" { retrying = nil }
        switch event.name {
        case "effort":
            let level = event.body["level"]?.string
            let asked = event.body["asked"]?.string
            appliedEffort = .some(level)
            appliedUltracode = event.body["ultracode"]?.bool ?? false
            askedUltracode = event.body["askedUltracode"]?.bool ?? false
            if asked == nil { defaultReading = (chat.model, level) }
        case "workflowTool":
            workflowsAvailable = event.body["available"]?.bool
        case "heads":
            heads.update(event.body, agent: chat.providerID)
        case "retrying":
            let attempt = event.body["attempt"]?.int ?? 0
            let max = event.body["max"]?.int ?? 0
            retrying = "Trying again, \(attempt) of \(max)…"
        case "turn.started":
            running = true
            sameFiles = []
            writtenByCommands = []
            // A turn nobody sent, a background agent reporting back, doesn't carry the last one's error.
            failed = false
            // A session of the new agent's own is up, and has been handed the thread.
            if chat.handover { chat.handover = false }
            if let sessionId = event.body["sessionId"]?.string, chat.sessionId != sessionId {
                chat.sessionId = sessionId
                unsaved = true
            }
            // A turn nobody sent says what it left running ended and woke it.
            if let woke = event.body["woke"]?.string {
                record("note", ["event": "note", "text": .string(woke)])
            }
        case "text", "thinking":
            let delta = event.body["delta"]?.string ?? ""
            if let open, open.kind == event.name {
                hold(delta)
            } else if everyOtherFrame() || opening?.kind == event.name {
                // A new row costs its frame 10 ms, so beside the open thread it waits for one with
                // room, and the deltas after it join it there, paced or not, so the reply stays one row.
                if let opening, opening.kind != event.name { openHeld() }
                opening = (event.name, (opening?.text ?? "") + delta)
                clock.wait(for: self)
            } else {
                record(event.name, ["event": .string(event.name), "delta": .string(delta)], keepOpen: true)
            }
        case "limited":
            // Refused by a limit, the turn didn't end by itself, and the queue's next would only be
            // refused too: it goes back to the field.
            failed = true
            record(event.name, event.body)
            if Limit.goesOn, let resetsAt = event.body["resetsAt"]?.double.map({ Date(timeIntervalSince1970: $0 / 1000) }),
               Limit.resumes(window: event.body["window"]?.string, resetsAt: resetsAt) {
                // Refused again past the reset, a Mac's clock ahead of Claude's: a while longer.
                chat.resumeAt = resetsAt > .now ? resetsAt : .now.addingTimeInterval(300)
                flush()
            }
        case "limits":
            nearLimit(event.body)
        case "session.lost":
            chat.sessionId = nil
            water.forget()
            record("note", ["event": "note", "text": "The earlier session is gone, so this thread carries on in a new one."])
        case "compacted":
            chat.contextUsed = event.body["after"]?.int ?? 0
            record(event.name, event.body)
        case "head.changed":
            // The head moved itself: the thread is on what it chose, so the next send carries it,
            // and the line saying why stays where it moved.
            if let model = event.body["model"]?.string, event.body["modelChanged"]?.bool == true { chat.model = model }
            chat.effort = event.body["effort"]?.string
            record(event.name, event.body)
        case "worker":
            // A worker's turn: its cost is the thread's too, and its edits are credited to its ray.
            chat.costUSD += event.body["costUSD"]?.double ?? 0
            record(event.name, event.body)
        case "head.chose":
            // Kept for ⌘I, without closing a reply that may be streaming beside it.
            keep(event.name, event.body)
        case "tool.use" where event.body["parent"]?.string != nil:
            keep("subagent.use", event.body)
        case "tool.result" where event.body["parent"]?.string != nil:
            keep("subagent.result", event.body)
        case "tool.ended":
            keep(event.name, event.body)
        case "tool.use", "tool.result", "ask", "ask.cancelled", "error", "note":
            if event.name == "error" { failed = true }
            record(event.name, event.body)
        case "ask.answered":
            // The thread's mode answered it, Don't ask or Plan picked while it waited, as the user would.
            if let requestId = event.body["requestId"]?.string { answered(requestId, allow: event.body["allow"]?.bool == true) }
        case "thread.suggested":
            // Under the reply it came with, which is still being written.
            guard running else {
                record(event.name, event.body)
                break
            }
            underTurn.append((event.name, event.body))
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
            // A session the model can't be sent again sends nothing more, the queue's next included.
            if event.body["spent"] != nil { failed = true }
            // Messages sent during the turn that it ended without taking up are the next turn's.
            nextFollows = !waiting.isEmpty && (event.body["waiting"]?.int ?? 0) > 0
            running = nextFollows
            if let sessionId = event.body["sessionId"]?.string { chat.sessionId = sessionId }
            chat.costUSD += event.body["costUSD"]?.double ?? 0
            if let used = event.body["context"]?["used"]?.int, used > 0 {
                chat.contextUsed = used
                chat.contextWindow = event.body["context"]?["window"]?.int ?? chat.contextWindow
            }
            writeInTurn()
            record(event.name, event.body)
            writeUnderTurn()
            endedByItself = QueuedMessage.endedByItself(event.body["stopReason"]?.string, failed: failed)
            if !endedByItself { handBackQueue() }
            flush()
        default:
            break
        }
    }

    /// The line where the head moved itself: "Opus · high", or "High" when only its level moved,
    /// "Default" for the model's own. Its reason is the line's hover.
    static func headChanged(_ body: JSON) -> String {
        let level = body["effort"]?.string.map { ModelMenu.effortName($0) }
        guard body["modelChanged"]?.bool == true else { return level ?? "Default" }
        let name = ModelMenu.shortName(body["name"]?.string ?? body["model"]?.string ?? "")
        return level.map { "\(name) · \($0.lowercased())" } ?? name
    }

    /// A limit nearing its ceiling puts one line in the thread each time its window fills: once
    /// said, it isn't said again until the reset it named has passed.
    private func nearLimit(_ body: JSON) {
        guard body["status"]?.string == "allowed_warning", let window = body["rateLimitType"]?.string,
              let used = body["utilization"]?.double ?? body["surpassedThreshold"]?.double,
              let resetsAt = body["resetsAt"]?.double.map({ Date(timeIntervalSince1970: $0 / 1000) })
        else { return }
        let said = items.contains { item in
            if case .nearLimit(_, window, _, let reset, _) = item { reset > .now } else { false }
        }
        guard !said else { return }
        record("limits", ["event": "limits", "rateLimitType": .string(window), "utilization": .number(used),
                          "resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000), "said": .number(Date.now.timeIntervalSince1970 * 1000)])
    }

    /// `by` is the thread that answered for the user, with its reason.
    func answered(_ requestId: String, allow: Bool, by: (title: String, reason: String)? = nil) {
        var body: [String: JSON] = ["event": "answer", "requestId": .string(requestId), "allow": .bool(allow)]
        if let by {
            body["by"] = .string(by.title)
            body["reason"] = .string(by.reason)
        }
        record("answer", .object(body))
    }

    /// The thread an ask went to first sent it up, to `to` or to the user, with its reason.
    func askPassed(_ requestId: String, _ pass: PendingAsk.Pass) {
        var body: [String: JSON] = ["event": "ask.passed", "requestId": .string(requestId), "by": .string(pass.by), "reason": .string(pass.reason)]
        if let to = pass.to { body["to"] = .string(to) }
        record("ask.passed", .object(body))
    }

    /// A command from the shell prompt starts: its block goes into the thread, which it starts if
    /// it hadn't, and is kept up to date by `shellEnded`.
    func shellStarted(_ run: ShellRun, id: UUID) {
        chat.started = true
        if !chat.titleIsCustom, chat.title == Chat.untitled { chat.title = Chat.title(from: run.command) }
        // A reply streaming meanwhile goes on in its own item, above the block, which is where
        // its event, written before the block's, puts it after a relaunch. A reply whose row
        // waits for the clock gets it first.
        writeHeld()
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
        apply("workflow", body, id: event.id, at: event.createdAt)
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
                // It ended with the engine just now. Read back at launch, when isn't known.
                if body["endedAt"] == nil { body["endedAt"] = .number((Date.now.timeIntervalSince1970 * 1000).rounded()) }
                workflowChanged(.object(body))
            } else {
                apply("workflow", .object(body), id: event.id, at: event.createdAt)
            }
        }
    }

    /// OriCode is quitting while the thread works, which isn't a stop: the thread is marked for the
    /// next launch, and what has streamed so far is written down. Working is what the mark shows,
    /// a turn running or a subagent or background command out, since the CLI that ran them goes too.
    func quitting() {
        guard working else { return }
        writeUnderTurn()
        // A worker's turn goes with the engine that ran it, and the next launch reads it Stopped.
        chat.quitMidTurn = chat.agentID == nil
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
        writeUnderTurn()
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

    /// A delta waits for the display's next frame, where every thread's are shown together.
    private func hold(_ delta: String) {
        held += delta
        clock.wait(for: self)
    }

    /// Whether deltas wait for the clock.
    fileprivate var holds: Bool { !held.isEmpty || opening != nil }

    /// What waits for the clock dropped unrecorded, for a thread being deleted, whose chat a
    /// row recorded later would point at.
    func forget() {
        opening = nil
        held = ""
        clock.forget(self)
        caughtUp()
    }

    /// Whether the reply is still showing a burst at the steady rate, which the turn's end waits
    /// for: shown with it, the rest of the burst would land in the footer's frame as one slab.
    var catchingUp: Bool {
        open?.kind == "text" && held.utf8.count > Self.steady && drawn()
    }

    @ObservationIgnored private var afterCatchingUp: (() -> Void)?

    func whenCaughtUp(_ next: @escaping () -> Void) {
        afterCatchingUp = next
    }

    fileprivate func caughtUp() {
        guard let next = afterCatchingUp else { return }
        afterCatchingUp = nil
        next()
    }

    /// The reply's row, made with the deltas that waited for it: with its first block alone
    /// unless it's `whole`, the rest held for the frames after.
    private func openHeld(whole: Bool = true) {
        guard let opening else { return }
        self.opening = nil
        var text = opening.text
        var rest = ""
        if !whole, opening.kind == "text", let first = Reply.split(text).first, first.utf8.count < text.utf8.count, text.hasPrefix(first) {
            rest = String(text.dropFirst(first.count))
            text = first
        }
        record(opening.kind, ["event": .string(opening.kind), "delta": .string(text)], keepOpen: true)
        held = rest
    }

    static let frame = Duration.seconds(NSScreen.main?.minimumRefreshInterval ?? 1.0 / 60)
    /// Characters a frame shows of a reply at the least, about 3,800 a second: well past what an
    /// agent streams, so only a burst is spread out.
    static let steady = 64

    /// The held deltas onto the open item, for the view. Its event and ⌘K's fold of it wait for
    /// `writeHeld`: the whole reply encoded and folded at every frame cost more with each one.
    /// A row added, or a block starting in a reply on screen, costs its frame 5 to 10 ms more,
    /// so the clock lets a frame start one block at most, or none when it's full: what's held
    /// shows as far as the next block's start and the rest waits for a frame with room. All of
    /// it when nothing is said. Whether a block or a row started.
    @discardableResult
    fileprivate func showHeld(startingAtMost allowed: Int? = nil) -> Bool {
        if opening != nil {
            guard allowed != 0 else { return false }
            openHeld(whole: allowed == nil)
            return true
        }
        guard let open, !held.isEmpty else { return false }
        let current = stored[open.item]
        let before = current.text ?? ""
        // A burst, many lines come at once from the agent, is shown over the next frames at a
        // steady rate rather than in one jump: a twelfth of what waits a frame, word by word.
        var shown = held
        var later = ""
        if allowed != nil, open.kind == "text", drawn(), held.utf8.count > Self.steady {
            let cap = max(Self.steady, held.count / 12)
            if cap < held.count {
                var cut = held.index(held.startIndex, offsetBy: cap)
                if let space = held[..<cut].lastIndex(where: \.isWhitespace) { cut = held.index(after: space) }
                later = String(held[cut...])
                shown = String(held[..<cut])
            }
        }
        var text = before + shown
        var rest = ""
        var starts = false
        if open.kind == "text", drawn() {
            let had = Reply.blocks(of: current.id, text: before).count
            let blocks = Reply.blocks(of: current.id, text: text)
            starts = blocks.count > had
            // Up to where the block after those allowed starts, when the blocks before it are
            // the text's start.
            if let allowed, had > 0, blocks.count > had + allowed {
                let kept = blocks.prefix(had + allowed).joined()
                if text.hasPrefix(kept) {
                    guard kept.utf8.count > before.utf8.count else { return false }
                    rest = String(text.dropFirst(kept.count))
                    text = kept
                    starts = allowed > 0
                }
            }
        }
        held = rest + later
        shownAt = .now
        stored[open.item] = open.kind == "text" ? .text(id: current.id, text: text) : .thinking(id: current.id, text: text)
        live.text = text
        if open.kind == "text" { said?.update(open.event.id, text: text) }
        if !ahead { wroteAt = shownAt }
        ahead = true
        unsaved = true
        if wroteAt.duration(to: shownAt) >= keeps { write() }
        return starts
    }

    /// The held deltas shown, and the open item's text onto its event, which the store takes at
    /// the next save. Before every save of it and before anything takes the item's place.
    private func writeHeld() {
        showHeld()
        write()
    }

    private func write() {
        guard ahead, let open else { return }
        ahead = false
        let text = stored[open.item].text ?? ""
        open.event.payload = (try? JSON.object(["event": .string(open.kind), "delta": .string(text)]).data()) ?? Data()
        if open.kind == "text" { said?.fold(open.event.id) }
    }

    /// Streaming deltas only touch objects in memory; the store is written here.
    func flush() {
        writeHeld()
        guard unsaved || context.hasChanges else { return }
        unsaved = false
        chat.updatedAt = .now
        try? context.save()
    }

    /// The held deltas into the store for a thread that reads this one (read_thread). Being read
    /// isn't work, so the thread's date stays as it is.
    func saveHeld() {
        writeHeld()
        if context.hasChanges { try? context.save() }
    }

    func stopped() {
        heads.clear()
        handBackQueue()
        guard running else { return }
        running = false
        nextFollows = false
        retrying = nil
        finishOpenTools()
        writeUnderTurn()
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
        writeHeld()
        let event = Event(turn: turn, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
        if let id { event.id = id }
        seq += 1
        context.insert(event)
        event.chat = chat
        unsaved = true
        open = nil
        apply(kind, body, id: event.id, at: event.createdAt)
        if kind == "user" || kind == "text" {
            said?.add(event.id, in: chat.id, user: kind == "user", text: body[kind == "user" ? "text" : "delta"]?.string ?? "")
        }
        if keepOpen, let last = items.indices.last { open = (last, event, kind) }
        if drawn() { clock.fill() }
        if !keepOpen { flush() }
        return event
    }

    /// A workflow agent's transcript as the engine read it from Claude Code's copy: each event
    /// stored and shown as it would have been live, saved once for the read.
    func transcribe(_ events: [JSON]) {
        for body in events {
            guard let kind = body["event"]?.string else { continue }
            let event = Event(turn: turn, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
            seq += 1
            context.insert(event)
            event.chat = chat
            apply(kind, body, id: event.id, at: event.createdAt)
            if kind == "user" || kind == "text" {
                said?.add(event.id, in: chat.id, user: kind == "user", text: body[kind == "user" ? "text" : "delta"]?.string ?? "")
            }
        }
        unsaved = true
        flush()
    }

    /// Stores an event the transcript has no item for, a subagent's call or a background
    /// command's ending, without closing the reply that may be streaming beside it. It's saved
    /// with whatever is saved next.
    private func keep(_ kind: String, _ body: JSON) {
        let event = Event(turn: turn, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
        seq += 1
        context.insert(event)
        event.chat = chat
        unsaved = true
        apply(kind, body, id: event.id, at: event.createdAt)
    }

    /// A call as its tool.use tells it.
    private func toolCall(_ body: JSON, at date: Date) -> ToolCall {
        let name = body["name"]?.string ?? ""
        return ToolCall(
            toolUseId: body["toolUseId"]?.string ?? "", name: name, input: body["input"] ?? .null,
            declared: ToolKind(body["kind"], tool: name), view: body["view"] ?? .null,
            startedAt: body["untimed"]?.bool == true ? nil : date,
            keepsCalls: body["subcalls"]?.bool ?? false)
    }

    /// What a tool.result says of its call.
    private func finish(_ call: inout ToolCall, _ body: JSON, at date: Date) {
        call.result = body["content"]?.string ?? ""
        call.isError = body["isError"]?.bool ?? false
        call.patch = Hunk.list(body["patch"])
        call.exitCode = body["exitCode"]?.int
        call.background = body["background"]?.bool ?? false
        // A command whose result is as old as its call was read out of a transcript, by
        // a build that didn't mark it, or came from an agent that tells of a call only
        // once it's over: either way when it began isn't known.
        if call.kind == .run, let started = call.startedAt, (0..<0.005).contains(date.timeIntervalSince(started)) { call.startedAt = nil }
    }

    private func apply(_ kind: String, _ body: JSON, id: UUID, at date: Date) {
        switch kind {
        case "user":
            let images = body["images"]?.array?.compactMap { $0.string.flatMap { Data(base64Encoded: $0) } } ?? []
            items.append(.user(id: id, text: body["text"]?.string ?? "", images: images, midTurn: body["midTurn"]?.bool ?? false))
        case "wake":
            items.append(.woke(id: id))
        case "text":
            items.append(.text(id: id, text: body["delta"]?.string ?? ""))
        case "thinking":
            items.append(.thinking(id: id, text: body["delta"]?.string ?? ""))
        case "tool.use":
            var call = toolCall(body, at: date)
            if call.kind == .plan { call.plan = planned(call.view["todos"] == nil ? call.input : call.view, at: id) }
            items.append(.tool(id: id, call: call))
        case "tool.result":
            let toolUseId = body["toolUseId"]?.string
            if let index = items.lastIndex(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
               case .tool(let itemId, var call) = items[index]
            {
                finish(&call, body, at: date)
                items[index] = .tool(id: itemId, call: call)
            }
        case "subagent.use":
            guard let parent = body["parent"]?.string else { break }
            under[parent, default: []].append(toolCall(body, at: date))
        case "subagent.result":
            let toolUseId = body["toolUseId"]?.string
            guard let parent = body["parent"]?.string, let index = under[parent]?.lastIndex(where: { $0.toolUseId == toolUseId }) else { break }
            finish(&under[parent]![index], body, at: date)
        case "tool.ended":
            let toolUseId = body["toolUseId"]?.string
            let status = body["status"]?.string
            if let index = items.lastIndex(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
               case .tool(let itemId, var call) = items[index]
            {
                call.ended = status
                items[index] = .tool(id: itemId, call: call)
            } else if let (parent, index) = under.lazy.compactMap({ parent, calls in calls.lastIndex { $0.toolUseId == toolUseId }.map { (parent, $0) } }).first {
                under[parent]![index].ended = status
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
            let tool = body["tool"]?.string ?? ""
            let ask = PendingAsk(
                requestId: body["requestId"]?.string ?? "",
                kind: body["kind"]?.string ?? "permission",
                tool: tool,
                input: body["input"] ?? .null,
                options: body["options"],
                toolUseId: body["toolUseId"]?.string,
                declared: ToolKind(body["toolKind"], tool: tool),
                view: body["view"] ?? .null,
                choices: (body["choices"]?.array ?? []).map { choice in
                    PendingAsk.Choice(
                        id: choice["id"]?.string ?? "", name: choice["name"]?.string ?? "", kind: choice["kind"]?.string ?? "",
                        help: choice["help"]?.string)
                },
                worker: body["worker"]?["agent"]?.string.map { PendingAsk.Worker(agent: $0, label: body["worker"]?["label"]?.string ?? "") },
                agentID: body["agentId"]?.string,
                askedAt: date)
            items.append(.ask(id: id, ask: ask))
        case "answer", "ask.cancelled":
            let requestId = body["requestId"]?.string
            let state: PendingAsk.State = kind == "ask.cancelled" ? .cancelled : (body["allow"]?.bool == true ? .allowed : .denied)
            if let index = items.lastIndex(where: { if case .ask(_, let ask) = $0 { ask.requestId == requestId } else { false } }),
               case .ask(let itemId, var ask) = items[index], ask.state == .waiting
            {
                ask.state = state
                ask.answeredBy = body["by"]?.string
                ask.answerReason = body["reason"]?.string
                items[index] = .ask(id: itemId, ask: ask)
            }
        case "ask.passed":
            let requestId = body["requestId"]?.string
            if let index = items.lastIndex(where: { if case .ask(_, let ask) = $0 { ask.requestId == requestId } else { false } }),
               case .ask(let itemId, var ask) = items[index], ask.state == .waiting
            {
                ask.passes.append(PendingAsk.Pass(by: body["by"]?.string ?? Chat.untitled, to: body["to"]?.string, reason: body["reason"]?.string ?? ""))
                items[index] = .ask(id: itemId, ask: ask)
            }
        case "turn.done":
            var footer = TurnFooter(
                durationMs: body["durationMs"]?.double ?? 0,
                costUSD: body["costUSD"]?.double ?? 0,
                stopReason: body["stopReason"]?.string ?? "")
            var paths = Set<String>()
            if footer.stopReason == "interrupted", let last = items.lastIndex(where: { if case .tool = $0 { true } else { $0.startsTurn } }),
               case .tool(let id, var call) = items[last], call.isError {
                call.stopped = true
                items[last] = .tool(id: id, call: call)
            }
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
        case "head.changed":
            items.append(.changed(id: id, text: Self.headChanged(body), reason: body["reason"]?.string ?? ""))
            if let choice = HeadChoice(kind, body, id: id, at: date) { choices.append(choice) }
        case "head.chose":
            if let choice = HeadChoice(kind, body, id: id, at: date) { choices.append(choice) }
        case "limited":
            let resetsAt = Date(timeIntervalSince1970: (body["resetsAt"]?.double ?? 0) / 1000)
            items.append(.limited(id: id, resetsAt: resetsAt, window: body["window"]?.string))
        case "limits":
            let date = { (key: String) in Date(timeIntervalSince1970: (body[key]?.double ?? 0) / 1000) }
            items.append(.nearLimit(id: id, window: body["rateLimitType"]?.string ?? "", used: body["utilization"]?.double ?? 0,
                                    resetsAt: date("resetsAt"), said: date("said")))
        case "shell":
            items.append(.shell(id: id, run: ShellRun(body)))
        case "thread.done":
            guard let thread = body["thread"]?.string.flatMap(UUID.init(uuidString:)) else { break }
            // One from before a line could wait has no reset, and reads as it did.
            let resetsAt = body["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }
            items.append(.opened(id: id, thread: thread, title: body["title"]?.string ?? Chat.untitled, finished: body["finished"]?.bool ?? true,
                                 resetsAt: resetsAt, window: body["window"]?.string))
        case "thread.act":
            // Opening, messaging and stopping another thread, and what it did from OriCode's menus,
            // are this thread's own calls, which its run of calls names; one stored before then
            // isn't drawn twice. Who opened this
            // one is ⌘⇧I's to show, and the opener's call line's.
            guard let act = ThreadAct(body), !(act.by && [.opened, .messaged, .stopped, .did].contains(act.act)), !(act.act == .opened && !act.by) else { break }
            items.append(.act(id: id, thread: act.thread, text: act.words, hover: act.hover))
        case "thread.overlap":
            guard let same = SameFile(body) else { break }
            items.append(.act(id: id, thread: same.with?.id ?? same.thread, text: same.words, hover: same.path))
        case "thread.suggested":
            guard let prompt = body["text"]?.string?.nonEmpty else { break }
            items.append(.suggested(id: id, title: body["title"]?.string?.nonEmpty ?? Chat.title(from: prompt), prompt: prompt))
        case "worker":
            workerCost += body["costUSD"]?.double ?? 0
            if let edit = RayEdit(body, turn: items.count(where: \.startsTurn)) { rayEdits.append(edit) }
        case "compacted":
            let before = body["before"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            let after = body["after"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            items.append(.note(id: id, text: before.map { "Compacted from \($0) tokens to \(after ?? "less")." } ?? "Compacted the conversation."))
        default:
            break
        }
        if !started, !items.isEmpty { started = true }
        if kind == "ask" || kind == "answer" || kind == "ask.cancelled" || kind == "ask.passed" { findWaitingAsk() }
    }

    /// A TodoWrite's list goes onto the card of the plan it carries on, or, for a new plan, onto a
    /// card of its own at its call, which is the plan this returns.
    private func planned(_ input: JSON, at id: UUID) -> Plan? {
        let next = Plan(input)
        defer { plan = next }
        if let next, let plan, plan.continues(into: next), let card = planCard,
           let index = items.lastIndex(where: { $0.id == card }), case .tool(_, var call) = items[index]
        {
            call.plan = next
            items[index] = .tool(id: card, call: call)
            return nil
        }
        planCard = next == nil ? nil : id
        return next
    }
}

extension Item {
    /// How much of your message the app reads for itself: what its bubble draws, what ⌘K searches,
    /// what the thread's title and the review's turns are named from. A paste can run to megabytes,
    /// which all go to the agent; laid out or folded whole on the main thread, one held the window
    /// for seconds, and its thread could hardly be opened again.
    static let headLength = 20_000

    var text: String? {
        switch self {
        case .text(_, let text), .thinking(_, let text), .user(_, let text, _, _), .note(_, let text): text
        default: nil
        }
    }

    /// A message sent between turns, which starts one, or a turn OriCode started. One Claude took
    /// up mid-turn doesn't.
    var startsTurn: Bool {
        switch self {
        case .user(_, _, _, let midTurn): !midTurn
        case .woke: true
        default: false
        }
    }

    /// A line written under a turn once it's over, after its footer: a thread it opened ending its
    /// first turn, one it suggested, or what it did to another thread or another to it. What reads
    /// how a turn ended looks past these.
    var followsTurn: Bool {
        switch self {
        case .opened, .suggested, .act: true
        default: false
        }
    }
}
