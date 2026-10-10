import AppKit
import SwiftData
import Testing
@testable import OriCode

/// What's typed and not sent outlasts a quit: a started thread's draft is written when the
/// keyboard leaves it, the app is left or quits, never on a key, and the next launch's composer
/// for that thread starts with it.
@MainActor
struct KeptDraftsTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let first: Chat
    private let second: Chat
    private let suite = "KeptDraftsTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
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
        model = AppModel(container: container, drafts: defaults)
        model.selectedProjectID = project.id
        model.selectedChatID = first.id
    }

    private var kept: [String: String] {
        defaults.dictionary(forKey: AppModel.draftsKey) as? [String: String] ?? [:]
    }

    /// The next launch: a model of its own on the same store and the same defaults.
    private func relaunched() -> AppModel {
        let next = AppModel(container: container, drafts: defaults)
        next.pruneDrafts()
        return next
    }

    /// The suite goes, and nothing is left unsaved for autosave to find once the store has gone.
    private func forget() {
        defaults.removePersistentDomain(forName: suite)
        try? container.mainContext.save()
    }

    @Test func aDraftIsWrittenWhenTheKeyboardLeavesItsThreadAndReadBackByTheNextLaunch() {
        defer { forget() }
        model.composer(for: first).draft.text = "for the first"
        #expect(kept.isEmpty)
        model.selectedChatID = second.id
        #expect(kept == [first.id.uuidString: "for the first"])
        model.composer(for: second).draft.text = "for the second"
        model.markCutOffTurns()
        #expect(kept[second.id.uuidString] == "for the second")

        let next = relaunched()
        #expect(next.composer(for: first).draft.text == "for the first")
        #expect(next.composer(for: second).draft.text == "for the second")
        // Read back and not edited, it isn't written again.
        defaults.removeObject(forKey: AppModel.draftsKey)
        next.keepDrafts()
        #expect(kept.isEmpty)
    }

    @Test func theThreadBesideIsWrittenWhenTheKeyboardCrossesBack() {
        defer { forget() }
        model.besideChatID = second.id
        model.selectedChatID = second.id
        model.composer(for: second).draft.text = "in the right half"
        model.selectedChatID = first.id
        #expect(model.besideChatID == second.id)
        #expect(kept == [second.id.uuidString: "in the right half"])
    }

    @Test func nothingIsWrittenWhileTyping() {
        defer { forget() }
        let draft = model.composer(for: first).draft
        draft.text = "a"
        let before = defaults.object(forKey: AppModel.draftsKey)
        draft.text = "ab"
        #expect(before == nil)
        #expect(defaults.object(forKey: AppModel.draftsKey) == nil)
        #expect(model.draftsWritten[first.id] == nil)
    }

    @Test func leavingTheAppWritesEveryEditedDraft() {
        defer { forget() }
        model.composer(for: first).draft.text = "left as it was"
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(kept == [first.id.uuidString: "left as it was"])
    }

    @Test func anEmptiedOrSentDraftIsTakenOut() {
        defer { forget() }
        let draft = model.composer(for: first).draft
        draft.text = "not yet"
        model.selectedChatID = second.id
        #expect(kept[first.id.uuidString] == "not yet")
        // What the composer does once a message has gone, with the keyboard still in the thread:
        // a crash after Return doesn't bring the message back as a draft.
        model.selectedChatID = first.id
        draft.text = ""
        model.keepDraft(of: first.id)
        #expect(kept.isEmpty)
        #expect(relaunched().composer(for: first).draft.text.isEmpty)
    }

    @Test func aDeletedOrArchivedThreadsDraftGoesWithIt() {
        defer { forget() }
        model.composer(for: first).draft.text = "going"
        model.composer(for: second).draft.text = "going too"
        model.keepDrafts()
        #expect(kept.count == 2)
        model.delete(first)
        #expect(kept == [second.id.uuidString: "going too"])
        model.archive(second)
        #expect(kept.isEmpty)
    }

    @Test func launchDropsADraftWhoseThreadIsGone() {
        defer { forget() }
        let gone = UUID().uuidString
        second.archived = true
        defaults.set([gone: "nobody's", first.id.uuidString: "kept", second.id.uuidString: "archived"], forKey: AppModel.draftsKey)
        let next = relaunched()
        #expect(kept == [first.id.uuidString: "kept"])
        #expect(next.composer(for: first).draft.text == "kept")
    }

    /// Left before its thread had a first message, a draft isn't marked written, so it's kept the
    /// first time the thread is one that keeps.
    @Test func aDraftLeftBeforeItsThreadBeganIsKeptOnceItHas() {
        defer { forget() }
        first.started = false
        model.composer(for: first).draft.text = "typed early"
        model.selectedChatID = second.id
        #expect(kept.isEmpty)
        first.started = true
        model.keepDrafts()
        #expect(kept == [first.id.uuidString: "typed early"])
    }

    /// Esc at the prompt makes what's typed a message again without an edit, and it's kept as one.
    @Test func aDraftPutAwayFromThePromptIsKeptAgain() {
        defer { forget() }
        let state = model.composer(for: first)
        state.draft.text = "ship the fix"
        model.keepDrafts()
        #expect(kept == [first.id.uuidString: "ship the fix"])
        state.draft.text = "ship the fix today"
        state.shellPrompt = true
        model.keepDrafts()
        #expect(kept.isEmpty)
        state.shellPrompt = false
        model.markCutOffTurns()
        #expect(kept == [first.id.uuidString: "ship the fix today"])
        #expect(relaunched().composer(for: first).draft.text == "ship the fix today")
    }

    @Test func onlyAMessageOfAStartedThreadIsKept() throws {
        defer { forget() }
        // A command at the prompt isn't a message.
        model.composer(for: first).draft.text = "ls -la"
        model.composer(for: first).shellPrompt = true
        // A thread that hasn't had its first message goes at launch, and its text with it.
        let draft = try #require(model.newChat())
        model.composer(for: draft).draft.text = "never sent"
        model.selectedChatID = second.id
        model.keepDrafts()
        #expect(kept.isEmpty)
    }
}
