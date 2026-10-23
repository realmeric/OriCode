import SwiftData
import SwiftUI

/// What an agent asks the app for through OriCode's own tools (engine/threads.ts): each arrives as
/// an event with a request id and is answered with `app.reply`. An agent does to threads what the
/// user can: a thread it opens is a thread like any other, made and sent to as the composer would,
/// and it messages, waits on and stops any thread as the composer and Stop would, each act a line
/// in both transcripts with its reason. In its way are a ceiling on threads working at once, set
/// in Settings › Agents, and its own permission mode, which no thread it opens or messages is
/// looser than. A thread it only suggests is an event in its transcript, and made by the user's
/// click. What it asks about the other threads is read from the store (OtherThreads).
extension AppModel {
    /// Threads working at once past which an agent can't set another going, so threads opening
    /// threads can't take the Mac. The user's own sends are never refused by it.
    static let ceilingKey = "threadsAtOnce"
    static let defaultCeiling = 6

    var threadsAtOnce: Int {
        max(1, UserDefaults.standard.object(forKey: Self.ceilingKey) as? Int ?? Self.defaultCeiling)
    }

    /// Refuses an act that would set one more thread working past the ceiling.
    func checkCeiling() throws {
        let working = conversations.values.count(where: \.running)
        guard working >= threadsAtOnce else { return }
        throw Refused(why: "\(working) threads are working, as many as the user allows at once in Settings › Agents. Wait for one with wait_thread or stop one, then try again.", full: true)
    }

    /// Why the app didn't do what a tool asked, in words the agent reads as the tool's error.
    /// `full` is the ceiling's refusal, which a plan's task waits out.
    struct Refused: LocalizedError {
        let why: String
        var full = false
        var errorDescription: String? { why }
    }

    /// What open_thread asked for: the thread it was called from, and the thread to make.
    struct ThreadRequest {
        var parent: UUID
        var title = ""
        var text: String
        var reason = ""
        var agent: String?
        var model: String?
        var folder: String?
        var worktree = false
        /// The task of the plan it's opened for, by its id.
        var task: String?
        /// A mode tighter than the parent's, asked for by its id.
        var mode: String?
        /// A level of its model's, which a plan's task names.
        var effort: String?

        init(parent: UUID, text: String) {
            self.parent = parent
            self.text = text
        }

        init(_ body: JSON, from parent: UUID) {
            self.init(parent: parent, text: body["text"]?.string ?? "")
            title = body["title"]?.string ?? ""
            reason = body["reason"]?.string ?? ""
            agent = body["agent"]?.string?.nonEmpty
            model = body["model"]?.string?.nonEmpty
            folder = body["folder"]?.string?.nonEmpty
            worktree = body["worktree"]?.bool ?? false
            task = body["task"]?.string?.nonEmpty
            mode = body["mode"]?.string?.nonEmpty
        }
    }

    /// A request worked out against the threads, projects and agents there are.
    struct Opening {
        let parent: Chat
        let project: Project
        let agent: ProviderInfo
        let model: String?
        let mode: String
        let effort: String?
        /// Whether it works where its parent does, a worktree included.
        let beside: Bool
        /// The task of the plan it takes as it opens, by its id and name, and the project whose
        /// plan it's in. open() finds it again there, since git may have run in between.
        var task: (id: UUID, name: String, plan: Project)?
    }

    /// The modes, tightest first: a thread opened on another agent gets none looser than its parent's.
    static let tightness = ["plan", "default", "acceptEdits", "auto", "bypassPermissions"]

    /// The mode a thread opened from one on `parent` runs in on `agent`: the parent's own on its
    /// own agent, and on another the loosest of that agent's that is no looser. An agent that asks
    /// before nothing has none unless the parent is on Don't ask. Nil when there is none.
    static func mode(under parent: String, on agent: ProviderInfo, same: Bool) -> String? {
        if same { return parent }
        let loosest = tightness.count - 1
        guard let limit = tightness.firstIndex(of: parent) else { return nil }
        if agent.unsupervised || agent.modes.isEmpty {
            guard limit == loosest else { return nil }
            return agent.modes.contains(parent) ? parent : agent.modes.first ?? parent
        }
        return tightness[...limit].last(where: agent.modes.contains)
    }

    /// An event that asks the app for something and waits on its answer.
    static let asks = Set(["thread.open", "thread.message", "thread.wait", "thread.answer", "thread.stop", "thread.merge", "thread.merged", "threads.list", "thread.read", "oricode.act"]).union(planAsks)

    func answerTool(_ event: EngineEvent, from thread: UUID) {
        guard let requestId = event.body["requestId"]?.string else { return }
        Task {
            var reply: [String: JSON] = ["requestId": .string(requestId)]
            do {
                reply["result"] = try await result(of: event, from: thread)
            } catch {
                reply["error"] = .string(error.localizedDescription)
            }
            _ = try? await engine.request("app.reply", .object(reply))
        }
    }

    private func result(of event: EngineEvent, from thread: UUID) async throws -> JSON {
        switch event.name {
        case "thread.open":
            let (chat, opening) = try await openThread(ThreadRequest(event.body, from: thread))
            return Self.made(chat, on: opening.agent, opening)
        case "thread.message":
            return try message(event.body["thread"]?.string ?? "", text: event.body["text"]?.string ?? "", reason: event.body["reason"]?.string ?? "", from: thread)
        case "thread.wait":
            return try await wait(on: event.body["thread"]?.string ?? "", from: thread)
        case "thread.answer":
            return try answerAsk(event.body, from: thread)
        case "thread.stop":
            return try stop(event.body["thread"]?.string ?? "", reason: event.body["reason"]?.string ?? "", from: thread)
        case "thread.merge":
            return try mergeTarget(event.body["thread"]?.string ?? "", from: thread)
        case "thread.merged":
            return try await merged(event.body, from: thread)
        case "threads.list":
            return try await listThreads(for: thread, edited: event.body["edited"]?.string?.nonEmpty, named: event.body["named"]?.string?.nonEmpty, skip: event.body["skip"]?.int ?? 0)
        case "thread.read":
            return try await readThread(event.body["thread"]?.string ?? "", before: event.body["before"]?.int, for: thread)
        case "oricode.act":
            return try await menuAct(event.body, from: thread)
        case "plan.wait":
            return try await waitPlan(from: thread)
        case "plan.add" where event.body["run"]?.bool == true:
            // Each task is checked as its thread would be, against the models its agent lists.
            for task in event.body["tasks"]?.array ?? [] {
                var request = ThreadRequest(parent: thread, text: "")
                request.agent = task["agent"]?.string?.nonEmpty
                request.model = task["model"]?.string?.nonEmpty
                request.effort = task["effort"]?.string?.nonEmpty
                await readModels(for: request)
            }
            return try answerPlan(event, from: thread)
        case _ where Self.planAsks.contains(event.name):
            return try answerPlan(event, from: thread)
        default:
            if MacHands.asks.contains(event.name) { return try await MacHands.answer(event, from: thread) }
            throw Refused(why: "OriCode doesn't know what \(event.name) asks for.")
        }
    }

    /// open_thread, and a plan's task starting: checked, its worktree made from the parent's
    /// folder as it is when it asks for one, then made and sent its first message.
    func openThread(_ request: ThreadRequest) async throws -> (Chat, Opening) {
        await readModels(for: request)
        let opening = try opening(for: request)
        var place: (path: String, branch: String)?
        if request.worktree {
            let slug = "t-" + UUID().uuidString.prefix(6).lowercased()
            let prefix = UserDefaults.standard.string(forKey: NewThreads.branchPrefix) ?? NewThreads.defaultBranchPrefix
            let reply = try await engine.request("worktree.add", ["cwd": .string(opening.project.path), "slug": .string(slug), "prefix": .string(prefix), "from": .string(opening.parent.cwd)])
            guard let path = reply["path"]?.string, let branch = reply["branch"]?.string else { throw Refused(why: "Git made no worktree for it.") }
            place = (path, branch)
        }
        let chat: Chat
        do {
            chat = try open(opening, request, in: place)
        } catch {
            if let place {
                _ = try? await engine.request("worktree.remove", ["cwd": .string(opening.project.path), "path": .string(place.path), "branch": .string(place.branch)])
            }
            throw error
        }
        refreshBranch(for: chat)
        return (chat, opening)
    }

    /// What the tool answers: the thread as it was made, for the agent to tell the user, and the
    /// id read_thread takes to see what it did.
    static func made(_ chat: Chat, on agent: ProviderInfo, _ opening: Opening? = nil) -> JSON {
        var made: [String: JSON] = [
            "thread": .string(chat.title), "id": .string(chat.id.uuidString), "agent": .string(agent.id), "mode": .string(chat.permissionMode), "folder": .string(chat.cwd),
        ]
        if let model = chat.model { made["model"] = .string(model) }
        if let branch = chat.worktreeBranch { made["branch"] = .string(branch) }
        if let task = opening?.task { made["task"] = .string(task.name) }
        return .object(made)
    }

    /// A named model or level is checked against its agent's list, which another agent's CLI gives
    /// only once a menu has asked for it: asked here when none has.
    private func readModels(for request: ThreadRequest) async {
        guard request.model != nil || request.effort != nil, let id = request.agent ?? chat(withID: request.parent)?.providerID, models(of: id).isEmpty,
              providers.first(where: { $0.id == id })?.state == .ready,
              let reply = try? await engine.request("models.list", ["provider": .string(id)]),
              let list = try? reply["models"]?.decode([ModelOption].self)
        else { return }
        modelsByAgent[id] = list
    }

    /// Checks a request before anything is made, so a refusal leaves no thread and no worktree.
    /// Without `ceiling`, a plan's task is checked as it's added, to start later.
    func opening(for request: ThreadRequest, ceiling: Bool = true) throws -> Opening {
        guard let parent = chat(withID: request.parent), let own = parent.project else { throw Refused(why: "The thread that asked is gone.") }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refused(why: "A thread needs its first message.") }
        if ceiling { try checkCeiling() }

        let id = request.agent ?? parent.providerID
        guard let agent = providers.first(where: { $0.id == id }) else {
            throw Refused(why: "No agent called \(id) is turned on in OriCode. Those that are: \(providers.map(\.id).joined(separator: ", ")).")
        }
        let same = id == parent.providerID
        guard same || agent.state == .ready else { throw Refused(why: "\(agent.name) can't run here yet\(agent.hint.map { ": \($0)" } ?? ".")") }
        // A head that chooses opens no thread on a model heads keep off, its own included.
        let keptOff = Rays.choose && offersWorkers(parent) ? Set(headsKeepOff) : []
        if let model = request.model {
            guard !models(of: id).isEmpty else { throw Refused(why: "\(agent.name) didn't list its models just now, so OriCode can't tell whether \(model) is one. Leave the model out, or try again.") }
            let listed = models(of: id).filter { !keptOff.contains("\(id)/\($0.id)") }
            guard listed.contains(where: { $0.id == model }) else {
                throw Refused(why: keptOff.contains("\(id)/\(model)")
                    ? "The user keeps heads off \(model) in Settings › Agents. \(agent.name) has: \(listed.map(\.id).joined(separator: ", "))."
                    : "\(agent.name) has no model called \(model). It has: \(listed.map(\.id).joined(separator: ", ")).")
            }
        }
        let model = request.model ?? (same ? parent.model : nil)
        if let model, keptOff.contains("\(id)/\(model)") {
            throw Refused(why: "This thread is on \(model), which the user keeps heads off in Settings › Agents, so a thread it opens can't take it. Name another \(agent.name) model.")
        }
        guard var mode = Self.mode(under: parent.permissionMode, on: agent, same: same) else {
            let title = PermissionModeOption(rawValue: parent.permissionMode)?.title ?? parent.permissionMode
            throw Refused(why: agent.unsupervised || agent.modes.isEmpty
                ? "\(agent.name) asks before nothing, and this thread is on \(title)."
                : "\(agent.name) has no permission mode as tight as this thread's, \(title).")
        }
        if let asked = request.mode, asked != mode {
            guard agent.modes.contains(asked) else {
                throw Refused(why: "\(agent.name) has no permission mode called \(asked). It has: \(agent.modes.joined(separator: ", ")).")
            }
            guard let tighter = Self.tightness.firstIndex(of: asked), let limit = Self.tightness.firstIndex(of: mode), tighter <= limit else {
                let title = PermissionModeOption(rawValue: mode)?.title ?? mode
                throw Refused(why: "\(asked) is looser than \(title), the loosest a thread this one opens may have.")
            }
            mode = asked
        }

        if let effort = request.effort {
            let levels = (model.flatMap { model in models(of: id).first { $0.id == model } } ?? models(of: id).first)?.efforts ?? []
            guard levels.contains(effort) else {
                throw Refused(why: levels.isEmpty
                    ? "\(model ?? agent.name) has no effort levels OriCode knows of, so leave `effort` out."
                    : "\(model ?? agent.name) has no level called \(effort). It has: \(levels.joined(separator: ", ")).")
            }
        }

        var project = own
        if let folder = request.folder {
            let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path
            guard let found = projects.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == path }) else {
                throw Refused(why: "\(folder) isn't one of the user's projects in OriCode. They are: \(projects.filter { !$0.isNoFolder }.map(\.path).joined(separator: ", ")).")
            }
            project = found
        }
        guard !request.worktree || !project.isNoFolder else { throw Refused(why: "A thread without a folder has nothing to branch.") }
        // The task is the opener's plan's, wherever the thread works on it.
        var task: (id: UUID, name: String, plan: Project)?
        if let named = request.task, let planned = planProject(of: parent) {
            let plan = ProjectPlan(planned)
            guard let found = plan.task(named: named) else { throw Refused(why: "\(planned.name)'s plan has no task \(named). read_plan gives the ones there are.") }
            if let why = whyUnclaimable(found, for: nil, in: plan) { throw Refused(why: why) }
            task = (found.id, found.name, planned)
        }
        return Opening(
            parent: parent, project: project, agent: agent, model: model, mode: mode, effort: request.effort,
            beside: project.id == own.id && !request.worktree, task: task)
    }

    /// Makes the thread and sends it its first message through the composer's own send. The
    /// thread on screen stays the one on screen.
    @discardableResult
    func open(_ opening: Opening, _ request: ThreadRequest, in worktree: (path: String, branch: String)? = nil) throws -> Chat {
        // Again, since threads may have started while git made the worktree, and its task may
        // have been taken or deleted. Nothing from here to the send waits, so two opens can't
        // both pass it.
        try checkCeiling()
        var task: PlanTask?
        if let (id, name, planned) = opening.task {
            let plan = ProjectPlan(planned)
            guard let found = plan.tasks.first(where: { $0.id == id }) else { throw Refused(why: "\(name) was deleted from \(planned.name)'s plan while the thread was being made.") }
            if let why = whyUnclaimable(found, for: nil, in: plan) { throw Refused(why: why) }
            task = found
        }
        let parent = opening.parent
        let chat = Chat(project: opening.project, permissionMode: opening.mode)
        chat.provider = opening.agent.id
        chat.model = opening.model
        chat.openedBy = parent.id
        chat.owesOpener = true
        // Beside its parent it works where the parent does. A parent's worktree stays the
        // parent's, so deleting the opened thread never takes it away, and becomes this thread's
        // when the parent is deleted first.
        if opening.beside { chat.cwd = parent.cwd }
        if let worktree {
            chat.cwd = worktree.path
            chat.worktreeBranch = worktree.branch
        }
        if chat.providerID == parent.providerID {
            chat.fastMode = parent.fastMode && chat.model == parent.model
            if let effort = parent.effort, option(for: chat)?.efforts.contains(effort) ?? (chat.model == parent.model) { chat.effort = effort }
        }
        if let effort = opening.effort { chat.effort = effort }
        // The name the agent gave it is the one it told the user, so the first message doesn't replace it.
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            chat.title = Chat.title(from: title)
            chat.titleIsCustom = true
        }
        context.insert(chat)
        // Taken before the send, so its first message is told the task.
        let held = task.map { ($0, $0.thread, $0.state) }
        if let task {
            task.thread = chat.id
            task.state = "working"
            task.updatedAt = .now
        }
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation(for: chat).threadAct(ThreadAct(act: .opened, by: false, thread: parent.id, title: parent.title, reason: reason))
        guard send(request.text, images: [], in: chat, from: parent) else {
            if let (task, thread, state) = held {
                task.thread = thread
                task.state = state
            }
            dropConversation(chat.id)
            context.delete(chat)
            save()
            throw Refused(why: "OriCode couldn't start a turn in it just now.")
        }
        save()
        return chat
    }

    /// The thread a tool names, among those the asking thread may list, and never itself.
    func other(_ named: String, from asking: UUID, doing: String) throws -> (asking: Chat, thread: Chat) {
        guard let chat = chat(withID: asking) else { throw Refused(why: "The thread that asked is gone.") }
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread = threads(around: chat).first(where: { $0.id.uuidString.caseInsensitiveCompare(named) == .orderedSame }) else {
            throw Refused(why: "No thread of this project has the id \(named). list_threads gives the ones there are.")
        }
        guard thread.id != chat.id else { throw Refused(why: "That's this thread. \(doing) is for another.") }
        return (chat, thread)
    }

    /// How loose a thread's permission mode is, as its place in `tightness`. A thread on an agent
    /// that asks before nothing is the loosest, whatever its mode says.
    func looseness(of chat: Chat) -> Int {
        let agent = agent(for: chat)
        let loosest = Self.tightness.count - 1
        guard !agent.unsupervised, !agent.modes.isEmpty else { return loosest }
        return Self.tightness.firstIndex(of: chat.permissionMode) ?? loosest
    }

    func modeWords(of chat: Chat) -> String {
        let agent = agent(for: chat)
        if agent.unsupervised || agent.modes.isEmpty { return "on \(agent.name), which asks before nothing" }
        return "on " + (PermissionModeOption(rawValue: chat.permissionMode)?.title ?? chat.permissionMode)
    }

    /// message_thread: the message goes to the thread as its composer would send it, starting a
    /// turn or into the one running, with the line saying who sent it and why in both threads.
    /// Everything that could stop it is checked before the lines are written, quietly: the user
    /// hears nothing of a call that's refused.
    func message(_ named: String, text: String, reason: String, from asking: UUID) throws -> JSON {
        let (chat, thread) = try other(named, from: asking, doing: "message_thread")
        if thread.agentID != nil { throw Refused(why: Self.agentRefusal(thread, doing: "takes no message")) }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Refused(why: "A message needs its text.") }
        // As an opened thread is never looser than its opener, a message can't have a looser
        // thread do what the sender's mode keeps it from.
        guard looseness(of: thread) <= looseness(of: chat) else {
            throw Refused(why: "\(thread.title) is \(modeWords(of: thread)), looser than this thread, which is \(modeWords(of: chat)), so it takes no message from here. Ask the user to send it.")
        }
        let agent = agent(for: thread)
        if handedOff[thread.id].flatMap({ shellBlocks[$0] })?.running == true {
            throw Refused(why: "\(thread.title) is open in \(agent.name)'s own CLI in one of the user's terminal blocks, so it can't take a message here until they quit it there.")
        }
        let conversation = conversation(for: thread)
        guard !conversation.waitingAfterQuit else { throw Refused(why: "\(thread.title) is waiting on the user to answer a question from before OriCode quit, so it can't take a message yet.") }
        let busy = conversation.running || !conversation.waiting.isEmpty
        if busy, !agent.capabilities.steer {
            throw Refused(why: "\(thread.title) is working, and \(agent.agent) takes no message until its turn ends. Wait for it with wait_thread, then send this again.")
        }
        if !busy { try checkCeiling() }
        if let why = whyTooLong(text, for: thread) { throw Refused(why: why) }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.threadAct(ThreadAct(act: .messaged, by: false, thread: chat.id, title: chat.title, reason: reason))
        if busy {
            sendIntoTurn(conversation.sentIntoTurn(text, images: []), in: thread, from: chat)
        } else if !send(text, images: [], in: thread, from: chat) {
            throw Refused(why: "OriCode couldn't start a turn in \(thread.title) just now.")
        }
        return ["thread": .string(thread.title), "id": .string(thread.id.uuidString), "sent": true, "intoTurn": .bool(busy)]
    }

    /// Why an agent's thread refuses a tool: only its workflow, its opener's Task call or its head
    /// writes there, and Claude Code stops a workflow whole.
    static func agentRefusal(_ thread: Chat, doing: String) -> String {
        switch thread.agentKind {
        case "subagent": "\(thread.title) is a subagent its opener started, and takes no message: only the subagent writes to it. Stop it with stop_thread, or read it with read_thread."
        case "worker": "\(thread.title) is a worker its opener's head sent out, and takes no message here: its head messages it with message_worker. Stop it with stop_thread, or read it with read_thread."
        default: "\(thread.title) is an agent of a workflow its opener started, and \(doing): only the workflow writes to it, and Claude Code stops a workflow whole. Stop its opener's workflow, or read it with read_thread."
        }
    }

    /// stop_thread: the thread's Stop, with the line in both threads.
    func stop(_ named: String, reason: String, from asking: UUID) throws -> JSON {
        let (chat, thread) = try other(named, from: asking, doing: "stop_thread")
        if thread.agentID != nil {
            // A subagent or a worker stops alone; a workflow's agent only with its workflow.
            guard thread.agentKind != nil else { throw Refused(why: Self.agentRefusal(thread, doing: "can't be stopped alone")) }
            guard thread.agentWorking else { throw Refused(why: "\(thread.title) isn't working, so there's nothing to stop.") }
            stopAgent(thread)
            return ["thread": .string(thread.title), "id": .string(thread.id.uuidString), "stopped": true]
        }
        // With its turn over, what it left working is what there is to stop.
        guard let conversation = conversations[thread.id], conversation.running || conversation.waitingAfterQuit || leftWorking(thread) else {
            throw Refused(why: "\(thread.title) isn't working, so there's nothing to stop.")
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.threadAct(ThreadAct(act: .stopped, by: false, thread: chat.id, title: chat.title, reason: reason))
        // A thread that stops its opener, or one above it, goes on itself.
        stop(in: thread, sparing: chat.id)
        turnEnded(thread.id)
        return ["thread": .string(thread.title), "id": .string(thread.id.uuidString), "stopped": true]
    }

    /// wait_thread: answered when the thread's turn ends, or with its state once the wait is up.
    /// A turn's end wakes it (turnEnded); nothing polls.
    func wait(on named: String, from asking: UUID, within limit: Duration = .seconds(300)) async throws -> JSON {
        let (_, thread) = try other(named, from: asking, doing: "wait_thread")
        let id = thread.id
        // An ask of a thread it set going wakes the wait, whichever thread it waits on.
        if conversations[id]?.running == true, asksHeld(by: asking).isEmpty {
            let key = UUID()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let timer = Task {
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    self.turnWaits[id]?.removeValue(forKey: key)?.done.resume()
                }
                turnWaits[id, default: [:]][key] = TurnWait(done: done, timer: timer, waiter: asking)
            }
        }
        guard let thread = chat(withID: id) else { throw Refused(why: "That thread was deleted while you waited on it.") }
        var answer: [String: JSON] = ["thread": .string(thread.title), "id": .string(id.uuidString), "state": .string(state(of: thread))]
        if let holder = chat(withID: asking) {
            let held = asksHeld(by: asking)
            if !held.isEmpty {
                answer["asks"] = .array(held.map { told($0, to: holder) })
                for waiting in held { heldAskRead(waiting.id) }
                answer["note"] = .string("A thread you set going asks you something. Answer each ask with answer_ask, then call wait_thread again.")
                return .object(answer)
            }
        }
        // What its turn edited that another working thread edited in its own: the merge will meet it.
        if let same = conversations[id]?.sameFiles, !same.isEmpty {
            answer["sameFiles"] = .array(same.map { ["path": .string($0.path), "thread": .string($0.title), "id": .string($0.thread.uuidString)] })
        }
        if let conversation = conversations[id], conversation.running {
            // An ask a third thread holds first is waiting on that thread, not the user.
            let asking = conversation.waitingAsk.map { ask in
                holder(of: ask.requestId).map { "It's waiting on \($0.title), which set it going, to answer it." } ?? "It's waiting on the user to answer it."
            }
            answer["note"] = .string((asking ?? "Still working.") + " Call wait_thread again to wait longer.")
            return .object(answer)
        }
        conversations[id]?.saveHeld()
        // A plan's owner that waited on a task's thread has heard how the task ended.
        for task in projects.flatMap(\.tasks) where task.thread == id && task.owner == asking && (task.state == "done" || task.state == "stuck") { task.heard = true }
        let container = context.container
        let reply = await Task.detached(priority: .userInitiated) { OtherThreads.lastReply(of: id, in: ModelContext(container)) }.value
        answer["reply"] = reply.map(JSON.string) ?? .null
        if let conversation = conversations[id] { answer["finished"] = .bool(conversation.endedByItself) }
        return .object(answer)
    }

    /// A thread's turn ended, or its work did: whoever waits on it hears now.
    /// Whichever way it ended, the asks still with it go up.
    func turnEnded(_ id: UUID) {
        guard conversations[id]?.running != true else { return }
        interrupting.remove(id)
        if let chat = conversations[id]?.chat { passHeld(by: chat) }
        planTurnEnded(id)
        guard let waits = turnWaits.removeValue(forKey: id) else { return }
        for wait in waits.values {
            wait.timer.cancel()
            wait.done.resume()
        }
    }

    /// The first turn of a thread another opened has ended: that thread gets its one line, from
    /// the turn.done that ended it. A first turn a limit stopped, when the thread goes on by itself
    /// at the reset, gives a line that it waits and until when, and the turn that ends after the
    /// reset the ordinary one. `stopped` is a first turn that won't come: a send the engine refused,
    /// or a wait the user called off. A parent not in memory gets it in the store alone, after its
    /// last event, and its transcript stays unread.
    func tellOpener(of chat: Chat, stopped: Bool = false) {
        guard let opener = chat.openedBy, let conversation = conversations[chat.id], let parent = self.chat(withID: opener)
        else { return }
        var waiting: (resetsAt: Date, window: String?)?
        switch chat.owesOpener {
        case nil:
            guard !stopped, conversation.turnsEnded == 1 else { return }
        case false?:
            return
        case true?:
            if !stopped, let resumeAt = chat.resumeAt, let limit = conversation.turnLimit, agent(for: chat).capabilities.resume {
                // Said for the first turn alone: a turn after the reset that a limit stops again waits quietly.
                guard conversation.turnsEnded == 1 else { return }
                waiting = (resumeAt, limit.window)
            } else {
                chat.owesOpener = false
            }
        }
        let line = OpenedLine.Told(finished: !stopped && conversation.endedByItself, waiting: waiting)
        // A thread on screen may be reading its events just now, and would miss the line.
        if conversations[opener] != nil || inView(opener) {
            self.conversation(for: parent).threadDone(chat, line)
        } else {
            Conversation.threadDone(chat, line, unread: parent, in: context)
        }
        save()
    }

    /// The engine turned down a send: the thread's work ends there, and a thread whose first send
    /// it was tells its opener now.
    func sendRefused(in chat: Chat, _ message: String) {
        conversation(for: chat).sendFailed(message)
        tellOpener(of: chat, stopped: true)
        turnEnded(chat.id)
        holdWhileWorking()
        // A queued message the engine turned down ends the thread's work, and the turn
        // before it held back its Finished for it.
        if isAway(chat) { notifier.post(title: chat.title, body: message, chatID: chat.id) }
    }

    /// A click on that line: the thread it names comes beside the one the line is in, which has
    /// the keyboard. Already beside it, nothing moves. In a window too narrow for two it's the
    /// thread shown, with the one it came from waiting beside for the window to widen.
    func openOpened(_ id: UUID, from parent: UUID? = nil) {
        guard let opened = chat(withID: id), opened.project != nil else { return say("That thread was deleted") }
        guard !opened.archived, let parent = parent.map(chat(withID:)) ?? chat, parent.id != id else { return open(chatID: id) }
        if selectedChatID != parent.id { select(parent) }
        if besideChatID != id { besideChatID = id }
        if besideShown == nil { select(opened) }
    }

    /// A click on a suggestion: a new thread in the suggesting thread's project, made as ⌘N makes
    /// one and named as the button was, with the prompt in the composer for the user to send,
    /// change or leave. It comes to the field the way a message handed back does, ahead of
    /// anything already typed there, and in place of the prompt an earlier click left there
    /// untouched: the project keeps one draft, so a second suggestion takes over the first's.
    @discardableResult
    func openSuggested(title: String, prompt: String, from chat: Chat) -> Chat? {
        guard let project = chat.project else { return nil }
        if selectedProjectID != project.id { selectedProjectID = project.id }
        guard let thread = newChat() else { return nil }
        thread.title = Chat.title(from: title)
        thread.titleIsCustom = true
        save()
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = composer(for: thread)
        conversation(for: thread).handBackQueue(with: [QueuedMessage(text: prompt, replaces: composer.suggestedPrompt)])
        composer.suggestedPrompt = prompt
        return thread
    }
}

/// A thread the agent suggested, under the reply it came with: an action button with its title.
/// Nothing has started; a click opens a new thread with the prompt waiting in the composer.
struct SuggestedThread: View {
    @Environment(AppModel.self) private var model
    let title: String
    let prompt: String
    /// The thread that suggested it, the open one when nil.
    var thread: UUID?

    var body: some View {
        Button {
            if let chat = thread.flatMap(model.chat(withID:)) ?? model.chat { model.openSuggested(title: title, prompt: prompt, from: chat) }
        } label: {
            Label(title, systemImage: "plus")
        }
        .buttonStyle(.action(small: true))
        .help(prompt)
        .accessibilityHint("Opens a new thread with this prompt in the composer")
    }
}

/// The quiet line a thread gets when one it opened ends its first turn, or when a limit stopped
/// that turn and the thread waits for it to reset. A click opens that thread.
struct OpenedLine: View {
    @Environment(AppModel.self) private var model
    let thread: UUID
    let title: String
    let finished: Bool
    /// When the limit that stopped its first turn resets, while it waits; nil for a turn that ended.
    var resetsAt: Date?
    var window: String?
    /// The thread the line is in; nil stands for the open one.
    var parent: UUID?
    @State private var hovering = false

    /// What the line says: how the first turn ended, or the limit it waits on.
    struct Told {
        let finished: Bool
        var waiting: (resetsAt: Date, window: String?)?
    }

    var body: some View {
        Button {
            model.openOpened(thread, from: parent)
        } label: {
            Text(Self.words(title: title, finished: finished, resetsAt: resetsAt, window: window))
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(resetsAt.map { _ in Limit.name(of: window).prefix(1).uppercased() + Limit.name(of: window).dropFirst() } ?? "")
    }

    /// "X replied" or "X stopped", and while a limit holds its first turn, "X waits · 14:00".
    static func words(title: String, finished: Bool, resetsAt: Date? = nil, window: String? = nil) -> String {
        if let resetsAt, resetsAt > .now { return "\(title) waits · \(Limit.time(resetsAt))" }
        return finished ? "\(title) replied" : "\(title) stopped"
    }
}

/// A wait_thread call: what wakes it, and the timer that answers it once the wait is up, called
/// off when the turn ends first so it never wakes the Mac for nothing. `waiter` is the thread
/// waiting, which an ask of a thread it set going wakes too.
struct TurnWait {
    let done: CheckedContinuation<Void, Never>
    let timer: Task<Void, Never>
    var waiter: UUID?
    /// A wait_plan, kept under the thread that waits and woken when a task it runs ends.
    var plan = false
}

/// What one thread did to another, as the line each of them stores: which act, whether this
/// thread did it or had it done to it, the other thread then, and the agent's reason.
struct ThreadAct: Equatable {
    /// `stoppedWith`: Stop on the opener reached the thread it opened. `merged`: the opener
    /// brought its work into its own folder. `allowed`, `denied`, `answered` and `passed`: the
    /// opener settled an ask of the thread's or sent it up (K-296).
    /// `stuck`: a task of the plan this thread runs got stuck in the other, and what waits on it won't start (K-297).
    /// `wentOn`: the thread a limit stopped went on by itself at the reset (REA-245).
    /// `did`: one of the menu's acts (K-303), `what` saying it.
    enum Kind: String { case opened, messaged, stopped, stoppedWith, merged, allowed, denied, answered, passed, stuck, wentOn, did }

    let act: Kind
    /// This thread did it; false when the other did it to this one.
    let by: Bool
    let thread: UUID
    let title: String
    let reason: String
    /// The ask's call, or a question's answer.
    var what = ""
    /// Who a passed ask went to; nil is the user.
    var to: String?

    init(act: Kind, by: Bool, thread: UUID, title: String, reason: String, what: String = "", to: String? = nil) {
        self.act = act
        self.by = by
        self.thread = thread
        self.title = title
        self.reason = reason
        self.what = what
        self.to = to
    }

    init?(_ body: JSON) {
        guard let act = body["act"]?.string.flatMap(Kind.init(rawValue:)), let thread = body["thread"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(act: act, by: body["by"]?.bool ?? false, thread: thread, title: body["title"]?.string ?? Chat.untitled, reason: body["reason"]?.string ?? "",
                  what: body["what"]?.string ?? "", to: body["to"]?.string)
    }

    var json: JSON {
        var json: [String: JSON] = ["event": "thread.act", "act": .string(act.rawValue), "by": .bool(by), "thread": .string(thread.uuidString), "title": .string(title), "reason": .string(reason)]
        if !what.isEmpty { json["what"] = .string(what) }
        if let to { json["to"] = .string(to) }
        return .object(json)
    }

    /// A name and a verb: "Opened X", "Opened by X". What it was about is the hover's.
    var words: String {
        switch (act, by) {
        case (.opened, true): "Opened \(title)"
        case (.messaged, true): "Messaged \(title)"
        case (.stopped, true), (.stoppedWith, true): "Stopped \(title)"
        case (.opened, false): "Opened by \(title)"
        case (.messaged, false): "From \(title)"
        case (.stopped, false): "Stopped by \(title)"
        case (.stoppedWith, false): "Stopped with \(title)"
        case (.merged, true): "Merged \(title)"
        case (.merged, false): "Merged into \(title)"
        case (.allowed, true): "Allowed \(title)"
        case (.allowed, false): "Allowed by \(title)"
        case (.denied, true): "Denied \(title)"
        case (.denied, false): "Denied by \(title)"
        case (.answered, true): "Answered \(title)"
        case (.answered, false): "Answered by \(title)"
        case (.passed, true): "Passed \(title)'s ask up"
        case (.passed, false): "Passed up by \(title)"
        case (.stuck, true): "\(what) stuck"
        case (.stuck, false): "\(title) stuck"
        case (.wentOn, true): "Went on"
        case (.wentOn, false): "\(title) went on"
        case (.did, true): what
        case (.did, false): "\(title): \(what)"
        }
    }

    /// The line's hover: the call, the answer or the task, whom a passed ask went to, and the
    /// agent's reason.
    var hover: String {
        let shown = act == .did || (act == .stuck && by)
        return [act == .passed ? "To \(to ?? "you")" : nil, shown ? nil : what.nonEmpty, reason.nonEmpty].compactMap(\.self).joined(separator: " · ")
    }
}

/// The line for what one thread did to another. A click opens the other thread beside this one.
struct ThreadActLine: View {
    @Environment(AppModel.self) private var model
    let thread: UUID
    let text: String
    var hover = ""
    /// The thread the line is in; nil stands for the open one.
    var parent: UUID?
    @State private var hovering = false

    var body: some View {
        Button {
            model.openOpened(thread, from: parent)
        } label: {
            Text(text)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(hover)
    }
}
