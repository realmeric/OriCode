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

enum Store {
    static func container() -> ModelContainer {
        let folder = URL.applicationSupportDirectory.appending(path: "OriCode", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(url: folder.appending(path: "OriCode.store"))
        do {
            return try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: configuration)
        } catch {
            fatalError("The store at \(folder.path) can't be opened: \(error)")
        }
    }
}
