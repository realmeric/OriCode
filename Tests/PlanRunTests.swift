import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A plan that runs itself (K-297): add_tasks' `run` makes the asking thread its owner, its ready
/// tasks start as threads under it within the ceiling, a task's thread ending its turn makes the
/// task done or stuck, what waits on it starts once it's done and merged, and the owner hears each.
@MainActor
struct PlanRunTests {
    private let container: ModelContainer
    private let project: Project

    init() throws {
        container = try TestStore.memory()
        project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        try container.mainContext.save()
    }

    /// The app as a launch makes it on the store, its engine ready.
    private func app() -> AppModel {
        let model = AppModel(container: container)
        model.support = FileManager.default.temporaryDirectory.appending(path: "oricode-run-\(UUID().uuidString)", directoryHint: .isDirectory)
        model.providers = [.claude]
        model.models = [ModelOption(id: "opus", name: "opus", description: "", efforts: ["low", "high"], fast: false, defaultEffort: nil, ultra: false, ultraBlocked: nil, more: nil, needs: nil)]
        model.engineState = .ready
        return model
    }

    private func model() throws -> (AppModel, Chat) {
        let model = app()
        let lead = Chat(project: project, title: "Lead", permissionMode: "acceptEdits")
        lead.provider = "claude"
        lead.model = "opus"
        lead.started = true
        container.mainContext.insert(lead)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = lead.id
        return (model, lead)
    }

    private func ask(_ model: AppModel, _ name: String, _ body: [String: JSON] = [:], from chat: Chat) throws -> JSON {
        var body = body
        body["event"] = .string(name)
        return try model.answerPlan(EngineEvent(name: name, threadId: chat.id.uuidString, body: .object(body)), from: chat.id)
    }

    private static let four: JSON = [
        ["title": "Write primes.py", "done": "it prints primes", "message": "Write primes.py.", "effort": "low", "worktree": true],
        ["title": "Write words.sh", "done": "it counts words", "message": "Write words.sh."],
        ["title": "Test primes.py", "done": "its tests pass", "message": "Test primes.py.", "waitsOn": ["T1"]],
        ["title": "Write WORDS.md", "done": "it says what words.sh printed", "message": "Write WORDS.md.", "waitsOn": ["T2"]],
    ]

    private func task(_ name: String) throws -> PlanTask {
        try #require(ProjectPlan(project).task(named: name))
    }

    /// The task's thread, opened under its owner as the runner opens it, with no engine to send to.
    private func opened(_ name: String, in model: AppModel) throws -> Chat {
        let task = try task(name)
        var request = AppModel.ThreadRequest(parent: try #require(task.owner), text: task.brief)
        request.title = task.title
        request.task = task.name
        request.effort = task.effort
        model.startingTasks.remove(task.id)
        let chat = try model.open(model.opening(for: request), request)
        if task.worktree { task.unmerged = true }
        return chat
    }

    private func done(_ chat: Chat, _ stopReason: String = "end_turn", replying reply: String = "Done.") -> [EngineEvent] {
        [EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["delta": .string(reply)]),
         EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: ["stopReason": .string(stopReason)])]
    }

    private func acts(_ conversation: Conversation) -> [String] {
        conversation.items.compactMap { if case .act(_, _, let text, let hover) = $0 { hover.isEmpty ? text : "\(text) · \(hover)" } else { nil } }
    }

    @Test func aPlanThatRunsStartsItsFreeTasksAtOnceUnderTheCeiling() throws {
        UserDefaults.standard.set(6, forKey: AppModel.ceilingKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey) }
        let (model, lead) = try model()
        let added = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        #expect(added["note"]?.string?.hasPrefix("T1 and T2 start now") == true)
        let first = try task("T1")
        #expect(first.owner == lead.id && first.brief == "Write primes.py." && first.effort == "low" && first.worktree)
        #expect(added["added"]?.array?.first?["runBy"]?["id"]?.string == lead.id.uuidString)
        // The two that wait on nothing are starting; the two that wait aren't.
        #expect(model.startingTasks == [first.id, try task("T2").id])

        // Held to one thread at once, only the first starts.
        model.startingTasks = []
        UserDefaults.standard.set(1, forKey: AppModel.ceilingKey)
        model.runPlans()
        #expect(model.startingTasks == [first.id])
    }

    @Test func aTaskToRunIsCheckedAsItsThreadWouldBe() throws {
        let (model, lead) = try model()
        func refusal(_ task: JSON) -> String? {
            do {
                _ = try ask(model, "plan.add", ["tasks": [task], "run": true], from: lead)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal(["title": "A", "done": "x"]) == "With run, each task needs the first message its thread is sent, in `message`: A has none.")
        #expect(refusal(["title": "A", "done": "x", "message": "go", "effort": "max"]) == "A: opus has no level called max. It has: low, high.")
        #expect(refusal(["title": "A", "done": "x", "message": "go", "agent": "nobody"])?.hasPrefix("A: No agent called nobody") == true)
        #expect(ProjectPlan(project).tasks.isEmpty)
        // Without run nothing of it is needed, and nothing starts.
        _ = try ask(model, "plan.add", ["tasks": [["title": "A", "done": "x"]]], from: lead)
        #expect(try task("T1").owner == nil && model.startingTasks.isEmpty)
    }

    @Test func aTaskDoneStartsWhatWaitedOnItOnceItsWorkIsMergedAndTheOwnerHearsIt() async throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let primes = try opened("T1", in: model)
        let words = try opened("T2", in: model)
        #expect(primes.openedBy == lead.id && primes.effort == "low")
        #expect(model.sendParams(in: primes, text: "hi", images: [])["task"]?["run"] == true)
        // The lead is at work, so it hears in wait_plan.
        let leading = model.conversation(for: lead)
        leading.userSent("Run it")

        for event in done(words, replying: "words.sh printed 12.\nIt counts runs of letters.") { model.route(event) }
        #expect(try task("T2").state == "done")
        #expect(try task("T2").note == "words.sh printed 12.")
        // T4 waited on T2 alone, and T2 worked beside the lead, so T4 starts.
        #expect(model.startingTasks.contains(try task("T4").id))

        for event in done(primes) { model.route(event) }
        #expect(try task("T1").state == "done")
        // T1 worked in a worktree: T3 waits for its work to come in.
        #expect(!model.startingTasks.contains(try task("T3").id))
        #expect(!model.startable(try task("T3")))

        let heard = try await model.waitPlan(from: lead.id)
        #expect(heard["ended"]?.array?.compactMap { $0["id"]?.string } == ["T1", "T2"])
        #expect(heard["ended"]?.array?.first?["merge"] == true)
        #expect(heard["ended"]?.array?.last?["reply"]?.string == "words.sh printed 12.\nIt counts runs of letters.")
        #expect(heard["planDone"] == false)
        #expect(try task("T1").heard && task("T2").heard)

        _ = try await model.merged(["thread": .string(primes.id.uuidString), "unmerged": true, "summary": "1 file, +3 −0"], from: lead.id)
        #expect(try !task("T1").unmerged)
        #expect(model.startingTasks.contains(try task("T3").id))
    }

    @Test func anOwnerThatIsntWorkingIsSentWhatEnded() throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let words = try opened("T2", in: model)
        for event in done(words, replying: "12 words.") { model.route(event) }
        let conversation = model.conversation(for: lead)
        #expect(conversation.running)
        // OriCode's own prompt starts the turn and draws nothing: no bubble, no line.
        #expect(!conversation.items.contains { if case .user = $0 { true } else { false } })
        #expect(acts(conversation).isEmpty)
        guard case .woke = conversation.items.last else { Issue.record("No woken turn"); return }
        #expect(TranscriptEntry.fold(conversation.items).isEmpty)
        // The store keeps what was sent, under its own kind, which neither search nor read_thread reads.
        let sent = try #require(StoredEvent.read(lead.id, from: container.mainContext).last { $0.kind == "wake" }?.body?["text"]?.string)
        #expect(sent.hasPrefix("[OriCode] Tasks of the plan you run have ended."))
        #expect(sent.contains("T2 · Write words.sh is done. Its last reply:\n\n12 words."))
        #expect(sent.hasSuffix("Call wait_plan for the rest of the plan."))
        #expect(lead.turnFrom == nil)
        #expect(try task("T2").heard)
    }

    @Test func aTaskStoppedIsStuckStopsWhatWaitsOnItAndIsTakenUpAgainWhenItsThreadIsWrittenInto() async throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let words = try opened("T2", in: model)
        let conversation = model.conversation(for: lead)
        conversation.userSent("Run it")

        // The user's Stop on its composer.
        model.stop(in: words)
        for event in done(words, "interrupted", replying: "Counting") { model.route(event) }
        let stuck = try task("T2")
        #expect(stuck.state == "stuck" && stuck.note == "Stopped by you")
        #expect(!model.startable(try task("T4")))
        conversation.receive(EngineEvent(name: "turn.done", threadId: lead.id.uuidString, body: ["stopReason": "end_turn"]))
        #expect(acts(conversation).contains("Write words.sh stuck · T2 · Stopped by you · T4 waits on it"))
        conversation.userSent("Go on")

        let heard = try await model.waitPlan(from: lead.id)
        #expect(heard["ended"]?.array?.first?["state"] == "stuck")
        #expect(heard["ended"]?.array?.first?["wontStart"] == ["T4"])
        // Its owner is told the Stop was the user's, to leave to them.
        #expect(heard["ended"]?.array?.first?["stoppedByUser"]?.string?.hasPrefix("The user stopped its thread.") == true)

        // The user writes into it, and its turn ending by itself finishes the task.
        #expect(model.send("Count them again", images: [], in: words))
        #expect(try task("T2").state == "working")
        for event in done(words, replying: "12 words.") { model.route(event) }
        #expect(try task("T2").state == "done")
        #expect(model.startingTasks.contains(try task("T4").id))
    }

    @Test func aTaskALimitStoppedStillWorksGoesOnAtTheResetAndItsOwnerHearsIt() throws {
        UserDefaults.standard.removeObject(forKey: Limit.goOnKey)
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let words = try opened("T2", in: model)
        words.sessionId = "session"
        let resetsAt = Date.now.addingTimeInterval(3600)
        model.route(EngineEvent(name: "limited", threadId: words.id.uuidString,
                                body: ["resetsAt": .number(resetsAt.timeIntervalSince1970 * 1000), "window": "five_hour"]))
        for event in done(words, "stop_sequence", replying: "Counting") { model.route(event) }
        let waiting = try task("T2")
        #expect(waiting.state == "working" && waiting.note == "Limit · \(Limit.time(resetsAt))")

        // The reset comes, the thread goes on by itself, and its owner hears it did.
        words.resumeAt = Date.now.addingTimeInterval(-60)
        model.resumeDue()
        #expect(model.conversation(for: words).running && waiting.note.isEmpty)
        #expect(acts(model.conversation(for: lead)).last == "Write words.sh went on")
        for event in done(words, replying: "12 words.") { model.route(event) }
        #expect(waiting.state == "done")
    }

    @Test func stopOnTheOwnerHoldsItsPlanUntilItWorksAgain() throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let words = try opened("T2", in: model)
        model.stop(in: lead)
        #expect(lead.planHeld)
        for event in done(words) { model.route(event) }
        // Nothing more starts, and the lead isn't sent what ended.
        #expect(!model.startingTasks.contains(try task("T4").id))
        #expect(!model.conversation(for: lead).running)
        #expect(!(try task("T2").heard))
        // The user writes to it: the plan goes on.
        #expect(model.send("Carry on", images: [], in: lead))
        #expect(!lead.planHeld)
        #expect(model.startingTasks.contains(try task("T4").id))
    }

    @Test func stopOnTheOwnerHoldsItsPlanAcrossARelaunch() throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        let words = try opened("T2", in: model)
        model.stop(in: lead)
        model.save()

        let relaunched = app()
        relaunched.movePlans()
        // A turn ending anywhere after the launch, T2's here, neither wakes the lead nor starts T4.
        relaunched.conversation(for: words).userSent("Count them")
        for event in done(words, replying: "12 words.") { relaunched.route(event) }
        #expect(try task("T2").state == "done" && !task("T2").heard)
        #expect(!relaunched.conversation(for: lead).running)
        #expect(relaunched.startingTasks.isEmpty)
        #expect(relaunched.send("Carry on", images: [], in: lead))
        #expect(relaunched.startingTasks.contains(try task("T4").id))
    }

    @Test func aTurnStoppedByAThreadOrThatFailedSaysSoAndTheOwnerThatMergedOrWaitedHasHeardIt() async throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        model.conversation(for: lead).userSent("Run it")

        // stop_thread from the lead: the Stop isn't the user's.
        let words = try opened("T2", in: model)
        _ = try model.stop(words.id.uuidString, reason: "Enough", from: lead.id)
        for event in done(words, "interrupted") { model.route(event) }
        #expect(try task("T2").state == "stuck" && task("T2").note == "Stopped")
        #expect(try !task("T2").heard)
        _ = try await model.wait(on: words.id.uuidString, from: lead.id)
        #expect(try task("T2").heard)
        #expect(!model.startable(try task("T4")))

        // A turn that failed: the error is why, and what waits on it doesn't start.
        let primes = try opened("T1", in: model)
        model.route(EngineEvent(name: "error", threadId: primes.id.uuidString, body: ["message": "Claude Code exited: API Error 529 overloaded\nretry later"]))
        model.route(EngineEvent(name: "turn.done", threadId: primes.id.uuidString, body: ["stopReason": "error_during_execution"]))
        #expect(try task("T1").state == "stuck")
        #expect(try task("T1").note == "Stopped: Claude Code exited: API Error 529 overloaded")
        #expect(!model.startable(try task("T3")))

        // A send the engine turned down, taken up again by the user first.
        model.conversation(for: primes).userSent("Try again")
        model.planTurnStarts(in: primes)
        #expect(try task("T1").state == "working")
        model.conversation(for: primes).sendFailed("The engine isn't running.")
        model.turnEnded(primes.id)
        #expect(try task("T1").note == "Stopped: The engine isn't running.")

        // A done task merged by its owner has been heard.
        model.conversation(for: primes).userSent("Once more")
        model.planTurnStarts(in: primes)
        for event in done(primes) { model.route(event) }
        #expect(try task("T1").state == "done" && task("T1").unmerged && !task("T1").heard)
        _ = try await model.merged(["thread": .string(primes.id.uuidString), "unmerged": true, "summary": "1 file, +3 −0"], from: lead.id)
        #expect(try task("T1").heard && !task("T1").unmerged)
    }

    @Test func theEngineGoingStartsNothingAndTellsNobodyUntilItsBack() throws {
        UserDefaults.standard.set(2, forKey: AppModel.ceilingKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey) }
        let (model, lead) = try model()
        let three: JSON = [["title": "A", "done": "x", "message": "Do A."], ["title": "B", "done": "x", "message": "Do B."], ["title": "C", "done": "x", "message": "Do C."]]
        _ = try ask(model, "plan.add", ["tasks": three, "run": true], from: lead)
        #expect(model.startingTasks == [try task("T1").id, try task("T2").id])
        _ = try opened("T1", in: model)
        _ = try opened("T2", in: model)

        // Mid-turn the engine goes: no turn.done, the tasks stuck all the same.
        model.engineState = .stopped
        model.engineStopped()
        #expect(try task("T1").state == "stuck" && task("T2").state == "stuck")
        #expect(try task("T1").note == "Stopped: The engine stopped in the middle of this turn.")
        // The ceiling has room, but nothing starts and the lead isn't sent anything.
        #expect(model.startingTasks.isEmpty)
        #expect(!model.conversation(for: lead).running)
        #expect(try !task("T1").heard)

        model.engineState = .ready
        model.movePlans()
        let sent = try StoredEvent.read(lead.id, from: container.mainContext).last { $0.kind == "wake" }?.body?["text"]?.string ?? ""
        #expect(sent.contains("T1 · A is stuck: Stopped: "))
        #expect(try task("T1").heard && task("T2").heard)
        #expect(model.startingTasks == [try task("T3").id])
    }

    @Test func aDeletedThreadLeavesItsTaskStuckAndADeletedTaskLetsWhatWaitedStart() throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": Self.four, "run": true], from: lead)
        model.conversation(for: lead).userSent("Run it")
        let primes = try opened("T1", in: model)
        let words = try opened("T2", in: model)
        for event in done(primes) { model.route(event) }
        #expect(try task("T1").unmerged)

        // Done but not merged: nobody can merge it now.
        model.delete(primes)
        #expect(try task("T1").state == "stuck" && !task("T1").unmerged)
        #expect(try task("T1").note == "Its thread was deleted before its work was merged.")
        // Deleted while it works: it can't end there.
        model.delete(words)
        #expect(try task("T2").state == "stuck" && task("T2").note == "Its thread was deleted before it finished.")
        #expect(!model.startable(try task("T4")))

        // The user deletes T2 on ⌘⇧I, and T4, which waited on it alone, starts.
        model.deleteTask(try task("T2"))
        #expect(model.startingTasks.contains(try task("T4").id))
    }

    @Test func aWaitThatRunsOutSaysWhatIsWorkingAndWhatWaitsForRoom() async throws {
        UserDefaults.standard.set(2, forKey: AppModel.ceilingKey)
        defer { UserDefaults.standard.removeObject(forKey: AppModel.ceilingKey) }
        let (model, lead) = try model()
        let two: JSON = [["title": "A", "done": "x", "message": "Do A."], ["title": "B", "done": "x", "message": "Do B."]]
        // The lead and a thread working A fill the ceiling of two, so B waits for room.
        let busy = Chat(project: project, title: "A", permissionMode: "acceptEdits")
        container.mainContext.insert(busy)
        model.conversation(for: lead).userSent("Run it")
        model.conversation(for: busy).userSent("Do A.")
        _ = try ask(model, "plan.add", ["tasks": two, "run": true], from: lead)
        #expect(model.startingTasks.isEmpty)
        try task("T1").state = "working"
        try task("T1").thread = busy.id
        let answer = try await model.waitPlan(from: lead.id, within: .milliseconds(20))
        #expect(answer["note"]?.string == "Still working: T1. T2 starts once fewer threads are working than the user allows at once. Call wait_plan again.")
    }

    @Test func aPlanWithNothingLeftToHappenAnswersAtOnce() async throws {
        let (model, lead) = try model()
        _ = try ask(model, "plan.add", ["tasks": [["title": "A", "done": "x", "message": "Do A."]], "run": true], from: lead)
        let a = try opened("T1", in: model)
        model.conversation(for: lead).userSent("Run it")
        for event in done(a) { model.route(event) }
        _ = try await model.waitPlan(from: lead.id)
        // Heard already, and nothing works: the wait doesn't sit five minutes.
        let again = try await model.waitPlan(from: lead.id, within: .seconds(30))
        #expect(again["planDone"] == true)
        #expect(again["note"]?.string == "Every task you run is done. Bring their results together.")
    }
}
