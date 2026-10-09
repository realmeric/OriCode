import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// A composer under each of two threads: both can work a turn at once, the keyboard is in the
/// selected thread's field and nowhere else, and what opens over the conversation stops above
/// the taller of the two.
@MainActor
struct TwoComposersTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let first: Chat
    private let second: Chat

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        first = Chat(project: project, title: "First")
        second = Chat(project: project, title: "Second")
        for (index, chat) in [first, second].enumerated() {
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
        for chat in [first, second] {
            model.conversation(for: chat).userSent("Hello from \(chat.title)")
            receive("turn.done", ["stopReason": "end_turn"], in: chat)
        }
        model.openBeside(second)
    }

    private func receive(_ name: String, _ body: [String: JSON] = [:], in chat: Chat) {
        var body = body
        body["event"] = .string(name)
        model.conversation(for: chat).receive(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)))
    }

    private func ask(_ requestId: String, in chat: Chat) {
        receive("ask", ["requestId": .string(requestId), "kind": "permission", "tool": "Bash", "input": ["command": "ls"]], in: chat)
    }

    private func sent(in chat: Chat) -> [String] {
        model.conversation(for: chat).items.compactMap { item in
            if case .user(_, let text, _, _) = item { text } else { nil }
        }
    }

    @Test func aMessageFromEachStartsATurnInEachAndBothRun() {
        #expect(model.send("to the left", in: first))
        #expect(model.conversation(for: first).running)
        #expect(!model.conversation(for: second).running)
        // The left one still works, and the keyboard hasn't moved for the right one to start.
        #expect(model.send("to the right", in: second))
        #expect(model.conversation(for: first).running && model.conversation(for: second).running)
        #expect(sent(in: first).last == "to the left")
        #expect(sent(in: second).last == "to the right")
        #expect(model.selectedChatID == first.id)
    }

    @Test func stopInOneLeavesTheOtherRunningWithItsQueue() {
        #expect(model.send("to the left", in: first))
        #expect(model.send("to the right", in: second))
        #expect(model.queue("then the left's next", in: first))
        #expect(model.queue("then the right's next", in: second))

        model.stop(in: first)
        receive("turn.done", ["stopReason": "interrupted"], in: first)
        #expect(!model.conversation(for: first).running)
        #expect(model.conversation(for: first).queue.isEmpty)
        #expect(model.conversation(for: first).returning.map(\.text) == ["then the left's next"])
        #expect(model.conversation(for: second).running)
        #expect(model.conversation(for: second).queue.map(\.text) == ["then the right's next"])
        #expect(model.conversation(for: second).returning.isEmpty)
    }

    @Test func whetherTheComposerTakesTheKeyboardIsTheSelectedThreadsAnswer() {
        ask("r", in: second)
        #expect(model.composerTakesKeyboard)
        // Over to the thread with a card waiting: its field isn't given the keyboard.
        let asked = model.composer(for: second).focus
        model.write(in: .right)
        #expect(model.selectedChatID == second.id)
        #expect(!model.composerTakesKeyboard)
        #expect(model.composer(for: second).focus == asked)
        // And back: the first thread's is asked to take it, and the second's count is its own.
        let mine = model.composer(for: first).focus
        model.write(in: .left)
        #expect(model.composerTakesKeyboard)
        #expect(model.composer(for: first).focus == mine + 1)
        #expect(model.composer(for: second).focus == asked)
    }

    @Test func whatOpensOverTheConversationStopsAboveTheTallerComposer() {
        model.composer(for: first).top = 684
        model.composer(for: second).top = 612
        #expect(model.composerTop == 612)
        model.write(in: .right)
        #expect(model.composerTop == 612)
        // One not laid out yet has no edge, and one that isn't on the glass doesn't count.
        model.composer(for: first).top = 0
        #expect(model.composerTop == 612)
        model.composer(for: first).top = 684
        model.roomForTwo = false
        #expect(model.composerTop == 612)
        model.write(in: .left)
        #expect(model.composerTop == 684)
        model.roomForTwo = true
        model.closeOtherSide()
        #expect(model.composerTop == 684)
    }

    // MARK: In the window

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

    /// The composers' fields, left to right.
    private func fields(in window: NSWindow) -> [ComposerTextView] {
        var found: [ComposerTextView] = []
        func walk(_ view: NSView) {
            if let field = view as? ComposerTextView { found.append(field) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(400))
    }

    private func type(_ text: String, into field: NSTextView) {
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func eachThreadInViewHasItsOwnFieldAndTheKeyboardIsInOne() async throws {
        model.closeOtherSide()
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let alone = try #require(fields(in: window).first)
        #expect(fields(in: window).count == 1)
        model.openBeside(second)
        try await settle()
        let pair = fields(in: window)
        #expect(pair.count == 2)
        // The second arriving doesn't make the first again, and the keyboard stays in it.
        #expect(pair.first === alone)
        #expect(window.firstResponder === alone)
        type("for the first", into: pair[0])
        type("for the second", into: pair[1])
        #expect(model.composer(for: first).draft.text == "for the first")
        #expect(model.composer(for: second).draft.text == "for the second")
        #expect(pair.map(\.string) == ["for the first", "for the second"])

        model.write(in: .right)
        try await settle()
        #expect(fields(in: window).elementsEqual(pair, by: ===))
        #expect(window.firstResponder === pair[1])
        #expect(pair.map(\.string) == ["for the first", "for the second"])
        model.write(in: .left)
        try await settle()
        #expect(window.firstResponder === pair[0])

        // Folded, the one composer shows the selected thread, and widened both are back.
        window.setContentSize(NSSize(width: 860, height: 760))
        try await settle()
        #expect(fields(in: window).map(\.string) == ["for the first"])
        window.setContentSize(NSSize(width: 1180, height: 760))
        try await settle()
        #expect(fields(in: window).map(\.string) == ["for the first", "for the second"])
    }

    @Test func aFieldThatTakesTheKeyboardSelectsItsThread() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        // What a click in the other field does.
        #expect(window.makeFirstResponder(pair[1]))
        try await settle()
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == first.id)
        #expect(model.composerHalf == .right)
        #expect(window.firstResponder === pair[1])
    }

    @Test func theKeyboardLeavesTheFieldOnTheWayToAThreadWithACardWaiting() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        #expect(window.firstResponder === pair[0])
        ask("r", in: second)
        try await settle()
        #expect(window.firstResponder === pair[0])
        model.write(in: .right)
        try await settle()
        #expect(!(window.firstResponder is ComposerTextView))
        // Answered in the selected thread, its own field takes the keyboard.
        model.conversation(for: second).answered("r", allow: true)
        try await settle()
        #expect(window.firstResponder === pair[1])
    }

    @Test func anAskAnsweredInTheThreadBesideLeavesTheKeyboardWhereItIs() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        ask("r", in: second)
        try await settle()
        model.conversation(for: second).answered("r", allow: true)
        try await settle()
        #expect(model.selectedChatID == first.id)
        #expect(window.firstResponder === pair[0])
    }

    @Test func theOtherSideClosedLeavesOneFieldWithTheKeyboardAndItsOwnText() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        type("for the first", into: pair[0])
        type("for the second", into: pair[1])
        // The keyboard is in the right half, whose composer goes with the pair.
        model.write(in: .right)
        try await settle()
        #expect(window.firstResponder === pair[1])
        model.closeOtherSide()
        try await settle()
        let alone = fields(in: window)
        #expect(alone.count == 1)
        #expect(model.selectedChatID == second.id)
        #expect(alone.first?.string == "for the second")
        #expect(window.firstResponder === alone.first)
        #expect(model.composer(for: first).draft.text == "for the first")
    }

    @Test func aDraftFromTheRightHalfKeepsItsComposerThroughTheFirstMessage() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        model.write(in: .right)
        try await settle()
        // The first thread waits behind the draft, which has the window and the right's field.
        let draft = try #require(model.newChat())
        try await settle()
        #expect(model.besideChatID == first.id)
        #expect(fields(in: window).elementsEqual([pair[1]], by: ===))
        #expect(window.firstResponder === pair[1])
        type("for the third", into: pair[1])
        #expect(model.composer(for: draft).draft.text == "for the third")

        model.conversation(for: draft).userSent("Hello from the third")
        try await settle()
        let back = fields(in: window)
        try #require(back.count == 2)
        #expect(back[1] === pair[1])
        #expect(window.firstResponder === pair[1])
        #expect(back.map(\.string) == ["", "for the third"])
        #expect(model.selectedChatID == draft.id)
    }

    @Test func foldedWithTheKeyboardInTheRightHalfTheFieldItIsInStays() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        let pair = fields(in: window)
        try #require(pair.count == 2)
        model.write(in: .right)
        try await settle()
        window.setContentSize(NSSize(width: 860, height: 760))
        try await settle()
        #expect(fields(in: window).elementsEqual([pair[1]], by: ===))
        #expect(window.firstResponder === pair[1])
        window.setContentSize(NSSize(width: 1180, height: 760))
        try await settle()
        #expect(fields(in: window).last === pair[1])
        #expect(window.firstResponder === pair[1])
    }

    @Test func thePickerOpensOverTheSelectedComposerOnly() async throws {
        let window = stage(width: 1180)
        defer { window.close() }
        try await settle()
        model.composer(for: first).modelButtonFrame = .zero
        model.composer(for: second).modelButtonFrame = .zero
        window.setContentSize(NSSize(width: 1181, height: 760))
        try await settle()
        // Each composer writes its own button's frame, and the model's is the selected one's.
        let left = model.composer(for: first).modelButtonFrame, right = model.composer(for: second).modelButtonFrame
        #expect(left.width > 0 && right.width > 0)
        #expect(left.maxX < 590.5 && right.minX > 590.5)
        #expect(model.modelButtonFrame == left)
        model.write(in: .right)
        #expect(model.modelButtonFrame == right)
    }
}
