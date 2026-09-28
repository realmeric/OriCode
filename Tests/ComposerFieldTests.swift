import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// The composer's text view: what it hands the composer, how tall it grows, and the composer's keys
/// through the real RootView in a window that isn't on screen.
@MainActor
struct ComposerFieldTests {
    private let container: ModelContainer
    private let model: AppModel
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        model = AppModel(container: container)
        chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        model.drawerPinned = false
        model.drawerShown = false
    }

    // MARK: The field alone

    private func loneField(maxLines: Int = 4) -> (ComposerTextView, Draft, NSWindow) {
        let draft = Draft()
        let field = ComposerTextView.make()
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 20)
        field.autoresizingMask = [.width]
        scroll.documentView = field
        window.contentView?.addSubview(scroll)
        field.draft = draft
        draft.field = field
        field.maxHeight = ComposerTextView.lineHeight(ComposerTextView.body) * CGFloat(maxLines)
        return (field, draft, window)
    }

    private func type(_ text: String, into field: NSTextView) {
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func whatsTypedAndWhatsSetMeet() {
        let (field, draft, _) = loneField()
        type("hello", into: field)
        #expect(draft.text == "hello")
        #expect(!draft.blank && !draft.empty)
        draft.text = "/review"
        #expect(field.string == "/review")
        #expect(field.selectedRange() == NSRange(location: 7, length: 0))
        #expect(draft.slash == "review")
        type(" now", into: field)
        #expect(draft.slash == nil)
        draft.text = ""
        #expect(field.string.isEmpty && draft.empty && draft.blank)
        type("!ls", into: field)
        #expect(draft.bang)
    }

    @Test func itGrowsALineAtATimeUpToItsLines() {
        let (field, draft, _) = loneField(maxLines: 4)
        let line = ComposerTextView.lineHeight(ComposerTextView.body)
        #expect(draft.height == line)
        type("one\ntwo", into: field)
        #expect(abs(draft.height - 2 * line) <= 1)
        type("\nthree\nfour\nfive\nsix", into: field)
        #expect(draft.height == 4 * line)
        draft.text = ""
        #expect(draft.height == line)
    }

    @Test func returnIsTheComposersUnlessAnInputMethodIsComposing() {
        let (field, _, _) = loneField()
        var pressed: [EventModifiers] = []
        field.keys = ComposerKeys(enter: { pressed.append($0) })
        field.keyDown(with: key(36, "\r"))
        field.keyDown(with: key(36, "\r", .shift))
        field.keyDown(with: key(76, "\u{3}", .option))
        #expect(pressed == [[], .shift, .option])
        field.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(field.hasMarkedText())
        field.keyDown(with: key(36, "\r"))
        #expect(pressed.count == 3)
    }

    @Test func arrowsTabAndDeleteGoToTheComposerFirst() {
        let (field, _, _) = loneField()
        var calls: [String] = []
        var takesUp = true
        field.keys = ComposerKeys(
            up: { calls.append("up"); return takesUp },
            down: { calls.append("down"); return true },
            tab: { calls.append($0 ? "backtab" : "tab") },
            delete: { calls.append("delete"); return false })
        type("a\nb", into: field)
        field.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(field.selectedRange().location == 3)
        takesUp = false
        field.doCommand(by: #selector(NSResponder.moveUp(_:)))
        // Not taken, so the caret moves up a line as it would anywhere.
        #expect(field.selectedRange().location == 1)
        field.doCommand(by: #selector(NSResponder.moveDown(_:)))
        field.doCommand(by: #selector(NSResponder.insertTab(_:)))
        field.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        field.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(calls == ["up", "up", "down", "tab", "backtab", "delete"])
        // Tab never goes in as text, and ⌫ not taken deletes.
        #expect(field.string == "\nb")
    }

    @Test func aSetIsOneChangeUndoTakesBack() throws {
        let (field, draft, window) = loneField()
        window.makeFirstResponder(field)
        let undo = try #require(field.undoManager)
        // A test has no events to group changes by, so each gets a group of its own.
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        undo.beginUndoGrouping()
        type("what's typed", into: field)
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        draft.text = "what ↑ brought back"
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo()
        #expect(field.string == "what's typed")
        #expect(draft.text == "what's typed")
    }

    @Test func theKeyboardWaitsForTheWindow() {
        let draft = Draft()
        draft.keyboard(true)
        let (field, _, window) = loneField()
        draft.field = field
        #expect(window.firstResponder === field)
        draft.keyboard(false)
        #expect(window.firstResponder === window)
    }

    @Test func imagesAndFilesDroppedOnTheTextAreAttachments() throws {
        let (field, _, _) = loneField()
        var dropped: [NSPasteboard] = []
        var over: [Bool] = []
        field.keys = ComposerKeys(drop: { dropped.append($0); return true }, dropping: { over.append($0) })
        let board = NSPasteboard(name: NSPasteboard.Name("ComposerFieldTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([URL(filePath: "/tmp/shot.png") as NSURL])
        let drag = Drag(board)
        #expect(field.draggingEntered(drag) == .copy)
        #expect(field.performDragOperation(drag))
        #expect(dropped.count == 1 && over == [true, false])
        #expect(field.string.isEmpty)
    }

    // MARK: Through the composer

    private func stage() async throws -> (NSWindow, ComposerTextView) {
        let host = NSHostingController(rootView: AnyView(
            RootView()
                .environment(model)
                .environment(Updates())
                .modelContainer(container)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 900, height: 600))
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        window.alphaValue = 0
        window.orderFrontRegardless()
        for _ in 0..<40 where !(window.firstResponder is ComposerTextView) {
            model.composerFocus += 1
            try await Task.sleep(for: .milliseconds(50))
        }
        let field = try #require(window.firstResponder as? ComposerTextView)
        return (window, field)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    @Test func returnSendsAndShiftReturnBreaksTheLineAtTheCaret() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("ab", into: field)
        field.setSelectedRange(NSRange(location: 1, length: 0))
        field.keyDown(with: key(36, "\r", .shift))
        #expect(field.string == "a\nb")
        // ⌥Return with no turn to wait for is a new line too.
        field.keyDown(with: key(36, "\r", .option))
        #expect(field.string == "a\n\nb")
        field.keyDown(with: key(36, "\r"))
        let conversation = model.conversation(for: chat)
        #expect(conversation.items.contains { if case .user(_, "a\n\nb", _, _) = $0 { true } else { false } })
        #expect(field.string.isEmpty)
        #expect(window.firstResponder === field)
        // No engine runs here: the turn fails, while the store is still here to record it.
        for _ in 0..<100 where conversation.running { try await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func duringATurnReturnSteersAndOptionReturnQueues() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        let conversation = model.conversation(for: chat)
        conversation.userSent("Run the tests")
        try await settle()
        type("then lint", into: field)
        field.keyDown(with: key(36, "\r", .option))
        #expect(conversation.queue.map(\.text) == ["then lint"])
        #expect(field.string.isEmpty)
        type("and look at the build", into: field)
        field.keyDown(with: key(36, "\r"))
        #expect(conversation.waiting.map(\.text) == ["and look at the build"])
        #expect(field.string.isEmpty)
        // With no engine the message comes back, and back into the field.
        for _ in 0..<100 where !conversation.waiting.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await settle()
        #expect(field.string == "and look at the build")
    }

    @Test func upBringsBackWhatWasSent() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        let conversation = model.conversation(for: chat)
        conversation.userSent("first")
        conversation.userSent("second")
        try await settle()
        field.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(field.string == "second")
        field.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(field.string == "first")
        field.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(field.string == "second")
    }

    @Test func aBangTurnsThePromptAndDeleteTurnsItBack() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("!", into: field)
        try await settle()
        #expect(model.shellPrompt)
        #expect(field.string.isEmpty)
        #expect(field.font == ComposerTextView.mono)
        field.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(!model.shellPrompt)
        try await settle()
        #expect(field.font == ComposerTextView.body)
        #expect(window.firstResponder === field)
    }

    @Test func theSlashMenuCompletesOnReturn() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        model.slashCommands[chat.providerID] = [chat.cwd: [
            SlashCommandInfo(name: "review", description: "Review the changes", hint: "[focus]"),
            SlashCommandInfo(name: "compact", description: "Compact the thread", hint: nil),
        ]]
        type("/rev", into: field)
        try await settle()
        field.keyDown(with: key(36, "\r"))
        #expect(field.string == "/review ")
        #expect(model.conversation(for: chat).items.isEmpty)
    }

    @Test func pastedTextComesInPlain() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        let board = NSPasteboard(name: NSPasteboard.Name("ComposerFieldTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.writeObjects([NSAttributedString(string: "bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 30)])])
        #expect(field.readSelection(from: board))
        #expect(field.string == "bold words")
        #expect(field.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == ComposerTextView.body)
    }
}

/// A drag with nothing but a pasteboard, for the drop tests.
private final class Drag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    @MainActor init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
