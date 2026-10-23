import AppKit
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var createdAt: Date
    /// Which of ProjectColor's colours its badge is; picked at random when the project is added.
    var colorIndex: Int?
    /// A command of the project's own that checks its work, `./ci.sh`, which the review counts
    /// as a build or a test beside the ones it knows. Typed in Settings › Source Control.
    var check: String?
    @Relationship(deleteRule: .cascade, inverse: \Chat.project) var chats: [Chat] = []
    /// Its plan, which agents keep through the oricode tools (ProjectPlan.swift).
    @Relationship(deleteRule: .cascade, inverse: \PlanTask.project) var tasks: [PlanTask] = []
    /// The highest number a task of its plan has had, so a deleted task's is never given again: a
    /// thread still told it works T4 can't then change a new T4.
    var lastTaskNumber = 0

    init(name: String, path: String) {
        id = UUID()
        self.name = name
        self.path = path
        createdAt = .now
    }
}

/// A thread. Named `Chat` in code only because `Thread` is Foundation's.
@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var project: Project?
    var title: String
    var sessionId: String?
    /// The agent it runs on, chosen with its model. A session doesn't move between agents, so a
    /// thread that changes one starts a new session, which opens with `handover`. Nil on a thread
    /// from before there were others, which is Claude Code's.
    var provider: String?
    var model: String?
    var effort: String?
    var permissionMode: String
    var cwd: String
    var createdAt: Date
    var updatedAt: Date
    /// Tokens in the last request's context and the model's window, from the latest turn.done.
    var contextUsed: Int = 0
    var contextWindow: Int = 0
    var costUSD: Double = 0
    /// What it had spent when a send first went under the budget in Settings › Agents, from which
    /// its budget is counted; nil while there's none.
    var spentBefore: Double?
    /// Set once the user renames the thread; until then the title follows the first message.
    var titleIsCustom: Bool = false
    /// Set for a thread on its own branch: cwd is the worktree, the branch is oricode/<slug>.
    var worktreeBranch: String?
    /// Fast mode, which the CLI serves only for models that support it.
    var fastMode: Bool = false
    /// Whether it has had its first message. Until then it's a draft: out of the drawer, and the
    /// thread ⌘N comes back to instead of making another.
    var started: Bool = false
    /// Archived: out of the drawer with its transcript and its session kept, until Settings ›
    /// Archive restores it or deletes it for good.
    var archived: Bool = false
    /// Pinned threads stay at the top of the drawer.
    var pinned: Bool = false
    /// Where it was put among the pinned threads, or among the rest once one of them was dragged;
    /// nil for a thread that never was, which sits above those that were, newest first.
    var position: Double?
    /// OriCode quit while its turn ran. The next launch sends it on, or, when it was waiting on
    /// you, puts the question back up.
    var quitMidTurn: Bool = false
    /// A limit stopped its turn and the thread waits for it: when the limit resets it goes on.
    var resumeAt: Date?
    /// Its rays, the models its head sends workers out on, by ModelRef's stored form, picked on the
    /// model page; nil, and the head works alone. It took the place of K-193's `workers`, agents by
    /// id, which name no model and were let go with it.
    var rays: [String]?
    /// Workflows on: its head fans each task out at the thread's own level, Claude Code's as its
    /// workflows, as Ultracode at Extra high, and another agent's on its rays. Never carried to a
    /// new thread, since it spends a plan much faster.
    var workflows: Bool = false
    /// It changed agent, or its session can't be sent to the model again, and its next send starts
    /// a new session that opens with the thread so far. Cleared when that session's turn starts.
    var handover: Bool = false
    /// The thread that opened it, through open_thread, when one did: its first turn's end is told
    /// to that thread, and the drawer lists it under that thread.
    var openedBy: UUID?
    /// Whether that thread is still owed the line its first turn's end gives: true from the open
    /// until it's stored, through a first turn a limit stopped and the thread waits out, then
    /// false. Nil for a thread opened before a line could wait, which tells at its first footer.
    var owesOpener: Bool?
    /// The thread whose open_thread or message_thread started its latest turn, nil when the user
    /// did: Stop on that thread stops the turn, where a turn the user started stays theirs.
    var turnFrom: UUID?
    /// It runs a plan and the user stopped it: nothing more of its plan starts and nothing is sent
    /// to it until it works again, across a quit too (PlanRun.swift).
    var planHeld: Bool = false
    /// The thread whose archive took it along, so restoring that one brings it back and one
    /// archived on its own stays.
    var archivedWith: UUID?
    /// The session in another tool it was imported from, as `source/id`, so Import sessions knows
    /// it's here already after its session id has changed or it moved to another agent.
    var importedFrom: String?
    /// The agent it is, when it's one: a thread its opener's workflow, Task call or head writes and
    /// nobody else, read-only, under that thread in the drawer. Claude Code's id for a workflow's
    /// agent or a subagent, OriCode's for a worker.
    var agentID: String?
    /// `subagent` for a Task subagent of its opener's loop, `worker` for a worker its opener's head
    /// sent out on a ray, nil for an agent of its opener's workflow.
    var agentKind: String?
    /// The task Stop stops: a workflow's whole, a subagent's or a worker's its own.
    var agentTask: String?
    /// Where Claude Code writes its transcript, and how many bytes of it are stored here.
    var agentTranscript: String?
    var agentRead: Int = 0
    /// `queued`, `running`, `done`, `failed` or `stopped`, as its workflow or its opener last told.
    var agentState: String?
    /// The first line of what it returned, or why it failed.
    var agentResult: String?
    @Relationship(deleteRule: .cascade, inverse: \Event.chat) var events: [Event] = []

    init(project: Project, title: String = Chat.untitled, permissionMode: String = "default") {
        id = UUID()
        self.project = project
        self.title = title
        self.permissionMode = permissionMode
        cwd = project.path
        createdAt = .now
        updatedAt = .now
    }
}

/// A task of a project's plan. Agents add it, take it for a thread and keep its state and note
/// through the oricode tools, and the user stops, reopens or deletes it on ⌘⇧I's screen.
@Model
final class PlanTask {
    @Attribute(.unique) var id: UUID
    var project: Project?
    /// What names it in its project's plan, as T3: one more than the highest there when it came.
    var number: Int
    var title: String
    /// What done means for it, one line someone can check.
    var doneWhen: String
    /// The numbers of the tasks it can't start before.
    var waitsOn: [Int] = []
    /// The thread working it, or that last did.
    var thread: UUID?
    /// `open`, `working`, `done` or `stuck`. An open task is waiting or ready by what it waits on.
    var state: String = "open"
    /// Where it stands, in its thread's words.
    var note: String = ""
    /// The thread that runs it, when an agent added it with add_tasks' `run`: it starts as a thread
    /// under that one once what it waits on is done (PlanRun.swift).
    var owner: UUID?
    /// What its thread is sent first and runs on, as its owner asked.
    var brief: String = ""
    var agent: String?
    var model: String?
    var effort: String?
    var worktree: Bool = false
    /// Its thread worked in a worktree its owner hasn't merged yet, which what waits on it waits for.
    var unmerged: Bool = false
    /// Whether its owner has heard how it ended.
    var heard: Bool = true
    var createdAt: Date
    var updatedAt: Date

    /// Not given its project here, for the reason Event isn't given its chat.
    init(number: Int, title: String, doneWhen: String, waitsOn: [Int] = []) {
        id = UUID()
        self.number = number
        self.title = title
        self.doneWhen = doneWhen
        self.waitsOn = waitsOn
        createdAt = .now
        updatedAt = .now
    }
}

/// One wire event, stored as the JSON it arrived as. `seq` orders events that share a timestamp.
@Model
final class Event {
    @Attribute(.unique) var id: UUID
    var chat: Chat?
    var turn: Int
    var seq: Int
    var kind: String
    var payload: Data
    var createdAt: Date

    /// Not given its chat here: set before the event is inserted, SwiftData can drop the
    /// relationship on save. `Conversation.record` inserts first, then attaches.
    init(turn: Int, seq: Int, kind: String, payload: Data) {
        id = UUID()
        self.turn = turn
        self.seq = seq
        self.kind = kind
        self.payload = payload
        createdAt = .now
    }
}

extension Project {
    /// The one project that isn't a folder of yours: No folder, for a thread that works on the Mac
    /// rather than in a project. Known by its id, which neither a new name nor a support folder
    /// that moved can change, and which needs nothing new in the store.
    static let noFolderID = UUID(uuidString: "4E6F2046-6F6C-4465-8000-000000000000")!
    static let noFolderName = "No folder"

    var isNoFolder: Bool { id == Self.noFolderID }
}

extension Chat {
    static let untitled = "New thread"

    /// The first message's first line, trimmed to 60 characters, read from the message's head.
    static func title(from message: String) -> String {
        let line = message.prefix(Item.headLength).split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return untitled }
        return line.count > 60 ? String(line.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

/// Which OriCode this is: the one you work in, or OriCode Molten, the Debug build you work on.
/// Each has its own name and its own folders, so neither opens the other's threads.
enum Build {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "OriCode"
    static let folder = Bundle.main.object(forInfoDictionaryKey: "OriCodeFolder") as? String ?? "OriCode"
    static var support: URL { URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory) }
    static var logs: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/\(folder)", directoryHint: .isDirectory) }
}

enum Store {
    static func container() -> ModelContainer {
        let folder = Build.support
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { claim(folder) }
        let configuration = ModelConfiguration(url: folder.appending(path: "OriCode.store"))
        do {
            return try ModelContainer(for: Project.self, Chat.self, Event.self, PlanTask.self, configurations: configuration)
        } catch {
            fatalError("The store at \(folder.path) can't be opened: \(error)")
        }
    }

    /// One process to a store. A second copy of the same build, which LaunchServices can start
    /// from an old DerivedData to deliver a notification's click, would fault on rows the first
    /// one deletes and bring it down, so it brings the first to the front and goes. The lock is
    /// held for the life of the process and let go with it, however it ends.
    private static func claim(_ folder: URL) {
        let lock = open(folder.appending(path: "OriCode.store.lock").path, O_CREAT | O_RDWR, 0o644)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) != 0 else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first { $0.processIdentifier != me }?.activate()
        exit(0)
    }
}

extension Chat {
    /// The drawer's order: pinned threads first, as they were put, then the rest, a thread never
    /// placed on top and newest first, the others as they were dragged. Each thread's three
    /// values are read once: a stored value read through SwiftData costs a microsecond or more,
    /// and comparing as the sort goes read six of them every step, 15 ms for 300 threads, which
    /// the Thread menu and the drawer paid five times over at every change they watch (K-318).
    static func inDrawerOrder(_ chats: [Chat]) -> [Chat] {
        chats.map { (chat: $0, pinned: $0.pinned, position: $0.position, createdAt: $0.createdAt) }
            .sorted { a, b in
                if a.pinned != b.pinned { return a.pinned }
                switch (a.position, b.position) {
                case let (x?, y?) where x != y: return x < y
                case (nil, _?): return true
                case (_?, nil): return false
                default: return a.createdAt > b.createdAt
                }
            }
            .map(\.chat)
    }
}
