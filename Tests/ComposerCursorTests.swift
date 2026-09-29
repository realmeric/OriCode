import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// Where the composer's caret and cursor are: the keyboard a new thread's field starts with, the
/// caret's colour on the dark glass, and the I-beam only over the field's own frame.
@MainActor
struct ComposerCursorTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: NSTemporaryDirectory())
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

    /// The real window, with nothing done to give its field the keyboard.
    private func stage() -> NSWindow {
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
        return window
    }

    /// Waits for the field to hold the keyboard, and hands it back, or nil if it never does.
    private func focused(_ window: NSWindow, within seconds: Double = 1.5) async throws -> ComposerTextView? {
        for _ in 0..<Int(seconds * 20) {
            if let field = window.firstResponder as? ComposerTextView { return field }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func type(_ text: String, into field: NSTextView) {
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func pointer(_ type: NSEvent.EventType, at point: NSPoint = .zero, in window: NSWindow) -> NSEvent {
        NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    // MARK: Keyboard

    @Test func aNewThreadsFieldHasTheKeyboardWithNothingAskedTwice() async throws {
        let window = stage()
        defer { window.close() }
        #expect(try await focused(window) != nil)
    }

    @Test func theFieldHasTheKeyboardAfterASend() async throws {
        let window = stage()
        defer { window.close() }
        let field = try #require(try await focused(window))
        type("hello", into: field)
        field.keyDown(with: key(36, "\r"))
        let conversation = model.conversation(for: chat)
        for _ in 0..<100 where conversation.running { try await Task.sleep(for: .milliseconds(20)) }
        #expect(try await focused(window) != nil)
    }

    @Test func theFieldHasTheKeyboardAfterCommandKAndEscape() async throws {
        let window = stage()
        defer { window.close() }
        _ = try #require(try await focused(window))
        model.toggleCommandCenter()
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.commandCenterShown)
        #expect(model.escape())
        #expect(try await focused(window) != nil)
    }

    @Test func theFieldHasTheKeyboardAfterSwitchingThreads() async throws {
        let other = Chat(project: project)
        container.mainContext.insert(other)
        try container.mainContext.save()
        let window = stage()
        defer { window.close() }
        _ = try #require(try await focused(window))
        model.selectedChatID = other.id
        model.openNewThread()
        #expect(try await focused(window) != nil)
        model.selectedChatID = chat.id
        model.composerFocus += 1
        #expect(try await focused(window) != nil)
    }

    // MARK: Caret

    @Test func theCaretIsBrightOnTheDarkGlass() async throws {
        let window = stage()
        defer { window.close() }
        let field = try #require(try await focused(window))
        var white: CGFloat = 0
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            white = field.insertionPointColor.usingColorSpace(.genericGray)?.whiteComponent ?? 0
        }
        #expect(white > 0.8)
        #expect(field.shouldDrawInsertionPoint)
    }

    // MARK: Frame and cursor

    @Test func theFieldStaysWithinItsScrollViewAndTheWindow() async throws {
        let window = stage()
        defer { window.close() }
        let field = try #require(try await focused(window))
        let scroll = try #require(field.enclosingScrollView)
        func check() {
            let inWindow = scroll.convert(scroll.bounds, to: nil)
            #expect(scroll.frame.width < 900 && inWindow.height < 300)
            #expect(field.frame.width <= scroll.contentView.bounds.width + 0.5)
            #expect(field.visibleRect.height <= scroll.bounds.height + 0.5)
            #expect(field.visibleRect.width <= scroll.bounds.width + 0.5)
            #expect(scroll.contentView.frame.size == scroll.bounds.size)
        }
        check()
        type("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight", into: field)
        try await Task.sleep(for: .milliseconds(100))
        check()
    }

    @Test func theIBeamIsTheFieldsAndTheArrowLeavesWithThePointer() async throws {
        let window = stage()
        defer { window.close() }
        let field = try #require(try await focused(window))
        // Over the text: a cursor update inside the field's frame.
        NSCursor.arrow.set()
        let inside = field.convert(NSPoint(x: 5, y: 5), to: nil)
        field.cursorUpdate(with: pointer(.cursorUpdate, at: inside, in: window))
        #expect(NSCursor.current == NSCursor.iBeam)
        // Leaving it, and a cursor update that lands outside its frame, are both the arrow.
        field.mouseExited(with: pointer(.mouseExited, in: window))
        #expect(NSCursor.current == NSCursor.arrow)
        NSCursor.iBeam.set()
        let outside = field.convert(NSPoint(x: -40, y: -40), to: nil)
        field.cursorUpdate(with: pointer(.cursorUpdate, at: outside, in: window))
        #expect(NSCursor.current == NSCursor.arrow)
    }
}
