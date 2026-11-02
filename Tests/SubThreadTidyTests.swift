import Foundation
import Link
import SwiftData
import Testing
@testable import OriCode

/// K-356: a finished sub-thread archives itself an hour after it was last at work, unless
/// something holds it, and a main thread never does.
@MainActor
@Suite(.serialized)
struct SubThreadTidyTests {
    private let cutoff = Date(timeIntervalSince1970: 100_000)

    /// Lead is a main thread; Sub and Deep sit under it, Deep under Sub; Elsewhere was opened by
    /// Lead from another project, which makes it that project's main thread. All were last at work
    /// long before the cutoff, and nothing is open.
    private func fixture() throws -> (AppModel, lead: Chat, sub: Chat, deep: Chat, elsewhere: Chat) {
        let container = try TestStore.memory()
        let context = container.mainContext
        let alpha = Project(name: "alpha", path: "/tmp/alpha")
        let beta = Project(name: "beta", path: "/tmp/beta")
        context.insert(alpha)
        context.insert(beta)
        func thread(_ title: String, in project: Project, under opener: Chat? = nil) -> Chat {
            let chat = Chat(project: project, title: title)
            chat.started = true
            chat.titleIsCustom = true
            chat.openedBy = opener?.id
            chat.owesOpener = opener == nil ? nil : false
            chat.createdAt = Date(timeIntervalSince1970: 1_000)
            chat.updatedAt = Date(timeIntervalSince1970: 2_000)
            context.insert(chat)
            return chat
        }
        let lead = thread("Lead", in: alpha)
        let sub = thread("Sub", in: alpha, under: lead)
        let deep = thread("Deep", in: alpha, under: sub)
        let elsewhere = thread("Elsewhere", in: beta, under: lead)
        try context.save()
        let model = AppModel(container: container)
        model.engineState = .ready
        model.selectedProjectID = alpha.id
        return (model, lead, sub, deep, elsewhere)
    }

    private func names(_ model: AppModel) -> Set<String> {
        Set(model.finishedSubThreads(before: cutoff).map(\.title))
    }

    @Test func aFinishedSubThreadGoesAndAMainThreadNever() throws {
        let (model, _, _, _, _) = try fixture()
        // Sub goes as the top of the two, and takes Deep with it; Lead and Elsewhere are main threads.
        #expect(names(model) == ["Sub"])
    }

    @Test func aThreadLastAtWorkLatelyStays() throws {
        let (model, _, sub, deep, _) = try fixture()
        sub.updatedAt = cutoff.addingTimeInterval(60)
        // Sub stays, so Deep, now the top of what qualifies, goes alone.
        #expect(names(model) == ["Deep"])
        deep.updatedAt = cutoff.addingTimeInterval(60)
        #expect(names(model).isEmpty)
    }

    @Test func pinnedOpenAndBesideStay() throws {
        let (model, _, sub, deep, _) = try fixture()
        deep.pinned = true
        #expect(names(model).isEmpty)
        deep.pinned = false
        model.selectedChatID = deep.id
        #expect(names(model).isEmpty)
        model.selectedChatID = nil
        model.besideChatID = sub.id
        // Sub stays, so Deep goes alone.
        #expect(names(model) == ["Deep"])
    }

    @Test func aTurnRunningOrAMessageQueuedKeepsIt() throws {
        let (model, _, sub, deep, _) = try fixture()
        model.conversation(for: deep).userSent("Run the test")
        #expect(names(model).isEmpty)
        model.conversations[deep.id] = nil
        deep.updatedAt = Date(timeIntervalSince1970: 2_000)
        #expect(names(model) == ["Sub"])
        model.conversation(for: sub).enqueue("And then this")
        #expect(names(model) == ["Deep"])
    }

    @Test func anAskWaitingKeepsIt() throws {
        let (model, _, _, deep, _) = try fixture()
        model.route(EngineEvent(name: "ask", threadId: deep.id.uuidString, body: [
            "event": "ask", "requestId": "r1", "kind": "permission", "tool": "Bash", "input": ["command": "make"],
        ]))
        #expect(model.conversations[deep.id]?.waitingAsk != nil)
        #expect(names(model).isEmpty)
    }

    @Test func aWorktreeNotMergedKeepsIt() throws {
        let (model, _, _, deep, _) = try fixture()
        deep.worktreeBranch = "oricode/deep"
        #expect(names(model).isEmpty)
    }

    @Test func whoOpenedItStillWaitingOnItKeepsIt() throws {
        let (model, lead, _, deep, _) = try fixture()
        // Its first turn's end isn't told yet.
        deep.owesOpener = true
        #expect(names(model).isEmpty)
        deep.owesOpener = false
        // A task of a plan its opener runs, not done, or done and not merged or not heard.
        let task = PlanTask(number: 1, title: "Check", doneWhen: "")
        task.project = lead.project
        task.thread = deep.id
        task.owner = lead.id
        model.context.insert(task)
        model.save()
        #expect(names(model).isEmpty)
        task.state = "done"
        task.unmerged = true
        #expect(names(model).isEmpty)
        task.unmerged = false
        task.heard = false
        #expect(names(model).isEmpty)
        task.heard = true
        #expect(names(model) == ["Sub"])
    }

    @Test func aSubThreadWithADraftOrALimitWaitStays() throws {
        let (model, _, sub, deep, _) = try fixture()
        model.composer(for: deep).draft.text = "half a thought"
        #expect(names(model).isEmpty)
        model.forgetComposer(of: deep.id)
        sub.resumeAt = .now.addingTimeInterval(600)
        #expect(names(model) == ["Deep"])
    }

    @Test func archivingTakesWhatIsUnderItAndRestoreBringsItBack() async throws {
        let (model, lead, sub, deep, elsewhere) = try fixture()
        // Aged by the real hour: the fixture's dates are 1970.
        let task = try #require(model.tidySubThreads(force: true))
        await task.value

        #expect(sub.archived && deep.archived)
        #expect(deep.archivedWith == sub.id && sub.archivedWith == nil)
        #expect(!lead.archived && !elsewhere.archived)
        #expect(model.archivedChats.contains { $0.id == sub.id })
        #expect(!model.chats.contains { $0.id == sub.id })
        model.restore(sub)
        #expect(!sub.archived && !deep.archived)
        // Brought back, it isn't taken again at once.
        #expect(model.finishedSubThreads(before: Date.now.addingTimeInterval(-AutoArchive.tidyAfter)).isEmpty)
    }

    @Test func offMeansNothingArchives() async throws {
        UserDefaults.standard.set(false, forKey: AutoArchive.tidyKey)
        defer { UserDefaults.standard.removeObject(forKey: AutoArchive.tidyKey) }
        let (model, _, sub, deep, _) = try fixture()

        #expect(model.tidySubThreads(force: true) == nil)
        #expect(!sub.archived && !deep.archived && model.tidied == nil)
    }

    @Test func itIsOnUntilSettingsSaysOtherwise() {
        UserDefaults.standard.removeObject(forKey: AutoArchive.tidyKey)
        #expect(AutoArchive.tidies)
        #expect(MenuSetting.all.first { $0.name == "archive_finished_sub_threads" }?.value == .bool(true))
    }

    @Test func aMessageToAnArchivedSubThreadBringsItBack() async throws {
        let (model, lead, sub, _, _) = try fixture()
        await model.tidySubThreads(force: true)?.value
        #expect(sub.archived)
        // message_thread still finds it, among the archived, and writes as a composer would.
        let reached = try model.other(sub.id.uuidString, from: lead.id, doing: "message_thread")
        #expect(reached.thread.id == sub.id)
        model.conversation(for: sub).userSent("Pick this up again")
        #expect(!sub.archived && sub.archivedWith == nil)
    }

    /// The phone lists what the snapshot holds, and a thread it saw at work stays in `seen` for the
    /// launch; archived, it is out of the snapshot all the same, and back in once restored.
    @Test func anArchivedSubThreadLeavesThePhone() async throws {
        let (model, _, sub, _, _) = try fixture()
        model.phone.model = model
        model.phone.seen.insert(sub.id)
        let key = RecordName.thread(sub.id)
        #expect(model.phone.snapshot().threads[key] != nil)

        await model.tidySubThreads(force: true)?.value
        #expect(sub.archived)
        #expect(model.phone.snapshot().threads[key] == nil)
        model.restore(sub)
        #expect(model.phone.snapshot().threads[key] != nil)
    }

    @Test func tidyingIsNotRepeatedWithinAMinute() async throws {
        let (model, _, _, _, _) = try fixture()
        await model.tidySubThreads()?.value
        #expect(model.tidySubThreads() == nil)
        #expect(model.tidySubThreads(force: true) != nil)
    }
}
