import Foundation
import SwiftData
import Testing
@testable import OriCode

@MainActor
struct DrawerListTests {
    /// Lead runs Primes and Words, its workflow's agents, and Primes's subagent is Test; Other is a
    /// thread of its own.
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
            if opener != nil { chat.agentID = "agent-\(title)" }
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

    @Test func theDrawerListsTopThreadsAlone() throws {
        let (model, lead, primes, words, test, other) = try model()

        #expect(model.chats.map(\.title) == ["Lead", "Other"])
        #expect(model.topThreads[test.id] == lead.id && model.topThreads[other.id] == other.id)
        #expect(Set(model.threads(under: lead).map(\.id)) == [primes.id, words.id, test.id])
        // Opened from ⌘K or a line in another thread, it's open with no row of its own.
        model.open(chatID: test.id)
        #expect(model.selectedChatID == test.id && model.chats.map(\.title) == ["Lead", "Other"])
    }

    /// A thread an agent opened in the same project sits under it, and ⌘⇧I and ⌘K reach it: the
    /// drawer shows the threads the user writes to (Meriç, 2026-10-31).
    @Test func aThreadOpenedInTheSameProjectHasNoRow() throws {
        let (model, lead, _, _, _, _) = try model()
        let opened = Chat(project: try #require(lead.project), title: "Phone plan")
        opened.started = true
        opened.openedBy = lead.id
        model.context.insert(opened)
        model.save()

        #expect(model.chats.map(\.title) == ["Lead", "Other"])
        #expect(model.topThreads[opened.id] == lead.id)
    }

    /// As blackjack went: a No folder thread opened "Araştırma ve Kanban planı" there, which ran
    /// the project, claimed tasks of its plan and opened everything else, and had no row at all.
    @Test func aThreadOpenedInAnotherProjectIsThatProjectsMainThread() throws {
        let (model, lead, _, _, _, _) = try model()
        let beta = Project(name: "beta", path: "/tmp/beta")
        model.context.insert(beta)
        func thread(_ title: String, openedBy opener: Chat) -> Chat {
            let chat = Chat(project: beta, title: title)
            chat.started = true
            chat.openedBy = opener.id
            model.context.insert(chat)
            return chat
        }
        let main = thread("Plan", openedBy: lead)
        let part = thread("Part", openedBy: main)
        let task = PlanTask(number: 1, title: "Claimed", doneWhen: "")
        task.project = beta
        task.thread = main.id
        model.context.insert(task)
        model.save()

        #expect(model.topThreads[main.id] == main.id && model.topThreads[part.id] == main.id)
        #expect(model.chats.map(\.title).contains("Plan") && !model.chats.map(\.title).contains("Part"))
        model.drawerFilter = .project(beta.id)
        #expect(model.chats.map(\.title) == ["Plan"])
        // It's still work under the thread that opened it when that one goes to the archive.
        model.drawerFilter = .all
        model.archive(lead)
        #expect(main.archived && part.archived)
    }

    /// Every thread at work on ⌘⇧I has a row to find it by, itself or the main thread above it.
    @Test func everyThreadLeadsToARow() throws {
        let (model, lead, primes, words, test, other) = try model()
        let rows = Set(model.chats.map(\.id))
        for chat in [lead, primes, words, test, other] {
            #expect(model.topThreads[chat.id].map(rows.contains) == true)
        }
    }

    @Test func threadsSitByProjectWithTheNewestProjectFirst() throws {
        let (model, lead, _, _, _, other) = try model()
        let beta = Project(name: "beta", path: "/tmp/beta")
        model.context.insert(beta)
        let build = Chat(project: beta, title: "Build")
        build.started = true
        build.createdAt = Date(timeIntervalSince1970: 1_500)
        model.context.insert(build)
        let solo = Chat(project: beta, title: "Solo")
        solo.started = true
        solo.createdAt = Date(timeIntervalSince1970: 500)
        model.context.insert(solo)
        model.save()

        #expect(model.chats.map(\.title) == ["Build", "Solo", "Lead", "Other"])
        #expect(Chat.byProject(model.chats).map { $0.map(\.title) } == [["Build", "Solo"], ["Lead", "Other"]])
        // A pin takes its project to the top, and a turn ending moves nothing.
        model.togglePin(other)
        #expect(model.chats.map(\.title) == ["Other", "Lead", "Build", "Solo"])
        lead.updatedAt = .now
        #expect(model.chats.map(\.title) == ["Other", "Lead", "Build", "Solo"])
    }

    /// A week and more old, from the fixture's dates, with the cutoff well after them.
    private let cutoff = Date(timeIntervalSince1970: 100_000)

    private func aged(_ chats: Chat...) {
        for chat in chats { chat.updatedAt = Date(timeIntervalSince1970: 2_000) }
    }

    @Test func aMainThreadLeftAloneIsOldAndTakesWhatIsUnderIt() throws {
        let (model, lead, primes, words, test, other) = try model()
        model.selectedChatID = nil
        aged(lead, primes, words, test, other)

        #expect(Set(model.oldThreads(before: cutoff).map(\.title)) == ["Lead", "Other"])
        for chat in model.oldThreads(before: cutoff) { model.archive(chat) }
        #expect([lead, primes, words, test, other].allSatisfy { $0.archived })
        // Brought back, it isn't taken again by the next sweep.
        model.restore(lead)
        #expect(!model.oldThreads(before: cutoff).contains { $0.id == lead.id })
    }

    @Test func aThreadInUseIsNeverOld() throws {
        let (model, lead, primes, words, test, other) = try model()
        aged(lead, primes, words, test, other)

        // Open.
        #expect(model.oldThreads(before: cutoff).map(\.title) == ["Lead"])
        model.selectedChatID = nil
        // Pinned.
        model.togglePin(other)
        #expect(model.oldThreads(before: cutoff).map(\.title) == ["Lead"])
        // A thread under it worked lately.
        test.updatedAt = cutoff.addingTimeInterval(60)
        #expect(model.oldThreads(before: cutoff).isEmpty)
        aged(test)
        // A thread under it works.
        model.conversation(for: test).userSent("Run the test")
        #expect(model.oldThreads(before: cutoff).isEmpty)
        model.conversations[test.id] = nil
        aged(test)
        // Something typed and not sent.
        model.composer(for: lead).draft.text = "half a thought"
        #expect(model.oldThreads(before: cutoff).isEmpty)
        model.forgetComposer(of: lead.id)
        // A task of a plan not done.
        let task = PlanTask(number: 1, title: "Open", doneWhen: "")
        task.project = lead.project
        task.thread = primes.id
        model.context.insert(task)
        model.save()
        #expect(model.oldThreads(before: cutoff).isEmpty)
        task.state = "done"
        #expect(model.oldThreads(before: cutoff).map(\.title) == ["Lead"])
    }

    @Test func ctrlTabStepsFromTheTopRowOfAThreadWithNoRow() throws {
        let (model, _, _, _, test, _) = try model()

        model.open(chatID: test.id)
        model.stepThread(1)
        #expect(model.chat?.title == "Other")
        model.open(chatID: test.id)
        model.stepThread(-1)
        #expect(model.chat?.title == "Lead")
    }

    @Test func workingAndWaitingListTheTopThreadOfWhatWorks() throws {
        let (model, _, _, _, test, _) = try model()

        model.conversation(for: test).userSent("Run the test")
        model.drawerFilter = .working
        #expect(model.chats.map(\.title) == ["Lead"])
        model.drawerFilter = .waiting
        #expect(model.chats.isEmpty)
    }

    @Test func digitsAndDragsAreTheRows() throws {
        let (model, _, _, _, _, other) = try model()

        model.pick(threadAt: 1)
        #expect(model.selectedChatID == other.id)
        model.moveThreads(in: try #require(other.project), from: [1], to: 0)
        #expect(model.chats.map(\.title) == ["Other", "Lead"])
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
        // The archive lists the one archived, and what went with it comes back with it.
        model.drawerFilter = .archived
        #expect(model.chats.map(\.title) == ["Lead"])

        model.restore(lead)
        #expect(![lead, primes, words, test].contains { $0.archived })
        #expect(model.chats.map(\.title) == ["Lead", "Other"])
    }

    @Test func restoringAThreadLeavesOneArchivedBeforeItInTheArchive() throws {
        let (model, lead, primes, words, test, _) = try model()

        model.archive(words)
        model.archive(lead)
        #expect([lead, primes, words, test].allSatisfy { $0.archived })

        model.restore(lead)
        #expect(![lead, primes, test].contains { $0.archived })
        #expect(words.archived)
        model.drawerFilter = .archived
        #expect(model.chats.map(\.title) == ["Words"])
    }

    @Test func aThreadWhoseOpenerIsNotListedHasARowOfItsOwn() throws {
        let (model, lead, primes, _, test, _) = try model()

        model.archive(lead)
        model.restore(primes)
        #expect(!primes.archived && !test.archived && lead.archived)
        #expect(model.chats.map(\.title) == ["Primes", "Other"])
    }

    @Test func aProjectListsItsOwnTopThreads() throws {
        let (model, lead, _, _, _, _) = try model()
        let context = model.context
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(beta)
        let build = Chat(project: beta, title: "Build")
        build.started = true
        build.openedBy = lead.id
        build.agentID = "agent-build"
        context.insert(build)
        let solo = Chat(project: beta, title: "Solo")
        solo.started = true
        context.insert(solo)
        model.save()

        let alpha = try #require(lead.project)
        model.drawerFilter = .project(alpha.id)
        #expect(model.chats.map(\.title) == ["Lead", "Other"])
        // Build sits under Lead, in whatever folder it was opened.
        model.drawerFilter = .project(beta.id)
        #expect(model.chats.map(\.title) == ["Solo"])
    }

    /// The header names the project picked there, not the open thread's, so the drawer keeps its
    /// shape when another project's thread opens.
    @Test func theHeaderKeepsItsProjectWhenAnotherProjectsThreadOpens() throws {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha"), beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(alpha)
        context.insert(beta)
        let there = Chat(project: beta, title: "There")
        there.started = true
        context.insert(there)
        try context.save()
        let model = AppModel(container: container)
        model.select(alpha)
        model.select(there)
        #expect(model.project?.id == beta.id)
        #expect(model.drawerProject?.id == alpha.id)
    }

    /// The first project added keeps its letters; one after it that would share them takes its next.
    @Test func twoProjectsNeverShareTheirLetters() throws {
        let container = try TestStore.memory()
        let context = container.mainContext
        let names = ["OriCode", "oricode-deneme", "oricode-deneme-2"]
        let projects = names.enumerated().map { index, name in
            let project = Project(name: name, path: "/tmp/\(index)")
            project.createdAt = Date(timeIntervalSince1970: Double(index))
            context.insert(project)
            return project
        }
        let letters = Project.initials(of: projects.reversed())
        #expect(projects.map { letters[$0.id] } == ["OE", "OD", "O2"])
    }
}
