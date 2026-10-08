import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What list_threads and read_thread answer with: the project's threads, the files each one's own
/// edits touched, and a transcript a part at a time, all from stored events.
@MainActor
struct OtherThreadsTests {
    private let container: ModelContainer
    private let project: Project
    private let other: Project

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        other = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(project)
        container.mainContext.insert(other)
        try container.mainContext.save()
    }

    private var context: ModelContext { container.mainContext }

    private func thread(_ title: String, in project: Project? = nil, started: Bool = true, active: TimeInterval = 0) throws -> Chat {
        let chat = Chat(project: project ?? self.project, title: title)
        chat.started = started
        context.insert(chat)
        chat.updatedAt = Date(timeIntervalSince1970: 1_800_000_000 + active)
        try context.save()
        return chat
    }

    /// Stores events in a thread after those it has, in the order given.
    private typealias Stored = (kind: String, body: JSON)

    private func store(_ events: [Stored], in chat: Chat) throws {
        var seq = (chat.events.map(\.seq).max() ?? -1) + 1
        for (kind, body) in events {
            let event = Event(turn: 1, seq: seq, kind: kind, payload: try body.data())
            event.createdAt = Date(timeIntervalSince1970: 1_800_000_000 + Double(seq))
            context.insert(event)
            event.chat = chat
            seq += 1
        }
        try context.save()
    }

    private static func edit(_ id: String, _ path: String, tool: String = "Edit", failed: Bool? = false) -> [Stored] {
        let use: Stored = ("tool.use", ["event": "tool.use", "toolUseId": .string(id), "name": .string(tool), "input": ["file_path": .string(path)]])
        guard let failed else { return [use] }
        return [use, ("tool.result", ["event": "tool.result", "toolUseId": .string(id), "content": "ok", "isError": .bool(failed)])]
    }

    private func paths(_ chat: Chat, asked: String? = nil) -> [String] {
        OtherThreads.edits(of: chat.id, cwd: chat.cwd, asked: asked, in: context).map(\.path)
    }

    @Test func aThreadsEditsAreItsOwnCallsThatWentThroughLatestFirst() throws {
        let chat = try thread("The drawer's width")
        var events = Self.edit("a", "/tmp/alpha/App/Drawer.swift") + Self.edit("b", "/tmp/alpha/README.md", tool: "Write")
        events += [
            ("tool.use", ["event": "tool.use", "toolUseId": "c", "name": "Read", "input": ["file_path": "/tmp/alpha/App/Theme.swift"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": "c", "content": "…", "isError": false]),
        ] as [Stored]
        // Refused, and one still waiting on its result: neither changed a file.
        events += Self.edit("d", "/tmp/alpha/App/Composer.swift", failed: true)
        events += Self.edit("e", "/tmp/alpha/Makefile", failed: nil)
        events += [
            // Another agent's call says what it does and what it's on.
            ("tool.use", ["event": "tool.use", "toolUseId": "f", "name": "Shell", "kind": "delete", "input": ["path": "old.txt"], "view": ["path": "old.txt"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": "f", "content": "", "isError": false]),
            ("tool.use", ["event": "tool.use", "toolUseId": "g", "name": "NotebookEdit", "input": ["notebook_path": "/elsewhere/n.ipynb"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": "g", "content": "", "isError": false]),
            // What a worker brought in is the thread's too.
            ("worker", ["event": "worker", "worker": "w1", "files": [["path": "App/Rays.swift", "hunks": []]]]),
        ] as [Stored]
        events += Self.edit("h", "/tmp/alpha/App/Drawer.swift")
        try store(events, in: chat)

        #expect(paths(chat) == ["App/Drawer.swift", "App/Rays.swift", "/elsewhere/n.ipynb", "old.txt", "README.md"])
        // Asked about one file, by its name, a path's end or its full path, whatever the case.
        #expect(paths(chat, asked: "Drawer.swift") == ["App/Drawer.swift"])
        #expect(paths(chat, asked: "app/drawer.swift") == ["App/Drawer.swift"])
        #expect(paths(chat, asked: "/tmp/alpha/App/Drawer.swift") == ["App/Drawer.swift"])
        #expect(paths(chat, asked: "old.txt") == ["old.txt"])
        // A name's end isn't the name, and a file only read or never written isn't edited.
        #expect(paths(chat, asked: "awer.swift").isEmpty)
        #expect(paths(chat, asked: "Theme.swift").isEmpty)
        #expect(paths(chat, asked: "Composer.swift").isEmpty)
        #expect(paths(chat, asked: "Makefile").isEmpty)
    }

    @Test func aThreadIsListedWithItsLatestFilesAndNoMore() throws {
        let chat = try thread("Many files")
        try store((0..<30).flatMap { Self.edit("t\($0)", "/tmp/alpha/f\($0).txt") }, in: chat)
        let listed = paths(chat)
        #expect(listed.count == OtherThreads.mostFiles)
        #expect(listed.first == "f29.txt" && listed.last == "f10.txt")
        // Asked about a file, the thread's whole history is read.
        #expect(paths(chat, asked: "f0.txt") == ["f0.txt"])
    }

    @Test func askedWhichThreadChangedAFileTheListingNamesThatThreadAlone() async throws {
        let (model, asking) = try model()
        let drawer = try thread("The drawer's width", active: 10)
        let readme = try thread("Fix the README", active: 20)
        try store(Self.edit("a", "/tmp/alpha/App/Drawer.swift"), in: drawer)
        let onlyRead: Stored = ("tool.use", ["event": "tool.use", "toolUseId": "r", "name": "Read", "input": ["file_path": "/tmp/alpha/App/Drawer.swift"]])
        try store(Self.edit("a", "/tmp/alpha/README.md") + [onlyRead], in: readme)

        let found = try await model.listThreads(for: asking.id, edited: "Drawer.swift")
        #expect(found["project"] == "alpha")
        let threads = try #require(found["threads"]?.array)
        #expect(threads.count == 1)
        #expect(threads[0]["id"]?.string == drawer.id.uuidString && threads[0]["title"] == "The drawer's width")
        #expect(threads[0]["edited"]?.array?.map { $0["path"] } == ["App/Drawer.swift"])
        #expect(threads[0]["state"] == "idle" && threads[0]["agent"] == "claude")
        #expect(found["note"] == nil)

        // No thread's edits touched it: said, with where else a change comes from.
        let none = try await model.listThreads(for: asking.id, edited: "Makefile")
        #expect(none["threads"]?.array?.isEmpty == true)
        #expect(none["note"]?.string?.hasPrefix("No thread's own edits touched Makefile.") == true)
    }

    @Test func aListingIsTheProjectsStartedThreadsAndThoseTheAskerOpenedElsewhere() async throws {
        let (model, asking) = try model()
        let worked = try thread("Worked on", active: 30)
        worked.worktreeBranch = "oricode/t-1"
        worked.cwd = "/tmp/alpha/.worktrees/t-1"
        let archived = try thread("Put away", active: 20)
        archived.archived = true
        _ = try thread("A draft", started: false, active: 50)
        _ = try thread("Beta's own", in: other, active: 40)
        let opened = try thread("Opened in beta", in: other, active: 10)
        opened.openedBy = asking.id
        try context.save()

        let listed = try await model.listThreads(for: asking.id, edited: nil)
        let threads = try #require(listed["threads"]?.array)
        // The latest worked on first; the asker is among them and says so.
        #expect(threads.map { $0["title"]?.string } == ["Asking", "Worked on", "Put away", "Opened in beta"])
        #expect(threads[0]["this"] == true && threads[0]["folder"] == nil && threads[0]["edited"] == [])
        #expect(threads[1]["branch"] == "oricode/t-1" && threads[1]["folder"] == "/tmp/alpha/.worktrees/t-1")
        #expect(threads[2]["archived"] == true)
        #expect(threads[3]["openedByYou"] == true && threads[3]["folder"] == "/tmp/beta")
        #expect(threads[1]["this"] == nil && threads[1]["openedByYou"] == nil && threads[1]["archived"] == nil)
        #expect(listed["more"] == nil)
    }

    @Test func aListingStopsAtFortyThreadsAndSaysHowManyAreLeft() throws {
        let threads = (0..<45).map {
            OtherThreads.Listed(id: UUID(), title: "t\($0)", agent: "claude", state: "idle", active: Date(timeIntervalSince1970: Double($0)), cwd: "/tmp/alpha")
        }
        let listed = OtherThreads.listing(threads, project: "alpha", folder: "/tmp/alpha", asked: nil, in: context)
        #expect(listed["threads"]?.array?.count == OtherThreads.mostThreads)
        #expect(listed["threads"]?.array?.first?["title"] == "t44")
        #expect(listed["more"] == 5)
    }

    @Test func askedAboutAFileTheThreadsPastFortyAreCountedOnlyWhenTheyEditedIt() throws {
        let chats = try (0..<43).map { try thread("t\($0)", active: Double($0)) }
        for chat in chats.dropFirst() { try store(Self.edit("a", "/tmp/alpha/shared.txt"), in: chat) }
        let threads = chats.map {
            OtherThreads.Listed(id: $0.id, title: $0.title, agent: "claude", state: "idle", active: $0.updatedAt, cwd: "/tmp/alpha")
        }
        let listed = OtherThreads.listing(threads, project: "alpha", folder: "/tmp/alpha", asked: "shared.txt", in: context)
        #expect(listed["threads"]?.array?.count == OtherThreads.mostThreads)
        #expect(listed["threads"]?.array?.first?["title"] == "t42")
        // t0 never edited it, so two are left, not three.
        #expect(listed["more"] == 2)
    }

    @Test func aMoveIsAnEditOfBothNames() throws {
        let chat = try thread("Rename the drawer")
        try store([
            ("tool.use", ["event": "tool.use", "toolUseId": "m", "name": "Edit", "kind": "move", "input": ["path": "App/Drawer.swift", "movePath": "App/Sidebar.swift"], "view": ["path": "App/Drawer.swift"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": "m", "content": "", "isError": false]),
        ], in: chat)
        #expect(paths(chat) == ["App/Sidebar.swift", "App/Drawer.swift"])
        #expect(paths(chat, asked: "Sidebar.swift") == ["App/Sidebar.swift"])
        #expect(paths(chat, asked: "Drawer.swift") == ["App/Drawer.swift"])
    }

    @Test func aBeforeNoIntHoldsIsNoBefore() {
        #expect(JSON.number(40).int == 40 && JSON.number(40.9).int == 40)
        for number in [1e30, -1e30, .infinity, .nan] { #expect(JSON.number(number).int == nil) }
    }

    @Test func aTranscriptIsWhatWasSaidAndEachCallAsALine() throws {
        let chat = try thread("The drawer's width")
        var events: [Stored] = [
            ("user", ["event": "user", "text": "Make the drawer 300pt wide."]),
            ("thinking", ["event": "thinking", "delta": "Where is the width?"]),
            ("text", ["event": "text", "delta": "I'll change the width."]),
        ]
        events += Self.edit("a", "/tmp/alpha/App/Drawer.swift")
        events += [
            ("tool.use", ["event": "tool.use", "toolUseId": "b", "name": "Bash", "input": ["command": "make test\nsecond line"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": "b", "content": "2 failed", "isError": true]),
            ("shell", ShellRun(command: "git status", folder: "/tmp/alpha").body),
            ("text", ["event": "text", "delta": .string(String(repeating: "x", count: OtherThreads.part + 50))]),
            ("turn.done", ["event": "turn.done", "stopReason": "end_turn"]),
        ] as [Stored]
        try store(events, in: chat)

        let part = OtherThreads.transcript(of: chat.id, cwd: chat.cwd, in: context)
        #expect(part.before == nil)
        #expect(part.text == """
        User: Make the drawer 300pt wide.
        Assistant: I'll change the width.
        Tool: Edit App/Drawer.swift
        Tool: Bash: make test (failed)
        User ran: git status
        Assistant: \(String(repeating: "x", count: OtherThreads.part))…
        """)
    }

    @Test func aLongTranscriptComesAPartAtATimeFromTheEndWithNothingLost() throws {
        let chat = try thread("Long")
        let replies: [Stored] = (0..<40).map { ("text", ["event": "text", "delta": .string("reply \($0) " + String(repeating: "y", count: 90))]) }
        try store(replies, in: chat)

        var before: Int?
        var parts: [OtherThreads.Part] = []
        repeat {
            let part = OtherThreads.transcript(of: chat.id, cwd: chat.cwd, before: before, page: 1_000, in: context)
            #expect(part.text.count <= 1_000)
            parts.append(part)
            before = part.before
        } while before != nil && parts.count < 20

        // The first part read is the end of the thread, and the parts together are all of it, in order.
        #expect(parts.count > 3)
        #expect(parts[0].text.hasSuffix(String(repeating: "y", count: 90)) && parts[0].text.contains("reply 39 "))
        let lines = parts.reversed().flatMap { $0.text.split(separator: "\n") }
        #expect(lines.count == 40)
        #expect(lines.enumerated().allSatisfy { $1.hasPrefix("Assistant: reply \($0) ") })
        // One line longer than a page still comes, alone.
        let single = OtherThreads.transcript(of: chat.id, cwd: chat.cwd, page: 10, in: context)
        #expect(single.text.hasPrefix("Assistant: reply 39 ") && single.before == 39)
    }

    @Test func aThreadReadsOneOfItsProjectsAndNoOther() async throws {
        let (model, asking) = try model()
        let drawer = try thread("The drawer's width")
        let beta = try thread("Beta's own", in: other)
        let opened = try thread("Opened in beta", in: other)
        opened.openedBy = asking.id
        try store([("user", ["event": "user", "text": "Make the drawer 300pt wide."])], in: drawer)
        try store([("user", ["event": "user", "text": "Rename sum.txt."])], in: opened)

        let read = try await model.readThread(drawer.id.uuidString.lowercased(), before: nil, for: asking.id)
        #expect(read == ["id": .string(drawer.id.uuidString), "title": "The drawer's width", "state": "idle", "transcript": "User: Make the drawer 300pt wide."])
        // One it opened in another project is its to read; that project's own threads aren't.
        #expect(try await model.readThread(opened.id.uuidString, before: nil, for: asking.id)["transcript"] == "User: Rename sum.txt.")
        for named in [beta.id.uuidString, "The drawer's width", ""] {
            await #expect(throws: AppModel.Refused.self) { try await model.readThread(named, before: nil, for: asking.id) }
        }
        // Nothing was written to a thread that was read, and none started a turn.
        #expect(drawer.events.count == 1 && opened.events.count == 1 && beta.events.isEmpty)
        #expect(model.conversations[drawer.id] == nil && model.conversations[opened.id] == nil)
    }

    @Test func readingAThreadLeavesItsDateAlone() async throws {
        let (model, asking) = try model()
        let drawer = try thread("The drawer's width", active: 10)
        try store([("user", ["event": "user", "text": "Make the drawer 300pt wide."])], in: drawer)
        let was = drawer.updatedAt
        // Open in memory, with another thread's change waiting in the context they share.
        _ = model.conversation(for: drawer)
        asking.title = "Asking still"
        #expect(context.hasChanges)

        let read = try await model.readThread(drawer.id.uuidString, before: nil, for: asking.id)
        #expect(read["transcript"] == "User: Make the drawer 300pt wide.")
        #expect(drawer.updatedAt == was)
    }

    @Test func bothAreAsksTheAppAnswers() {
        #expect(AppModel.asks.isSuperset(of: ["threads.list", "thread.read"]))
    }

    /// A model with a started Claude thread, Asking, open in alpha.
    private func model() throws -> (AppModel, Chat) {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-others-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        let asking = try thread("Asking", active: 100)
        model.selectedProjectID = project.id
        model.selectedChatID = asking.id
        return (model, asking)
    }
}
