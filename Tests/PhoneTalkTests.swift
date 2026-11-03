import Foundation
import Link
import SwiftData
import Testing
@testable import OriCode

/// A thread's conversation for the phone: how the Mac folds and pages it, and what it publishes
/// for a thread at work.
@MainActor
struct PhoneTalkTests {
    private func model() throws -> (AppModel, Chat) {
        let container = try TestStore.memory()
        let context = container.mainContext
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let chat = Chat(project: project, title: "Characters")
        chat.started = true
        context.insert(chat)
        try context.save()
        return (AppModel(container: container), chat)
    }

    private func text(_ words: String) -> Item { .text(id: UUID(), text: words) }

    private func tool(_ command: String, result: String? = "ok") -> Item {
        .tool(id: UUID(), call: ToolCall(toolUseId: UUID().uuidString, name: "Bash", input: ["command": .string(command)], result: result))
    }

    private func request(_ items: [Item], finished: [Range<Int>] = [], from: Int? = nil, written: Set<Int> = [], thread: UUID = UUID()) -> TalkFold.Request {
        TalkFold.Request(thread: thread, items: items, finished: finished, from: from, written: written, task: nil, cwd: "/tmp/alpha")
    }

    private func long(_ count: Int) -> [Item] {
        (0..<count).map { _ in text(String(repeating: "word ", count: 2_000)) }
    }

    @Test func aRunOfCallsIsOneLineWithACount() {
        let lines = TalkFold.lines(of: [text("Looking."), tool("make"), tool("ls"), text("Done.")], task: nil, cwd: "/tmp").map(\.line)
        #expect(lines.map(\.kind) == [.agent, .tools, .agent])
        #expect(lines[1].count == 2)
        #expect(lines[1].calls == ["Ran make", "Ran ls"])
    }

    @Test func thinkingAndAPlanDrawNoLine() {
        let plan = Item.tool(id: UUID(), call: ToolCall(toolUseId: "p", name: "TodoWrite", input: .null))
        #expect(TalkFold.lines(of: [.thinking(id: UUID(), text: "Hm"), plan, text("Yes.")], task: nil, cwd: "/tmp").map(\.line.kind) == [.agent])
    }

    @Test func whatOpenedAThreadIsNotAMessage() {
        let task = UUID()
        let lines = TalkFold.lines(of: [.user(id: task, text: "Do it"), .user(id: UUID(), text: "Well?", images: [Data()])], task: task, cwd: "/tmp").map(\.line)
        #expect(lines.map(\.kind) == [.task, .mine])
        #expect(lines[1].count == 1)
    }

    @Test func aLongThreadOpensAtItsLastTwoPages() {
        let folded = TalkFold.fold(request(long(30)))
        let tail = (folded.pages.map(\.index).max() ?? 0)
        #expect(tail > 3)
        #expect(folded.pages.map(\.index).sorted() == [tail - 1, tail])
        #expect(folded.finished.count == tail)
    }

    @Test func finishedPagesStayAsTheyWereAndOnlyTheTailIsFoldedAgain() throws {
        var items = long(30)
        let first = TalkFold.fold(request(items))
        items += [text("One more.")]
        let next = TalkFold.fold(request(items, finished: first.finished))
        #expect(Array(next.finished.prefix(first.finished.count)) == first.finished)
        let whole = TalkFold.fold(request(items, from: 0))
        for page in next.pages { #expect(whole.pages.first { $0.index == page.index }?.lines == page.lines) }
    }

    @Test func earlierPagesComeWhenAskedForAndTheStartIsReached() {
        let items = long(30)
        let opened = TalkFold.fold(request(items))
        let written = Set(opened.pages.map(\.index))
        let asked = TalkFold.fold(request(items, finished: opened.finished, from: 0, written: written))
        // What was written stays written, but for the newest page, and every other page comes.
        let tail = written.max() ?? 0
        #expect(Set(asked.pages.map(\.index)) == Set(0...tail).subtracting(written).union([tail]))
        var pages = Dictionary(opened.pages.map { ($0.index, $0.lines) }, uniquingKeysWith: { $1 })
        for page in asked.pages { pages[page.index] = page.lines }
        // None lost and none twice, end to end.
        #expect(Talk.merged(pages).map(\.id) == items.map(\.id.uuidString))
    }

    @Test func aCallStillOutKeepsItsPageOpen() {
        var items = long(4)
        items.append(tool("make", result: nil))
        items += long(30)
        let folded = TalkFold.fold(request(items))
        // Everything from the page with that call on can still change, and is cut again next time.
        #expect(folded.finished.count < Talk.cut(TalkFold.lines(of: items[...], task: nil, cwd: "/tmp").map(\.line)).count - 1)
    }

    @Test func aStoredThreadFoldsAsItsReplayDoes() throws {
        let (_, chat) = try model()
        func event(_ kind: String, _ seq: Int, _ body: JSON) -> StoredEvent {
            StoredEvent(id: UUID(), kind: kind, turn: 1, seq: seq, body: body, createdAt: .now, model: nil)
        }
        let events = [
            event("user", 0, ["text": "Build it"]),
            event("text", 1, ["delta": "On it."]),
            event("tool.use", 2, ["toolUseId": "a", "name": "Bash", "input": ["command": "make"]]),
            event("tool.result", 3, ["toolUseId": "a", "content": "ok"]),
            event("tool.use", 4, ["toolUseId": "b", "name": "Read", "input": ["file_path": "/tmp/alpha/a.swift"]]),
            event("tool.result", 5, ["toolUseId": "b", "content": "x", "isError": true]),
            event("ask", 6, ["requestId": "r", "kind": "permission", "tool": "Mac", "input": ["app": "Safari", "bundleId": "com.apple.Safari"]]),
            event("answer", 7, ["requestId": "r", "allow": true]),
            event("turn.done", 8, ["durationMs": 1, "costUSD": 0, "stopReason": "end_turn"]),
            event("user", 9, ["text": "Thanks"]),
        ]
        let replay = Conversation(chat: chat, context: chat.modelContext!, stored: events)
        let live = TalkFold.lines(of: replay.items[...], task: nil, cwd: "/tmp/alpha").map(\.line)
        let stored = TalkFold.lines(of: TalkFold.items(of: events)[...], task: nil, cwd: "/tmp/alpha").map(\.line)
        #expect(stored == live)
        #expect(live.map(\.kind) == [.mine, .agent, .tools, .ask, .mine])
        #expect(live[3].text == "Allowed · See and use Safari")
    }

    /// The blank: asking, or waiting on a thread, a thread has no words for its step, and in its
    /// first turn no reply yet.
    @Test func aThreadWaitingOnYouPublishesItsAskAndNoEmptyStep() throws {
        let (model, chat) = try model()
        let link = PhoneLink()
        link.model = model
        model.conversation(for: chat).userSent("See the app")
        model.route(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": "grant", "kind": "permission", "tool": "Mac", "input": ["app": "Safari", "bundleId": "com.apple.Safari"],
            "choices": [["id": "deny", "name": "Deny", "kind": "reject_once"], ["id": "allow", "name": "Allow", "kind": "allow_always"]],
        ]))
        let snapshot = link.snapshot()
        let thread = try #require(snapshot.threads[RecordName.thread(chat.id)])
        #expect(thread.status == .asking)
        #expect(thread.step == nil)
        let ask = try #require(snapshot.asks[RecordName.ask("grant")])
        #expect(ask.title == "Let this thread see and use Safari?")
        #expect(ask.choices.map(\.name) == ["Deny", "Allow"])
    }

    @Test func aThreadWaitingOnAThreadNamesIt() throws {
        let (model, chat) = try model()
        let other = Chat(project: try #require(chat.project), title: "Count A")
        chat.modelContext?.insert(other)
        try chat.modelContext?.save()
        let link = PhoneLink()
        link.model = model
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run them")
        model.route(EngineEvent(name: "tool.use", threadId: chat.id.uuidString, body: [
            "event": "tool.use", "toolUseId": "w", "name": "mcp__oricode__wait_thread", "input": ["thread": .string(other.id.uuidString)],
        ]))
        #expect(link.snapshot().threads[RecordName.thread(chat.id)]?.step == "Waiting on Count A")
    }

    @Test func pagesInICloudAreNotTakenForWhatLeftTheSet() {
        let link = PhoneLink()
        let thread = UUID()
        link.talk.books[thread] = PhoneLink.TalkBook(written: [3: Data(), 4: Data()])
        #expect(link.talkNames == [RecordName.talk(thread, page: 3), RecordName.talk(thread, page: 4)])
    }

    @Test func aPhoneThatWatchesNothingCostsNothing() {
        let link = PhoneLink()
        #expect(link.talkNames.isEmpty)
        #expect(link.talk.ending == nil && link.talk.waiting == nil)
    }
}
