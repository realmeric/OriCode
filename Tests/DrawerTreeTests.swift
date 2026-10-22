import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct DrawerTreeTests {
    /// Lead opened Primes and Words, and Primes opened Test; Other is a thread of its own.
    private func model(in container: ModelContainer? = nil) throws -> (AppModel, lead: Chat, primes: Chat, words: Chat, test: Chat, other: Chat) {
        let container = try container ?? TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(alpha)
        let start = Date(timeIntervalSince1970: 1_000)
        func thread(_ title: String, after seconds: Double, openedBy opener: Chat? = nil) -> Chat {
            let chat = Chat(project: alpha, title: title)
            chat.started = true
            chat.createdAt = start.addingTimeInterval(seconds)
            chat.openedBy = opener?.id
            context.insert(chat)
            return chat
        }
        let other = thread("Other", after: 0)
        let lead = thread("Lead", after: 1)
        let primes = thread("Primes", after: 2, openedBy: lead)
        let words = thread("Words", after: 3, openedBy: lead)
        let test = thread("Test", after: 4, openedBy: primes)
        try context.save()
        let model = AppModel(container: container)
        model.selectedProjectID = alpha.id
        model.selectedChatID = other.id
        return (model, lead, primes, words, test, other)
    }

    @Test func aThreadSitsFoldedUnderTheOneThatOpenedIt() throws {
        let (model, lead, primes, words, test, other) = try model()

        #expect(model.chats.map(\.title) == ["Lead", "Other"])
        let tree = model.drawerTree
        #expect(tree.map(\.chat.title) == ["Lead", "Other"])
        #expect(tree[0].children?.map(\.chat.title) == ["Primes", "Words"])
        #expect(tree[0].children?[0].children?.map(\.chat.title) == ["Test"])
        // A thread that opened none has no fold.
        #expect(tree[1].children == nil && tree[0].children?[1].children == nil)
        #expect(model.drawerRows.map(\.title) == ["Lead", "Other"])
        #expect(Set(model.threads(under: lead).map(\.id)) == [primes.id, words.id, test.id])
        _ = other
    }

    @Test func openingAThreadUnfoldsTheThreadsAboveIt() throws {
        let (model, lead, primes, _, test, _) = try model()

        // ⌘K opens a thread by its id, as a line in another thread does.
        model.open(chatID: test.id)
        #expect(model.unfolded == [lead.id, primes.id])
        #expect(model.drawerRows.map(\.title) == ["Lead", "Primes", "Test", "Words", "Other"])
        model.unfolded.remove(primes.id)
        #expect(model.drawerRows.map(\.title) == ["Lead", "Primes", "Words", "Other"])
        // ⌃Tab steps through the rows in sight.
        model.select(primes)
        model.stepThread(1)
        #expect(model.chat?.title == "Words")
    }

    @Test func openingAThreadUnfoldsAFoldedThreadAboveAnUnfoldedOne() throws {
        let (model, lead, primes, _, test, other) = try model()

        model.open(chatID: test.id)
        model.unfolded.remove(lead.id)
        model.select(other)
        model.open(chatID: test.id)
        #expect(model.unfolded == [lead.id, primes.id])
        #expect(model.drawerRows.map(\.title) == ["Lead", "Primes", "Test", "Words", "Other"])
    }

    @Test func aLaunchUnfoldsTheThreadsAboveTheOpenOne() throws {
        let container = try TestStore.memory()
        let (model, lead, primes, _, test, _) = try model(in: container)
        model.select(test)

        let next = AppModel(container: container)
        #expect(next.selectedChatID == test.id)
        #expect(next.unfolded == [lead.id, primes.id])
        #expect(next.drawerRows.map(\.title) == ["Lead", "Primes", "Test", "Words", "Other"])
    }

    @Test func ctrlTabStepsFromTheRowAboveAnOpenThreadFoldedAway() throws {
        let (model, lead, _, _, test, _) = try model()

        model.open(chatID: test.id)
        model.unfolded.remove(lead.id)
        #expect(model.drawerRows.map(\.title) == ["Lead", "Other"])
        model.stepThread(1)
        #expect(model.chat?.title == "Other")
        model.open(chatID: test.id)
        model.unfolded.remove(lead.id)
        model.stepThread(-1)
        #expect(model.chat?.title == "Lead")
    }

    @Test func nextThreadCountsTheRowsInSight() throws {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(alpha)
        let lead = Chat(project: alpha, title: "Lead")
        let worker = Chat(project: alpha, title: "Worker")
        worker.openedBy = lead.id
        for chat in [lead, worker] {
            chat.started = true
            context.insert(chat)
        }
        try context.save()
        let model = AppModel(container: container)
        model.drawerFilter = .project(alpha.id)
        model.select(lead)
        model.unfolded = []

        #expect(model.chats.count == 1 && model.drawerRows.count == 1)
        model.unfolded = [lead.id]
        #expect(model.chats.count == 1 && model.drawerRows.count == 2)
        model.stepThread(1)
        #expect(model.chat?.title == "Worker")
    }

    @Test func onlyTheTopRowsTakeADigitAndADrag() throws {
        let (model, lead, _, _, _, other) = try model()
        model.unfolded = [lead.id]

        model.pick(threadAt: 1)
        #expect(model.selectedChatID == other.id)
        model.moveThreads(from: [1], to: 0)
        #expect(model.chats.map(\.title) == ["Other", "Lead"])
        #expect(model.drawerTree[1].children?.map(\.chat.title) == ["Primes", "Words"])
    }

    @Test func aThreadGoesToTheArchiveWithTheThreadsUnderItAndComesBackWithThem() throws {
        let (model, lead, primes, words, test, _) = try model()

        model.conversation(for: test).userSent("Run the test")
        model.archive(lead)
        #expect(!lead.archived && !test.archived)
        #expect(model.note == "Stop the threads under it first")

        model.conversations[test.id] = nil
        model.archive(lead)
        #expect([lead, primes, words, test].allSatisfy { $0.archived })
        #expect(model.chats.map(\.title) == ["Other"])

        model.restore(lead)
        #expect(![lead, primes, words, test].contains { $0.archived })
        #expect(model.drawerTree[0].children?.map(\.chat.title) == ["Primes", "Words"])
    }

    @Test func restoringAThreadLeavesOneArchivedBeforeItInTheArchive() throws {
        let (model, lead, primes, words, test, _) = try model()

        model.archive(words)
        model.archive(lead)
        #expect([lead, primes, words, test].allSatisfy { $0.archived })

        model.restore(lead)
        #expect(![lead, primes, test].contains { $0.archived })
        #expect(words.archived)
        #expect(model.drawerTree[0].children?.map(\.chat.title) == ["Primes"])
    }

    @Test func restoringAThreadThatWentWithItsOpenerBringsBackWhatWentUnderIt() throws {
        let (model, lead, primes, words, test, _) = try model()

        model.archive(lead)
        model.restore(primes)
        #expect(!primes.archived && !test.archived)
        #expect(lead.archived && words.archived)
        // Its opener still archived, it stands at the top with its own under it.
        #expect(model.drawerTree.first { $0.id == primes.id }?.children?.map(\.chat.title) == ["Test"])
    }

    @Test func aThreadWhoseOpenerIsNotListedStandsOnItsOwn() throws {
        let (model, _, primes, _, test, _) = try model()

        model.delete(primes)
        #expect(model.chats.contains { $0.id == test.id })
        let top = model.drawerTree.first { $0.id == test.id }
        #expect(top != nil && top?.children == nil)
    }

    @Test func aThreadOpenedInAnotherFolderSitsUnderItsOpener() throws {
        let (model, lead, _, _, _, _) = try model()
        let context = model.context
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(beta)
        let build = Chat(project: beta, title: "Build")
        build.started = true
        build.createdAt = Date(timeIntervalSince1970: 1_005)
        build.openedBy = lead.id
        context.insert(build)
        let alpha = try #require(lead.project)
        let check = Chat(project: alpha, title: "Check")
        check.started = true
        check.openedBy = build.id
        context.insert(check)
        model.save()

        #expect(model.drawerTree[0].children?.map(\.chat.title) == ["Primes", "Words", "Build"])
        // Its opener's project lists it under the opener, and what it opened under it.
        model.drawerFilter = .project(alpha.id)
        #expect(model.chats.map(\.title) == ["Lead", "Other"])
        #expect(model.drawerTree[0].children?.map(\.chat.title) == ["Primes", "Words", "Build"])
        #expect(model.drawerTree[0].children?[2].children?.map(\.chat.title) == ["Check"])
        // Its own project, without its opener, has it at the top, with what it opened.
        model.drawerFilter = .project(beta.id)
        #expect(model.drawerTree.map(\.chat.title) == ["Build"])
        #expect(model.drawerTree[0].children?.map(\.chat.title) == ["Check"])
    }

    @Test func theArchivedFilterIsFlat() throws {
        let (model, _, primes, _, _, _) = try model()

        model.archive(primes)
        model.drawerFilter = .archived
        #expect(model.chats.map(\.title).sorted() == ["Primes", "Test"])
        #expect(model.drawerTree.allSatisfy { $0.children == nil })
    }
}

