import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var createdAt: Date
    /// Which of ProjectColor's colours its badge is; picked at random when the project is added.
    var colorIndex: Int?
    @Relationship(deleteRule: .cascade, inverse: \Chat.project) var chats: [Chat] = []

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
    /// Set once the user renames the thread; until then the title follows the first message.
    var titleIsCustom: Bool = false
    /// Set for a thread on its own branch: cwd is the worktree, the branch is oricode/<slug>.
    var worktreeBranch: String?
    /// Fast mode, which the CLI serves only for models that support it.
    var fastMode: Bool = false
    /// Whether it has had its first message. Until then it's a draft: out of the drawer, and the
    /// thread ⌘N comes back to instead of making another.
    var started: Bool = false
    /// Pinned threads stay at the top of the drawer.
    var pinned: Bool = false
    /// Where it was put among the pinned threads, or among the rest once one of them was dragged;
    /// nil for a thread that never was, which sits above those that were, newest first.
    var position: Double?
    /// OriCode quit while its turn ran. The next launch sends it on, or, when it was waiting on
    /// you, puts the question back up.
    var quitMidTurn: Bool = false
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

extension Chat {
    static let untitled = "New thread"

    /// The first message's first line, trimmed to 60 characters.
    static func title(from message: String) -> String {
        let line = message.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
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
        let configuration = ModelConfiguration(url: folder.appending(path: "OriCode.store"))
        do {
            return try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: configuration)
        } catch {
            fatalError("The store at \(folder.path) can't be opened: \(error)")
        }
    }
}

extension Chat {
    /// The drawer's order: pinned threads first, as they were put, then the rest, a thread never
    /// placed on top and newest first, the others as they were dragged.
    static func drawerOrder(_ a: Chat, _ b: Chat) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        switch (a.position, b.position) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a.createdAt > b.createdAt
        }
    }
}
