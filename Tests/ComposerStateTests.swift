import AppKit
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// What a composer holds is its thread's: the text, the pictures and the prompt stay behind when
/// another thread is opened, and are there on the way back.
@MainActor
struct ComposerStateTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let first: Chat
    private let second: Chat

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        project = Project(name: "alpha", path: NSTemporaryDirectory())
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
    }

    private func picture() throws -> ImageAttachment {
        try #require(ImageAttachment(image: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }))
    }

    private func sent(in chat: Chat) -> [String] {
        model.conversation(for: chat).items.compactMap { item in
            if case .user(_, let text, _, _) = item { text } else { nil }
        }
    }

    @Test func whatOneThreadsComposerHoldsIsNotTheOthers() throws {
        let image = try picture()
        model.composer(for: first).draft.text = "for the first"
        model.draftAttachments = [image]
        model.shellPrompt = true

        model.selectedChatID = second.id
        #expect(model.composer(for: second) !== model.composer(for: first))
        #expect(model.composer(for: second).draft.text.isEmpty)
        #expect(model.draftAttachments.isEmpty)
        #expect(!model.shellPrompt)
        model.composer(for: second).draft.text = "for the second"

        model.selectedChatID = first.id
        #expect(model.composer(for: first).draft.text == "for the first")
        #expect(model.draftAttachments == [image])
        #expect(model.shellPrompt)
        #expect(model.composer(for: second).draft.text == "for the second")
    }

    @Test func aMessageFromAThreadThatIsNotOpenGoesToItWithItsOwnPictures() throws {
        let mine = try picture(), others = try picture()
        model.draftAttachments = [mine]
        model.composer(for: second).attachments = [others]

        #expect(model.send("to the second", in: second))
        #expect(sent(in: second) == ["to the second"])
        #expect(sent(in: first).isEmpty)
        #expect(model.composer(for: second).attachments.isEmpty)
        #expect(model.draftAttachments == [mine])
        #expect(model.selectedChatID == first.id)
    }

    @Test func queuedAndStoppedInTheThreadNamed() throws {
        let conversation = model.conversation(for: second)
        conversation.userSent("Run the tests")
        model.composer(for: second).attachments = [try picture()]
        #expect(!model.queue("then lint"))
        #expect(model.queue("then lint", in: second))
        #expect(conversation.queue.map(\.text) == ["then lint"])
        #expect(conversation.queue.first?.images.count == 1)
        #expect(model.composer(for: second).attachments.isEmpty)
        model.stop(in: second)
        #expect(conversation.queue.isEmpty)
        #expect(conversation.returning.map(\.text) == ["then lint"])
    }

    @Test func whatsTypedWithNoThreadOpenGoesToTheThreadItStarts() throws {
        model.selectedChatID = nil
        let loose = model.composer(for: nil)
        loose.draft.text = "typed before a thread"
        loose.attachments = [try picture()]
        loose.shellPrompt = true

        let thread = try #require(model.newChat())
        #expect(model.composer(for: thread) === loose)
        #expect(model.shellPrompt && model.draftAttachments.count == 1)
        // The window with no thread starts clean the next time.
        #expect(model.composer(for: nil) !== loose)
        #expect(model.composer(for: nil).draft.text.isEmpty)
    }

    @Test func aDraftReplacedHandsOnWhatWasTypedInIt() throws {
        let draft = try #require(model.newChat())
        let typed = model.composer(for: draft)
        typed.draft.text = "typed in the draft"
        let next = try #require(model.newChat())
        #expect(next.id != draft.id)
        #expect(model.composer(for: next) === typed)
        #expect(model.composers[draft.id] == nil)
        // The project keeps one draft, so from a thread that has begun the next draft takes it
        // over too, and with no draft to replace a new thread starts empty.
        model.selectedChatID = first.id
        model.composer(for: first).draft.text = "the first's own"
        let third = try #require(model.newChat())
        #expect(model.composer(for: third) === typed)
        #expect(model.composer(for: first).draft.text == "the first's own")
        third.started = true
        model.save()
        model.selectedChatID = first.id
        let fresh = try #require(model.newChat())
        #expect(model.composer(for: fresh).draft.text.isEmpty)
    }

    @Test func whatsTypedInNoFoldersDraftOutlivesIt() throws {
        model.selectedChatID = nil
        model.selectedProjectID = nil
        let typed = model.composer(for: nil)
        typed.draft.text = "typed before any folder"
        typed.attachments = [try picture()]
        // A model pick makes No folder and its draft, and a project opened over it takes both away.
        let draft = try #require(model.newChat())
        #expect(draft.project?.isNoFolder == true)
        #expect(model.composer(for: draft) === typed)
        let folder = FileManager.default.temporaryDirectory.appending(path: "k247-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.addProject(at: folder)
        #expect(!model.projects.contains { $0.isNoFolder })
        #expect(model.chat == nil)
        #expect(model.composer(for: model.chat) === typed)
        #expect(model.draftAttachments.count == 1)
        // The project's first thread takes it, as any thread started from the empty window does.
        let thread = try #require(model.newChat())
        #expect(model.composer(for: thread).draft.text == "typed before any folder")
    }

    @Test func whatsTypedInNoFoldersDraftWaitsBehindAThreadOpenedOverIt() throws {
        model.selectedChatID = nil
        model.selectedProjectID = nil
        model.composer(for: nil).draft.text = "typed before any folder"
        try #require(model.newChat())
        model.select(second)
        #expect(model.composer(for: second).draft.text.isEmpty)
        model.selectedChatID = nil
        #expect(model.composer(for: nil).draft.text == "typed before any folder")
    }

    @Test func aThreadDeletedOrArchivedTakesItsComposerWithIt() {
        model.composer(for: first).draft.text = "going"
        model.composer(for: second).draft.text = "going too"
        let ids = (first.id, second.id)
        model.delete(first)
        #expect(model.composers[ids.0] == nil)
        model.archive(second)
        #expect(model.composers[ids.1] == nil)
        #expect(model.composer(for: second).draft.text.isEmpty)
    }

    @Test func escapeActsOnTheOpenThreadsListAndPrompt() {
        model.composer(for: second).menu = true
        model.composer(for: second).shellPrompt = true
        model.shellPrompt = true
        #expect(model.escape())
        #expect(!model.shellPrompt)
        #expect(!model.escape())
        #expect(model.composer(for: second).menu && model.composer(for: second).shellPrompt)

        model.selectedChatID = second.id
        #expect(model.escape())
        #expect(!model.composerMenu && model.shellPrompt)
        #expect(model.escape())
        #expect(!model.shellPrompt)
    }

    @Test func whereAComposerIsAndHowOftenItWasAskedAreItsOwn() {
        let composer = model.composer(for: first)
        composer.top = 640
        composer.modelButtonFrame = CGRect(x: 700, y: 650, width: 120, height: 30)
        composer.menu = true
        let focus = composer.focus
        model.selectedChatID = second.id
        // The second thread's composer hasn't been laid out, and was asked once, on being opened.
        #expect(model.composerTop == 0)
        #expect(model.modelButtonFrame == .zero)
        #expect(model.composerFocus == 1)
        #expect(!model.composerMenu)
        #expect(composer.top == 640 && composer.focus == focus && composer.menu)
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

    private func type(_ text: String, into field: NSTextView) {
        field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func theFieldShowsEachThreadsOwnDraft() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("written to the first", into: field)
        try await settle()
        #expect(model.composer(for: first).draft.text == "written to the first")

        model.selectedChatID = second.id
        try await settle()
        #expect(field.string.isEmpty)
        #expect(window.firstResponder === field)
        type("and to the second", into: field)
        try await settle()
        #expect(model.composer(for: second).draft.text == "and to the second")
        #expect(model.composer(for: first).draft.text == "written to the first")

        model.selectedChatID = first.id
        try await settle()
        #expect(field.string == "written to the first")
        // One field, and only the thread showing writes into it.
        model.composer(for: second).draft.text = "handed back while away"
        #expect(field.string == "written to the first")
        #expect(model.composer(for: first).draft.field === field && model.composer(for: second).draft.field == nil)
    }

    @Test func undoAfterASwitchNeverBringsTheOtherThreadsText() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("the first's words", into: field)
        try await settle()
        model.selectedChatID = second.id
        try await settle()
        #expect(field.string.isEmpty)
        let undo = try #require(field.undoManager)
        undo.undo()
        #expect(field.string.isEmpty)

        type("the second's", into: field)
        try await settle()
        model.selectedChatID = first.id
        try await settle()
        #expect(field.string == "the first's words")
        undo.undo()
        #expect(field.string == "the first's words")
        #expect(model.composer(for: first).draft.text == "the first's words")
    }

    @Test func thePromptAndThePicturesStayWithTheirThread() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("!", into: field)
        try await settle()
        #expect(model.shellPrompt && field.font == ComposerTextView.mono)
        model.draftAttachments = [try picture()]

        model.selectedChatID = second.id
        try await settle()
        #expect(!model.shellPrompt)
        #expect(field.font == ComposerTextView.body)
        #expect(model.draftAttachments.isEmpty)

        model.selectedChatID = first.id
        try await settle()
        #expect(model.shellPrompt)
        #expect(field.font == ComposerTextView.mono)
        #expect(model.draftAttachments.count == 1)
    }

    @Test func whatsTypedBeforeAThreadStaysThroughTheFirstMessageAndAModelPick() async throws {
        model.selectedChatID = nil
        let (window, field) = try await stage()
        defer { window.close() }
        type("typed with no thread", into: field)
        try await settle()
        // A model pick starts the thread, as the picker does.
        let thread = try #require(model.newChat())
        try await settle()
        #expect(field.string == "typed with no thread")
        #expect(model.composer(for: thread).draft.text == "typed with no thread")
        #expect(window.firstResponder === field)
    }

    @Test func theFilesAnAtListsShowWhenTheyArrive() async throws {
        let (window, field) = try await stage()
        defer { window.close() }
        type("see ", into: field)
        try await settle()
        type("@gre", into: field)
        try await settle()
        // No engine here, so the list the composer asked for comes back empty.
        #expect(model.projectFilesFolder == first.cwd)
        #expect(!model.composerMenu)
        model.projectFiles = ["Sources/greet.swift"]
        try await settle()
        #expect(model.composerMenu)
    }
}
