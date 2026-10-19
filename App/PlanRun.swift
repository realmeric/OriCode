import Foundation

/// A plan that runs itself (K-297): the tasks a thread added with add_tasks' `run` start as
/// threads under it, its owner, each once every task it waits on is done, its thread's turn over
/// and its worktree's work merged into the owner's folder. A task's thread is opened as
/// open_thread opens one, under the same ceiling and mode, so it is a full thread the user can
/// write into and stop. Its turn ending by itself makes the task done, its last reply the result;
/// stopped or failed, the task is stuck, and what waits on it doesn't start. The owner hears each
/// end in wait_plan, or in a message when it isn't working. Nothing polls: the plan moves when a
/// turn ends, a task changes, a merge comes in, a turn starts, a thread is deleted or the engine
/// is ready again; while it's gone, nothing starts and nobody is told.
extension AppModel {
    /// The tasks a thread runs, in every project.
    func runTasks(of owner: UUID) -> [PlanTask] {
        projects.flatMap(\.tasks).filter { $0.owner == owner }
    }

    /// Whether a task its plan runs can start now, by what it waits on: each done, its thread's
    /// turn over and its work, from a worktree, merged.
    func startable(_ task: PlanTask) -> Bool {
        guard let project = task.project, task.owner != nil, task.state == "open", !startingTasks.contains(task.id) else { return false }
        let plan = ProjectPlan(project)
        guard plan.state(of: task) == .ready else { return false }
        return task.waitsOn.compactMap { number in plan.tasks.first { $0.number == number } }.allSatisfy { waited in
            !waited.unmerged && waited.thread.map { conversations[$0]?.running != true } ?? true
        }
    }

    /// Starts every task that can start, as long as the ceiling leaves room, oldest plan first.
    func runPlans() {
        guard engineState == .ready else { return }
        let ready = projects.flatMap(\.tasks).filter { task in
            guard let owner = task.owner.flatMap(chat(withID:)), !owner.archived, !owner.planHeld else { return false }
            return startable(task)
        }.sorted { ($0.createdAt, $0.number) < ($1.createdAt, $1.number) }
        for task in ready {
            guard conversations.values.count(where: \.running) + startingTasks.count < threadsAtOnce else { return }
            start(task)
        }
    }

    /// The task's thread, opened under its owner with what the owner asked for it.
    private func start(_ task: PlanTask) {
        guard let owner = task.owner, let project = task.project else { return }
        startingTasks.insert(task.id)
        let plan = ProjectPlan(project)
        let after = task.waitsOn.compactMap { number in plan.tasks.first { $0.number == number }?.name }
        var request = ThreadRequest(parent: owner, text: task.brief)
        request.title = task.title
        request.reason = after.isEmpty ? "\(task.name) of the plan, which waits on nothing" : "\(task.name) of the plan, now that \(after.joined(separator: " and ")) \(after.count == 1 ? "is" : "are") done"
        request.agent = task.agent
        request.model = task.model
        request.effort = task.effort
        request.worktree = task.worktree
        request.task = task.name
        Task {
            defer { startingTasks.remove(task.id) }
            do {
                let (chat, _) = try await openThread(request)
                if chat.worktreeBranch != nil { task.unmerged = true }
                save()
            } catch {
                startingTasks.remove(task.id)
                // Full just now: it starts once a thread ends.
                guard (error as? Refused)?.full != true, task.state == "open" else { return }
                task.state = "stuck"
                task.note = "Its thread couldn't open: \(error.localizedDescription)"
                task.updatedAt = .now
                task.heard = false
                save()
                planChanged(task)
            }
        }
    }

    /// A thread's turn ended: the run task it works is done, or stuck when the turn was stopped or
    /// failed; the owners hear what ended, and whatever can start now starts.
    /// `stopped` is a turn the engine took with it, which no turn.done ended.
    func planTurnEnded(_ id: UUID, stopped: Bool = false) {
        let byUser = conversations[id]?.running != true && stoppedByUser.remove(id) != nil
        if let conversation = conversations[id] {
            for task in projects.flatMap(\.tasks) where task.thread == id && task.owner != nil && task.state == "working" {
                if conversation.endedByItself, !stopped {
                    task.state = "done"
                    if task.note.isEmpty { task.note = Self.firstLine(of: Self.lastText(in: conversation) ?? "Its turn ended with no reply.") }
                } else {
                    task.state = "stuck"
                    task.note = byUser && !stopped ? Self.stoppedByYou : Self.whyStopped(conversation)
                }
                task.heard = false
                task.updatedAt = .now
                save()
                stuckLine(task)
            }
        }
        tellOwners()
        runPlans()
    }

    /// What ended unheard is told and what can start starts: once the engine is ready, at launch
    /// or back after it stopped, and once a task is deleted.
    func movePlans() {
        tellOwners()
        runPlans()
    }

    /// A thread is deleted: a task it worked can't end there, so it's stuck, as is one done whose
    /// work in its worktree nobody can merge any more.
    func planThreadDeleted(_ id: UUID) {
        let held = projects.flatMap(\.tasks).filter { $0.thread == id && $0.owner != nil && ($0.state == "working" || $0.unmerged) }
        guard !held.isEmpty else { return }
        for task in held {
            task.note = task.state == "working" ? "Its thread was deleted before it finished." : "Its thread was deleted before its work was merged."
            task.state = "stuck"
            task.unmerged = false
            task.heard = false
            task.updatedAt = .now
            stuckLine(task)
        }
        save()
        movePlans()
    }

    /// A run task changed outside its thread's turn ending: by update_task, Stop on ⌘⇧I or a
    /// thread that couldn't open.
    func planChanged(_ task: PlanTask) {
        if task.state == "stuck", !task.heard { stuckLine(task) }
        tellOwners()
        runPlans()
    }

    /// A thread starts a turn: a run task it was stuck on is taken up again, so the user writing
    /// into a stopped task's thread finishes it, and a stopped owner's plan goes on.
    func planTurnStarts(in chat: Chat) {
        stoppedByUser.remove(chat.id)
        for task in projects.flatMap(\.tasks) where task.thread == chat.id && task.owner != nil && task.state == "stuck" {
            task.state = "working"
            task.note = ""
            task.updatedAt = .now
        }
        if chat.planHeld {
            chat.planHeld = false
            runPlans()
        }
    }

    /// Stop on a thread that runs a plan holds it: nothing more starts until it works again.
    func holdPlan(of chat: Chat) {
        if !runTasks(of: chat.id).isEmpty { chat.planHeld = true }
    }

    /// A task stuck stops what waits on it: its owner's transcript says so, with why.
    private func stuckLine(_ task: PlanTask) {
        guard task.state == "stuck", let owner = task.owner.flatMap(chat(withID:)) else { return }
        let waiting = dependents(of: task).map(\.name)
        let thread = task.thread.flatMap(chat(withID:))
        let act = ThreadAct(act: .stuck, by: false, thread: thread?.id ?? owner.id, title: thread?.title ?? task.title, reason: task.note,
                            what: waiting.isEmpty ? task.name : "\(task.name), so \(waiting.joined(separator: " and ")) won't start")
        line("thread.act", act.json, in: owner) { $0.threadAct(act) }
    }

    /// The tasks that wait on it, at any depth, not done.
    func dependents(of task: PlanTask) -> [PlanTask] {
        guard let project = task.project else { return [] }
        var found: [PlanTask] = []
        var next = [task.number]
        while let number = next.popLast() {
            for other in project.tasks where other.waitsOn.contains(number) && other.state != "done" && !found.contains(where: { $0.id == other.id }) {
                found.append(other)
                next.append(other.number)
            }
        }
        return found.sorted { $0.number < $1.number }
    }

    /// The ends an owner hasn't heard, of tasks whose thread's turn is over.
    func unheard(of owner: UUID) -> [PlanTask] {
        runTasks(of: owner).filter { task in
            !task.heard && (task.state == "done" || task.state == "stuck") && task.thread.map { conversations[$0]?.running != true } ?? true
        }.sorted { $0.number < $1.number }
    }

    /// Each owner with ends unheard hears them: in its wait_plan while it works, or else in a
    /// message, sent as the task's thread messaging it, when its last turn wasn't stopped.
    private func tellOwners() {
        guard engineState == .ready else { return }
        for owner in Set(projects.flatMap(\.tasks).compactMap(\.owner)) {
            let ended = unheard(of: owner)
            guard !ended.isEmpty else { continue }
            if conversations[owner]?.running == true {
                wakePlanWaits(of: owner)
                continue
            }
            guard let chat = chat(withID: owner), !chat.archived, !chat.planHeld,
                  conversations.values.count(where: \.running) + startingTasks.count < threadsAtOnce
            else { continue }
            let from = ended.first?.thread.flatMap(self.chat(withID:))
            let text = report(ended, to: owner)
            guard whyTooLong(text, for: chat) == nil, !heldInBlock(chat), conversation(for: chat).waitingAfterQuit == false else { continue }
            if let from {
                conversation(for: chat).threadAct(ThreadAct(act: .messaged, by: false, thread: from.id, title: from.title,
                                                            reason: ended.map { "\($0.name) \($0.state)" }.joined(separator: ", ")))
            }
            guard send(text, images: [], in: chat, from: from) else { continue }
            for task in ended { task.heard = true }
            save()
        }
    }

    /// wait_plan's calls the owner has running answer now.
    private func wakePlanWaits(of owner: UUID) {
        guard let waits = turnWaits[owner] else { return }
        for (key, wait) in waits where wait.plan {
            wait.timer.cancel()
            wait.done.resume()
            turnWaits[owner]?[key] = nil
        }
        if turnWaits[owner]?.isEmpty == true { turnWaits[owner] = nil }
    }

    /// What an owner that isn't working is sent when tasks it runs have ended.
    private func report(_ ended: [PlanTask], to owner: UUID) -> String {
        var parts = ended.map { task in
            let thread = task.thread.flatMap(chat(withID:))
            let named = "\(task.name) · \(task.title)"
            guard task.state == "done" else {
                let waiting = dependents(of: task).map(\.name)
                return "\(named) is stuck: \(task.note)" + (waiting.isEmpty ? "" : " \(waiting.joined(separator: " and ")) \(waiting.count == 1 ? "waits" : "wait") on it and won't start until it's done.") + (task.note == Self.stoppedByYou ? " The user stopped it, so leave it to them." : "")
            }
            let reply = thread.flatMap { lastReply(of: $0) } ?? "It gave no reply."
            let merge = task.unmerged ? "\n\nIts work is in its worktree: bring it in with merge_thread, thread \(thread?.id.uuidString ?? "")." : ""
            return "\(named) is done. Its last reply:\n\n\(reply)\(merge)"
        }
        parts.append(runTasks(of: owner).allSatisfy { $0.state == "done" } ? "Every task of the plan you run is done." : "Call wait_plan for the rest of the plan.")
        return "[OriCode] Tasks of the plan you run have ended.\n\n" + parts.joined(separator: "\n\n")
    }

    /// wait_plan: answered at once with what ended unheard, an ask, or a plan with nothing left to
    /// happen without the owner; else when a task it runs ends, an ask comes, or five minutes pass.
    func waitPlan(from asking: UUID, within limit: Duration = .seconds(300)) async throws -> JSON {
        guard let owner = chat(withID: asking) else { throw Refused(why: "The thread that asked is gone.") }
        guard !runTasks(of: asking).isEmpty else { throw Refused(why: "This thread runs no task of the plan. add_tasks with `run` starts some.") }
        if unheard(of: asking).isEmpty, asksHeld(by: asking).isEmpty, !settled(asking) {
            let key = UUID()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let timer = Task {
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    self.turnWaits[asking]?.removeValue(forKey: key)?.done.resume()
                }
                turnWaits[asking, default: [:]][key] = TurnWait(done: done, timer: timer, waiter: asking, plan: true)
            }
        }
        var answer: [String: JSON] = [:]
        let held = asksHeld(by: asking)
        if !held.isEmpty {
            answer["asks"] = .array(held.map { told($0, to: owner) })
            for waiting in held { heldAskRead(waiting.id) }
            answer["note"] = .string("A thread you set going asks you something. Answer each ask with answer_ask, then call wait_plan again.")
            return .object(answer)
        }
        let ended = unheard(of: asking)
        answer["ended"] = .array(ended.map { task in
            let thread = task.thread.flatMap(chat(withID:))
            var json: [String: JSON] = ["id": .string(task.name), "title": .string(task.title), "state": .string(task.state)]
            if let thread { json["thread"] = ["id": .string(thread.id.uuidString), "title": .string(thread.title)] }
            if task.state == "done" {
                json["reply"] = thread.flatMap { lastReply(of: $0) }.map(JSON.string) ?? .null
                if task.unmerged { json["merge"] = true }
            } else {
                json["note"] = .string(task.note)
                let waiting = dependents(of: task).map(\.name)
                if !waiting.isEmpty { json["wontStart"] = .array(waiting.map(JSON.string)) }
                // Taking it up again would undo the user's Stop.
                if task.note == Self.stoppedByYou { json["stoppedByUser"] = .string("The user stopped its thread. Don't message it or reopen the task yourself: tell the user what waits on it, and they'll write into its thread when they want it to go on.") }
            }
            return .object(json)
        })
        // An answer the engine took with it reached nobody, so its ends are told once it's back.
        if engineState == .ready {
            for task in ended { task.heard = true }
            save()
        }
        let tasks = runTasks(of: asking).sorted { $0.number < $1.number }
        answer["plan"] = .array(tasks.compactMap { task in task.project.map { taskJSON(task, in: ProjectPlan($0), for: owner) } })
        let done = tasks.allSatisfy { $0.state == "done" }
        answer["planDone"] = .bool(done)
        if done {
            answer["note"] = .string("Every task you run is done." + (tasks.contains(where: \.unmerged) ? " Merge the ones that say merge before you bring their results together." : " Bring their results together."))
        } else if ended.isEmpty {
            answer["note"] = .string(settled(asking) ? whyStill(asking) : stillGoing(tasks))
        } else if tasks.contains(where: \.unmerged) {
            answer["note"] = .string("Merge each done task that says merge with merge_thread, since what waits on it starts once it's in; then call wait_plan again.")
        }
        return .object(answer)
    }

    /// Nothing more happens in the plan without its owner: no task working or starting, and none
    /// that could start but for the ceiling.
    private func settled(_ owner: UUID) -> Bool {
        let tasks = runTasks(of: owner)
        return !tasks.contains { $0.state == "working" || startingTasks.contains($0.id) || startable($0) }
    }

    /// What a plan that isn't settled is doing, when five minutes brought no end.
    private func stillGoing(_ tasks: [PlanTask]) -> String {
        func names(_ some: [PlanTask]) -> String { some.map(\.name).joined(separator: " and ") }
        let working = tasks.filter { $0.state == "working" }
        let starting = tasks.filter { startingTasks.contains($0.id) }
        let room = tasks.filter(startable)
        var still: [String] = []
        if !working.isEmpty { still.append("Still working: \(working.map(\.name).joined(separator: ", ")).") }
        if !starting.isEmpty { still.append("\(names(starting)) \(starting.count == 1 ? "is" : "are") starting.") }
        if !room.isEmpty { still.append("\(names(room)) \(room.count == 1 ? "starts" : "start") once fewer threads are working than the user allows at once.") }
        return (still + ["Call wait_plan again."]).joined(separator: " ")
    }

    /// What holds a settled plan that isn't done.
    private func whyStill(_ owner: UUID) -> String {
        let tasks = runTasks(of: owner)
        let unmerged = tasks.filter(\.unmerged).map(\.name)
        let stuck = tasks.filter { $0.state == "stuck" }.map(\.name)
        var why: [String] = []
        if !unmerged.isEmpty { why.append("\(unmerged.joined(separator: " and ")) \(unmerged.count == 1 ? "waits" : "wait") to be merged with merge_thread before what waits on \(unmerged.count == 1 ? "it" : "them") can start") }
        if !stuck.isEmpty { why.append("\(stuck.joined(separator: " and ")) \(stuck.count == 1 ? "is" : "are") stuck, so what waits on \(stuck.count == 1 ? "it" : "them") won't start: tell the user, who can write into its thread to take it up again") }
        if chat(withID: owner)?.planHeld == true { why.append("the user stopped this thread, which holds the plan until it works again") }
        return "Nothing more starts on its own: " + (why.isEmpty ? "no task can start." : why.joined(separator: "; ") + ".")
    }

    /// A thread's last reply: from its conversation in memory, or the store.
    private func lastReply(of thread: Chat) -> String? {
        if let conversation = conversations[thread.id], let text = Self.lastText(in: conversation) {
            return text.count > OtherThreads.page ? String(text.prefix(OtherThreads.page)) + "…" : text
        }
        return OtherThreads.lastReply(of: thread.id, in: context)
    }

    private static func lastText(in conversation: Conversation) -> String? {
        for item in conversation.items.reversed() {
            if item.startsTurn { return nil }
            if case .text = item { return item.text?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        }
        return nil
    }

    private static func firstLine(of text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 200 ? String(line.prefix(199)) + "…" : line
    }

    /// Why a turn that didn't end by itself ended: its last note when the turn has one.
    private static func whyStopped(_ conversation: Conversation) -> String {
        for item in conversation.items.reversed() {
            if item.startsTurn { break }
            if case .note(_, let text) = item, !text.isEmpty { return "Its turn ended before it finished: \(firstLine(of: text))" }
        }
        return "Its turn was stopped before it finished."
    }
}
