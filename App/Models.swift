import Foundation
import SwiftData

@Model
final class Project {
    @Attribute(.unique) var id: UUID
    var name: String
    var path: String
    var createdAt: Date
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
    @Relationship(deleteRule: .cascade, inverse: \Event.chat) var events: [Event] = []

    init(project: Project, title: String = "New thread", permissionMode: String = "default") {
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

    init(chat: Chat, turn: Int, seq: Int, kind: String, payload: Data) {
        id = UUID()
        self.chat = chat
        self.turn = turn
        self.seq = seq
        self.kind = kind
        self.payload = payload
        createdAt = .now
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
