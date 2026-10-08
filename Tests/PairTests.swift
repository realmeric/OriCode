import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// Two threads drawn side by side: how one is called beside the other, how the composer is sent
/// across, what a window too narrow for two does, and what RootView makes of it.
@MainActor
struct PairTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let first: Chat
    private let second: Chat
    private let third: Chat

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        first = Chat(project: project, title: "First")
        second = Chat(project: project, title: "Second")
        third = Chat(project: project, title: "Third")
        for (index, chat) in [first, second, third].enumerated() {
            chat.started = true
            chat.position = Double(index)
            container.mainContext.insert(chat)
        }
        try container.mainContext.save()
        model = AppModel(container: container)
        model.selectedProjectID = project.id
        model.selectedChatID = first.id
        model.drawerPinned = false
        model.drawerShown = false
        for chat in [first, second, third] { say("Hello from \(chat.title)", in: chat) }
    }

    private func say(_ text: String, in chat: Chat) {
        model.conversation(for: chat).userSent(text, previews: [], id: UUID())
        model.conversation(for: chat).receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["event": "turn.done", "stopReason": "end_turn"]))
    }

    private func ask(_ requestId: String, in chat: Chat) {
        model.conversation(for: chat).receive(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": .string(requestId), "kind": "permission", "tool": "Bash", "input": ["command": "ls"],
        ]))
    }

    @Test func aThreadOpenedBesideLeavesTheKeyboardWhereItIs() {
        model.openBeside(second)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
        #expect(model.besideShown?.id == second.id)
        // Another one takes the other half, and the open thread stays the open one.
        model.openBeside(third)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == third.id)
    }

    @Test func theDrawersNumberOpensThatThreadBeside() throws {
        let order = model.chats.map(\.id)
        #expect(order.count == 3)
        let index = try #require(order.firstIndex(of: third.id))
        model.openBeside(threadAt: index)
        #expect(model.besideChatID == third.id)
        model.openBeside(threadAt: 9)
        #expect(model.besideChatID == third.id)
    }

    @Test func theOpenThreadADraftAndAnArchivedOneDontComeBeside() throws {
        model.openBeside(first)
        #expect(model.besideChatID == nil)
        third.archived = true
        model.openBeside(third)
        #expect(model.besideChatID == nil)
        let draft = try #require(model.newChat())
        model.select(first)
        model.openBeside(draft)
        #expect(model.besideChatID == nil)
    }

    @Test func withNoThreadOpenItOpens() {
        model.selectedChatID = nil
        model.openBeside(second)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == nil)
    }

    @Test func theArrowsSendTheComposerToTheirSide() {
        model.openBeside(second)
        model.write(in: .left)
        #expect(model.selectedChatID == first.id)
        model.write(in: .right)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == first.id)
        #expect(model.composerHalf == .right)
        model.write(in: .right)
        #expect(model.selectedChatID == second.id)
        model.write(in: .left)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
    }

    @Test func anArrowWithNoThreadBesideMovesNothing() {
        model.write(in: .right)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == nil)
    }

    @Test func aMessageGoesToTheThreadTheComposerIsUnder() {
        func sent(_ chat: Chat) -> [String] {
            model.conversation(for: chat).items.compactMap { if case .user(_, let text, _, _) = $0 { text } else { nil } }
        }
        model.openBeside(second)
        model.write(in: .right)
        #expect(model.send("To the right one"))
        #expect(sent(second).last == "To the right one")
        #expect(sent(first) == ["Hello from First"])
        model.write(in: .left)
        #expect(model.send("To the left one"))
        #expect(sent(first).last == "To the left one")
        #expect(sent(second).last == "To the right one")
    }

    @Test func closingTheOtherSideStopsNothing() {
        model.openBeside(second)
        model.conversation(for: second).receive(EngineEvent(name: "turn.started", threadId: second.id.uuidString, body: ["event": "turn.started"]))
        #expect(model.conversation(for: second).running)
        model.closeOtherSide()
        #expect(model.besideChatID == nil)
        #expect(model.selectedChatID == first.id)
        #expect(model.conversations[second.id]?.running == true)
    }

    @Test func aWindowTooNarrowForTwoFoldsToTheOpenThread() {
        model.roomForTwo = false
        model.openBeside(second)
        // Still beside, and kept in memory; only not drawn.
        #expect(model.besideChatID == second.id)
        #expect(model.inView(second.id))
        #expect(model.besideShown == nil)
        #expect(!model.onGlass(second.id))
        #expect(model.onGlass(first.id))
        #expect(model.note == "Widen the window to see both")
        // Folded, either arrow shows the other thread.
        model.write(in: .left)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == first.id)
        model.write(in: .left)
        #expect(model.selectedChatID == first.id)
        model.roomForTwo = true
        #expect(model.besideShown?.id == second.id)
        #expect(model.onGlass(second.id))
    }

    @Test func aDraftHasTheWindowToItself() throws {
        model.openBeside(second)
        let draft = try #require(model.newChat())
        #expect(model.selectedChatID == draft.id)
        #expect(model.besideChatID == second.id)
        #expect(model.besideShown == nil)
        // Its first message makes it a thread, and the one beside is back in view.
        say("Begin", in: draft)
        draft.started = true
        #expect(model.besideShown?.id == second.id)
    }

    @Test func escNeverClosesAColumnOrDeniesTheOtherThreadsAsk() {
        model.openBeside(second)
        ask("theirs", in: second)
        #expect(!model.escape())
        #expect(model.besideChatID == second.id)
        #expect(model.conversation(for: second).waitingAsk?.requestId == "theirs")
        ask("mine", in: first)
        #expect(model.escape())
        #expect(model.conversation(for: first).waitingAsk == nil)
        #expect(model.conversation(for: second).waitingAsk?.requestId == "theirs")
        #expect(model.besideChatID == second.id)
    }

    @Test func theColumnBesideStreamsEveryOtherFrameOnlyWhileBothWork() {
        func turn(_ name: String, in chat: Chat) {
            model.conversation(for: chat).receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: ["event": .string(name), "stopReason": "end_turn"]))
        }
        let beside = model.conversation(for: second)
        #expect(!beside.everyOtherFrame())
        model.openBeside(second)
        // Alone at work, it has the frame to itself.
        #expect(!beside.everyOtherFrame())
        turn("turn.started", in: first)
        #expect(beside.everyOtherFrame())
        #expect(!model.conversation(for: first).everyOtherFrame())
        model.roomForTwo = false
        #expect(!beside.everyOtherFrame())
        model.roomForTwo = true
        // The composer sent across, the other one is the one that waits a frame.
        model.write(in: .right)
        #expect(!beside.everyOtherFrame())
        turn("turn.started", in: second)
        #expect(model.conversation(for: first).everyOtherFrame())
        turn("turn.done", in: second)
        #expect(!model.conversation(for: first).everyOtherFrame())
    }

    @Test func theThreeKeysHaveDefaultsAndTheDigitsAreKept() {
        let suite = "PairTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = Shortcuts(defaults: defaults)
        #expect(shortcuts.label(.writeLeft) == "⌥⌘←")
        #expect(shortcuts.label(.writeRight) == "⌥⌘→")
        #expect(shortcuts.label(.closeOtherSide) == "⌥⌘W")
        #expect(shortcuts.set(KeyCombo("2", [.command, .option]), for: .review) == "⌥⌘2 is Open Thread 2 Beside")
        #expect(shortcuts.set(KeyCombo("l", [.command, .option]), for: .closeOtherSide) == nil)
        #expect(Shortcuts(defaults: defaults).label(.closeOtherSide) == "⌥⌘L")
    }

    /// RootView in a window that isn't on screen.
    private func stage(width: CGFloat) -> NSWindow {
        let host = NSHostingController(rootView: AnyView(
            RootView()
                .environment(model)
                .environment(Updates())
                .modelContainer(container)
                .preferredColorScheme(.dark)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: width, height: 760))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.alphaValue = 0
        window.orderFrontRegardless()
        return window
    }

    /// The transcripts' scroll views, left to right.
    private func columns(in window: NSWindow) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > 300, scroll.frame.height > 300 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    @Test func theWindowDrawsEqualHalvesAndFoldsWhenNarrow() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        #expect(columns(in: window).count == 1)
        #expect(columns(in: window).first?.frame.width == 1180)
        model.openBeside(second)
        try await settle()
        #expect(columns(in: window).map(\.frame.width) == [590, 590])
        #expect(model.roomForTwo)
        // Under 440pt a column the pair folds to the open thread, and widened it's back.
        window.setContentSize(NSSize(width: 860, height: 760))
        try await settle()
        #expect(columns(in: window).map(\.frame.width) == [860])
        #expect(!model.roomForTwo)
        #expect(model.besideChatID == second.id)
        window.setContentSize(NSSize(width: 900, height: 760))
        try await settle()
        #expect(columns(in: window).map(\.frame.width) == [450, 450])
        #expect(model.roomForTwo)
        // A pinned drawer moves both over and takes its width from the room.
        window.setContentSize(NSSize(width: 1180, height: 760))
        model.drawerPinned = true
        model.drawerShown = true
        try await settle()
        #expect(columns(in: window).map(\.frame.width) == [444, 444])
        window.setContentSize(NSSize(width: 1100, height: 760))
        try await settle()
        #expect(columns(in: window).count == 1)
    }

    @Test func theColumnBesideStartsUnderItsTitle() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        model.openBeside(second)
        try await settle()
        // Its first line is lower than the open one's, clear of the title drawn over it.
        let heights = columns(in: window).map { $0.documentView?.frame.height ?? 0 }
        model.write(in: .right)
        try await settle()
        let crossed = columns(in: window).map { $0.documentView?.frame.height ?? 0 }
        #expect(crossed[0] - heights[0] == TranscriptView.besideTop - TitleBar.height)
        #expect(heights[1] - crossed[1] == TranscriptView.besideTop - TitleBar.height)
    }

    @Test func aDrawerOverTheLeftHalfLeavesTheComposerItsWidth() {
        // One thread: the composer's left end clears the drawer, as before.
        #expect(RootView.clearing(width: 1180) == 102)
        #expect(RootView.clearing(width: 720) == 292)
        #expect(RootView.clearing(width: 1500) == 0)
        // A half's column keeps the 388pt the narrowest window's composer has.
        #expect(RootView.clearing(width: 590) == 162)
        #expect(RootView.clearing(width: 450) == 22)
        #expect(RootView.clearing(width: 440) == 12)
    }

    @Test func tradingTheComposerMakesNeitherTranscriptAgain() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        model.openBeside(second)
        try await settle()
        let before = columns(in: window)
        #expect(before.count == 2)
        model.write(in: .right)
        try await settle()
        let crossed = columns(in: window)
        #expect(crossed.count == 2)
        #expect(zip(before, crossed).allSatisfy { $0 === $1 })
        model.write(in: .left)
        try await settle()
        #expect(zip(before, columns(in: window)).allSatisfy { $0 === $1 })
        // A third thread takes the other half, and the open one's transcript is the one it was.
        model.openBeside(third)
        try await settle()
        let replaced = columns(in: window)
        #expect(replaced.count == 2)
        #expect(replaced.first === before.first)
        #expect(replaced.last !== before.last)
    }
}
