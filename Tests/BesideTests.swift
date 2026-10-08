import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// A second thread in view beside the open one: it stays in memory, trades places with the open
/// one when picked, answers its own asks, and leaves when it's archived, deleted or closed over.
@MainActor
struct BesideTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let other: Project
    private let first: Chat
    private let second: Chat
    private let third: Chat
    /// In another project, as a thread beside can be.
    private let far: Chat

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        other = Project(name: "beta", path: "/tmp/beta")
        container.mainContext.insert(project)
        container.mainContext.insert(other)
        first = Chat(project: project, title: "First")
        second = Chat(project: project, title: "Second")
        third = Chat(project: project, title: "Third")
        far = Chat(project: other, title: "Far")
        for chat in [first, second, third, far] {
            chat.started = true
            container.mainContext.insert(chat)
        }
        try container.mainContext.save()
        model = AppModel(container: container)
        model.awayLimit = .milliseconds(150)
        model.selectedProjectID = project.id
        model.selectedChatID = first.id
    }

    private func away() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    private func ask(_ requestId: String, in chat: Chat) {
        model.conversation(for: chat).receive(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": .string(requestId), "kind": "permission", "tool": "Bash", "input": ["command": "ls"],
        ]))
    }

    private func asks(in chat: Chat) -> [PendingAsk] {
        model.conversation(for: chat).items.compactMap { item in
            if case .ask(_, let ask) = item { ask } else { nil }
        }
    }

    @Test func aThreadBesideIsNotLetGo() async throws {
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        try await away()
        #expect(model.conversations[second.id] != nil)
        model.letGo(second.id)
        #expect(model.conversations[second.id] != nil)
    }

    @Test func aThreadPutAwayFromBesideIsLetGoInItsTime() async throws {
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        model.besideChatID = nil
        #expect(model.conversations[second.id] != nil)
        try await away()
        #expect(model.conversations[second.id] == nil)
    }

    @Test func aThreadComingBesideIsReadFromTheStore() async throws {
        model.besideChatID = far.id
        for _ in 0..<50 where model.conversations[far.id] == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.conversations[far.id] != nil)
    }

    @Test func pickingTheThreadBesideTradesTheTwo() async throws {
        _ = model.conversation(for: first)
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        #expect(model.composerHalf == .left)
        model.select(second)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == first.id)
        // Each keeps its half, and the composer crosses to the one picked.
        #expect(model.composerHalf == .right)
        try await away()
        #expect(model.conversations[first.id] != nil)
        #expect(model.conversations[second.id] != nil)
        model.select(first)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
    }

    @Test func theTwoAreNeverTheSameThread() {
        model.besideChatID = first.id
        #expect(model.besideChatID == nil)
        model.besideChatID = second.id
        model.selectedChatID = second.id
        #expect(model.selectedChatID != model.besideChatID)
        model.selectedChatID = third.id
        #expect(model.besideChatID == first.id)
        // With none open there's none beside either.
        model.selectedChatID = nil
        #expect(model.besideChatID == nil)
        model.selectedChatID = first.id
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == nil)
        #expect(model.composerHalf == .left)
    }

    @Test func pickingTheThreadBesideFromADraftLeavesItAlone() throws {
        model.besideChatID = second.id
        let draft = try #require(model.newChat())
        #expect(model.besideChatID == second.id)
        model.select(second)
        #expect(model.selectedChatID == second.id)
        // A draft has no half to keep.
        #expect(model.besideChatID == nil)
        #expect(draft.started == false)
    }

    @Test func aThreadInAnotherProjectTradesToo() {
        model.besideChatID = far.id
        model.select(far)
        #expect(model.selectedProjectID == other.id)
        #expect(model.chat?.id == far.id)
        #expect(model.besideChatID == first.id)
    }

    @Test func anAskAnsweredForTheThreadBesideFoldsItsOwnCard() {
        ask("mine", in: first)
        ask("theirs", in: second)
        model.besideChatID = second.id
        model.answer(asks(in: second)[0], in: second.id, allow: true)
        #expect(asks(in: second).map(\.state) == [.allowed])
        #expect(model.conversation(for: second).waitingAsk == nil)
        #expect(asks(in: first).map(\.state) == [.waiting])
        #expect(model.conversation(for: first).waitingAsk?.requestId == "mine")
    }

    @Test func anAskAnsweredWithNoThreadNamedIsTheOpenOnes() {
        ask("mine", in: first)
        ask("theirs", in: second)
        model.besideChatID = second.id
        model.answer(asks(in: first)[0], allow: false)
        #expect(asks(in: first).map(\.state) == [.denied])
        #expect(asks(in: second).map(\.state) == [.waiting])
    }

    @Test func theLimitCardsToggleIsItsOwnThreads() {
        let reset = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + 3 * 86_400).rounded())
        for chat in [first, second] {
            model.conversation(for: chat).receive(EngineEvent(name: "limited", threadId: chat.id.uuidString, body: [
                "event": "limited", "resetsAt": .number(reset.timeIntervalSince1970 * 1000), "window": "seven_day",
            ]))
        }
        model.besideChatID = second.id
        defer { model.resumeTask?.cancel() }
        model.goOn(true, at: reset, in: second.id)
        #expect(second.resumeAt == reset)
        #expect(first.resumeAt == nil)
        model.goOn(true, at: reset)
        model.goOn(false, at: reset, in: second.id)
        #expect(second.resumeAt == nil)
        #expect(first.resumeAt == reset)
    }

    @Test func withNoThreadOpenNoneIsBeside() async throws {
        _ = model.conversation(for: first)
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        let empty = Project(name: "gamma", path: "/tmp/gamma")
        container.mainContext.insert(empty)
        try container.mainContext.save()
        model.select(empty)
        #expect(model.selectedChatID == nil)
        #expect(model.besideChatID == nil)
        #expect(model.composerHalf == .left)
        try await away()
        #expect(model.conversations[first.id] == nil)
        #expect(model.conversations[second.id] == nil)
    }

    @Test func archivingTheThreadBesideClearsIt() {
        model.besideChatID = second.id
        model.archive(second)
        #expect(model.besideChatID == nil)
        #expect(model.selectedChatID == first.id)
    }

    @Test func deletingTheThreadBesideClearsIt() {
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        model.delete(second)
        #expect(model.besideChatID == nil)
        #expect(model.selectedChatID == first.id)
        #expect(model.conversations[second.id] == nil)
    }

    @Test func archivingOrDeletingTheOpenThreadGivesTheWindowToTheOneBeside() {
        model.besideChatID = far.id
        model.archive(first)
        #expect(model.selectedChatID == far.id)
        #expect(model.selectedProjectID == other.id)
        #expect(model.besideChatID == nil)
        model.besideChatID = second.id
        model.delete(far)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == nil)
        #expect(model.composerHalf == .left)
    }

    @Test func closingTheOpenThreadGivesTheWindowToTheOneBeside() async throws {
        _ = model.conversation(for: first)
        _ = model.conversation(for: second)
        model.besideChatID = second.id
        #expect(model.closesThread)
        model.close()
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == nil)
        // The closed thread is let go as a closed thread is, and the one left stays.
        #expect(model.conversations[first.id] == nil)
        try await away()
        #expect(model.conversations[second.id] != nil)
        model.close()
        #expect(model.selectedChatID == nil)
    }

    @Test func removingAProjectTakesItsThreadFromBeside() {
        model.besideChatID = far.id
        model.remove(other)
        #expect(model.besideChatID == nil)
        #expect(model.selectedChatID == first.id)
    }

    @Test func removingTheOpenProjectGivesTheWindowToTheThreadBeside() {
        model.besideChatID = far.id
        model.remove(project)
        #expect(model.selectedChatID == far.id)
        #expect(model.selectedProjectID == other.id)
        #expect(model.besideChatID == nil)
    }

    @Test func aLinkOpensAgainstItsOwnThreadsFolder() {
        model.besideChatID = far.id
        model.links(in: far.id)(URL(string: "notes.md:7")!)
        #expect(model.openFile?.path == "notes.md")
        #expect(model.openFile?.cwd == "/tmp/beta")
        model.links(in: first.id)(URL(string: "notes.md")!)
        #expect(model.openFile?.cwd == "/tmp/alpha")
        // A path the open thread's folder doesn't hold is shown as its own thread's has it.
        model.openFile("/tmp/beta/Sources/main.swift", in: far.cwd)
        #expect(model.openFile?.path == "Sources/main.swift")
    }

    /// The two transcripts side by side in a window that isn't on screen, the open one second:
    /// of two cards that both took Return, the first in the window would get it.
    private func stage(active: Chat, other: Chat) -> NSWindow {
        let host = NSHostingController(rootView: AnyView(
            HStack(spacing: 0) {
                TranscriptView(conversation: model.conversation(for: other), cwd: other.cwd, active: false)
                TranscriptView(conversation: model.conversation(for: active), cwd: active.cwd)
            }
            .environment(model)
            .frame(width: 1180, height: 760)
            .preferredColorScheme(.dark)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.alphaValue = 0
        window.orderFrontRegardless()
        return window
    }

    @Test func returnAnswersOnlyTheOpenThreadsAsk() async throws {
        ask("mine", in: first)
        ask("theirs", in: second)
        model.besideChatID = second.id
        let window = stage(active: first, other: second)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let pressed = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        #expect(window.performKeyEquivalent(with: pressed))
        #expect(asks(in: first).map(\.state) == [.allowed])
        #expect(asks(in: second).map(\.state) == [.waiting])
    }
}
