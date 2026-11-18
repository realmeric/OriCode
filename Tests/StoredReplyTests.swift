import Foundation
import SQLite3
import SwiftData
import Testing
@testable import OriCode

/// The phone's reply of a thread whose transcript isn't in memory (K-381).
struct StoredReplyTests {
    private static func text(_ words: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["type": "text", "delta": words])
    }

    /// Two threads in a store on disk, with events in an order the rows don't follow.
    @MainActor
    private static func store(at url: URL) throws -> (ModelContainer, UUID, UUID) {
        let container = try ModelContainer(for: Project.self, Chat.self, Event.self, PlanTask.self, configurations: ModelConfiguration(url: url, cloudKitDatabase: .none))
        let context = container.mainContext
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let first = Chat(project: project), second = Chat(project: project)
        context.insert(first)
        context.insert(second)
        for (chat, seq, kind, payload) in [
            (first, 2, "text", text("last")), (first, 1, "text", text("first")), (first, 3, "turn.done", Data("{}".utf8)),
            (second, 9, "text", text("other thread")),
        ] {
            let event = Event(turn: 0, seq: seq, kind: kind, payload: payload)
            context.insert(event)
            event.chat = chat
        }
        try context.save()
        return (container, first.id, second.id)
    }

    private static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "StoredReply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func theLastTextOfTheThreadIsReadOffTheMainThread() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (container, first, second) = try await Self.store(at: folder.appending(path: "OriCode.store"))
        let replies = await Task.detached {
            #expect(pthread_main_np() == 0)
            let context = ModelContext(container)
            return (PhoneLink.storedReply(of: first, in: context), PhoneLink.storedReply(of: second, in: context), PhoneLink.storedReply(of: UUID(), in: context))
        }.value
        #expect(replies.0 == "last")
        #expect(replies.1 == "other thread")
        #expect(replies.2 == nil)
    }

    /// The lookup is one step of an index on the thread, the kind and the order; without it SQLite
    /// read every event in the store.
    @Test func eventsAreIndexedByThreadKindAndOrder() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "OriCode.store")
        _ = try await Self.store(at: url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { Issue.record("can't open the store"); return }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ZEVENT'", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        var indexes: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { indexes.append(String(cString: sqlite3_column_text(statement, 0))) }
        #expect(indexes.contains { $0.contains("ZCHAT") && $0.contains("ZKIND") && $0.contains("ZSEQ") })
    }
}
