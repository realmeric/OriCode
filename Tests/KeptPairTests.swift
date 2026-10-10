import AppKit
import SwiftData
import Testing
@testable import OriCode

/// The pair outlasts a quit, each thread in the half it was in, and two more ways to make one:
/// ⌘K's Open beside, and the line a thread leaves in the one that opened it.
@MainActor
struct KeptPairTests {
    private let container: ModelContainer
    private let model: AppModel
    private let project: Project
    private let first: Chat
    private let second: Chat
    private let third: Chat
    private let suite = "KeptPairTests-\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
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
        model = AppModel(container: container, drafts: defaults)
        model.drawerPinned = false
        model.drawerShown = false
    }

    /// The window as it's quit: one thread open and another beside it. The open thread is picked
    /// here and not in init, so what the next launch reads was written with no other suite's
    /// model in between.
    private func pair(_ open: Chat, beside: Chat) {
        model.select(open)
        model.besideChatID = nil
        model.openBeside(beside)
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

    @Test func thePairComesBackWithEachThreadInItsHalf() {
        defer { forget() }
        pair(first, beside: second)
        var next = relaunched()
        #expect(next.selectedChatID == first.id)
        #expect(next.besideChatID == second.id)
        #expect(next.composerHalf == .left)
        #expect(next.besideShown?.id == second.id)

        // The keyboard sent to the right half: the same two threads, the open one on the right.
        model.write(in: .right)
        #expect(model.selectedChatID == second.id && model.composerHalf == .right)
        next = relaunched()
        #expect(next.selectedChatID == second.id)
        #expect(next.besideChatID == first.id)
        #expect(next.composerHalf == .right)
    }

    @Test func bothThreadsAreReadAndEachHasItsDraft() async throws {
        defer { forget() }
        pair(first, beside: second)
        model.composer(for: first).draft.text = "for the left"
        model.composer(for: second).draft.text = "for the right"
        model.keepDrafts()
        let next = relaunched()
        #expect(next.composer(for: first).draft.text == "for the left")
        #expect(next.composer(for: second).draft.text == "for the right")
        for _ in 0..<200 where next.conversations[first.id] == nil || next.conversations[second.id] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(next.conversations[first.id] != nil)
        #expect(next.conversations[second.id] != nil)
        #expect(next.conversations[third.id] == nil)
    }

    @Test func aThreadArchivedMeanwhileComesBackAsOne() throws {
        defer { forget() }
        pair(first, beside: second)
        model.write(in: .right)
        model.composer(for: first).draft.text = "typed beside"
        model.keepDrafts()
        // Archived with the app shut: nothing of this model's hears of it.
        first.archived = true
        try container.mainContext.save()
        let next = relaunched()
        #expect(next.selectedChatID == second.id)
        #expect(next.besideChatID == nil)
        #expect(next.composerHalf == .left)
        #expect(next.besideShown == nil)
        #expect(UserDefaults.standard.string(forKey: "besideChat") == nil)
        #expect(defaults.dictionary(forKey: AppModel.draftsKey)?[first.id.uuidString] == nil)
        // The half kept for the pair that's gone isn't the next pair's.
        next.openBeside(third)
        let after = relaunched()
        #expect(after.selectedChatID == second.id)
        #expect(after.besideChatID == third.id)
        #expect(after.composerHalf == .left)
    }

    @Test func aThreadDeletedMeanwhileComesBackAsOne() throws {
        defer { forget() }
        pair(first, beside: second)
        let gone = second.id
        container.mainContext.delete(second)
        try container.mainContext.save()
        let next = relaunched()
        #expect(next.selectedChatID == first.id)
        #expect(next.besideChatID == nil)
        #expect(next.composerHalf == .left)
        #expect(next.chat(withID: gone) == nil)
        #expect(UserDefaults.standard.string(forKey: "besideChat") == nil)
    }

    @Test func withNoThreadOpenNoneComesBackBeside() throws {
        defer { forget() }
        pair(first, beside: second)
        // The open thread went with the app shut, and the window comes up with none.
        container.mainContext.delete(first)
        try container.mainContext.save()
        let next = relaunched()
        #expect(next.chat == nil)
        #expect(next.besideChatID == nil)
    }

    @Test func oneThreadComesBackAsOne() {
        defer { forget() }
        pair(first, beside: second)
        model.closeOtherSide()
        let next = relaunched()
        #expect(next.selectedChatID == first.id)
        #expect(next.besideChatID == nil)
    }

    // MARK: The line an opened thread leaves in its parent

    @Test func theLineOpensItsThreadBesideTheParentAndLeavesTheKeyboardThere() {
        defer { forget() }
        model.select(first)
        model.openOpened(second.id, from: first.id)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
        // Already beside, nothing moves.
        model.openOpened(second.id, from: first.id)
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
    }

    @Test func inAFoldedWindowTheLineSwitchesToItsThread() {
        defer { forget() }
        model.select(first)
        model.roomForTwo = false
        model.openOpened(second.id, from: first.id)
        #expect(model.selectedChatID == second.id)
        #expect(model.note == nil)
        // The parent waits beside, in the left half it would have had, for the window to widen.
        #expect(model.besideChatID == first.id)
        #expect(model.composerHalf == .right)
        model.roomForTwo = true
        #expect(model.besideShown?.id == first.id)
    }

    @Test func theLineInTheColumnBesideTakesTheOtherHalfForItsThread() {
        defer { forget() }
        pair(first, beside: second)
        // The line is in the second thread, which doesn't have the keyboard: a click in a column
        // puts it there, and the thread it names takes the half the first had.
        model.openOpened(third.id, from: second.id)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == third.id)
        #expect(model.composerHalf == .right)
        // The pair it names already on the glass, only the keyboard comes over.
        model.openOpened(second.id, from: third.id)
        #expect(model.selectedChatID == third.id)
        #expect(model.besideChatID == second.id)
        #expect(model.composerHalf == .left)
    }

    @Test func anArchivedThreadsLineStillOpensItAlone() throws {
        defer { forget() }
        model.select(first)
        second.archived = true
        try container.mainContext.save()
        model.openOpened(second.id, from: first.id)
        #expect(model.selectedChatID == second.id)
        #expect(model.besideChatID == nil)
    }

    // MARK: ⌘K

    private func rows(of id: String) async throws -> [PaletteItem] {
        let item = try #require(model.paletteSearchable().first { $0.id == id })
        guard item.unavailable == nil, case .list(let list) = item.action else { return [] }
        return try await list.items()
    }

    @Test func openBesideListsTheOtherThreadsAndPuttingOneBesideKeepsTheKeyboard() async throws {
        defer { forget() }
        model.select(first)
        third.archived = true
        try container.mainContext.save()
        let listed = try await rows(of: "thread.beside")
        #expect(listed.map(\.title) == ["Second"])
        guard case .run(let run) = try #require(listed.first).action else {
            Issue.record("The row doesn't run")
            return
        }
        run()
        #expect(model.selectedChatID == first.id)
        #expect(model.besideChatID == second.id)
        // The one beside is the checked row.
        #expect(try await rows(of: "thread.beside").map(\.checked) == [true])
    }

    @Test func openBesideCountsItsOwnListNotTheDrawersRows() async throws {
        defer { forget() }
        model.select(first)
        // Nothing is working, so the drawer filtered to Working has no row.
        model.drawerFilter = .working
        #expect(model.chats.isEmpty)
        #expect(try #require(model.paletteSearchable().first { $0.id == "thread.beside" }).unavailable == nil)
        #expect(try await rows(of: "thread.beside").count == 2)
        // With no other thread to bring, it says so.
        model.drawerFilter = .all
        second.archived = true
        third.archived = true
        try container.mainContext.save()
        #expect(try #require(model.paletteSearchable().first { $0.id == "thread.beside" }).unavailable == "No other thread")
    }

    @Test func closeOtherSideIsOfferedOnlyWithAPair() throws {
        defer { forget() }
        model.select(first)
        #expect(!model.paletteSearchable().contains { $0.id == "thread.closeOtherSide" })
        model.openBeside(second)
        let close = try #require(model.paletteSearchable().first { $0.id == "thread.closeOtherSide" })
        guard case .run(let run) = close.action else {
            Issue.record("Close other side doesn't run")
            return
        }
        run()
        #expect(model.besideChatID == nil)
        #expect(model.selectedChatID == first.id)
    }

    @Test func openBesideNeedsAThreadThatHasBegun() throws {
        defer { forget() }
        model.selectedProjectID = project.id
        model.selectedChatID = nil
        #expect(try #require(model.paletteSearchable().first { $0.id == "thread.beside" }).unavailable != nil)
    }
}
