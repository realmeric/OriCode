import SwiftData
import SwiftUI

/// Where a task of a project's plan stands, as agents read it and ⌘⇧I's screen says it. Waiting
/// and ready are never stored: an open task waits while a task it waits on isn't done.
enum TaskState: String {
    case waiting, ready, working, done, stuck

    var word: String { rawValue.capitalized }
}

extension PlanTask {
    /// What names it to agents and the user: T3.
    var name: String { "T\(number)" }
}

/// A project's plan as one reading of it: its tasks in order, and what each one's state is by
/// the others. Made where it's read, from the store, so nothing keeps it between calls.
struct ProjectPlan {
    let tasks: [PlanTask]
    /// The highest number a task has had here, a deleted one's included.
    let lastNumber: Int

    init(_ tasks: [PlanTask], lastNumber: Int = 0) {
        self.tasks = tasks.sorted { $0.number < $1.number }
        self.lastNumber = lastNumber
    }

    init(_ project: Project) {
        self.init(project.tasks, lastNumber: project.lastTaskNumber)
    }

    var nextNumber: Int { max(lastNumber, tasks.map(\.number).max() ?? 0) + 1 }
    var doneCount: Int { tasks.count { $0.state == "done" } }

    /// Where it stands, or would with `waits` in place of what it waits on.
    func state(of task: PlanTask, waits: [Int]? = nil) -> TaskState {
        switch task.state {
        case "working": .working
        case "done": .done
        case "stuck": .stuck
        default: waitingOn(task, waits: waits).isEmpty ? .ready : .waiting
        }
    }

    /// The tasks it waits on, or would wait on with `waits`, that aren't done. One deleted waits on nothing.
    func waitingOn(_ task: PlanTask, waits: [Int]? = nil) -> [PlanTask] {
        (waits ?? task.waitsOn).compactMap { number in tasks.first { $0.number == number } }.filter { $0.state != "done" }
    }

    /// Its tasks in order, but of those done only the latest `kept` to be done, and how many
    /// done tasks that leaves out. A plan agents have kept for weeks is mostly done tasks.
    func shown(keepingDone kept: Int) -> (tasks: [PlanTask], doneLeftOut: Int) {
        let done = tasks.filter { $0.state == "done" }.sorted { $0.updatedAt > $1.updatedAt }
        let latest = Set(done.prefix(kept).map(\.id))
        return (tasks.filter { $0.state != "done" || latest.contains($0.id) }, max(0, done.count - kept))
    }

    /// A task by its id, T3 or 3, or by its title, the latest of that title first.
    func task(named: String) -> PlanTask? {
        if let number = Self.number(in: named) { return tasks.first { $0.number == number } }
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.last { $0.title.caseInsensitiveCompare(named) == .orderedSame }
    }

    /// The number an id names, T3 or 3, or nil for what isn't an id.
    static func number(in named: String) -> Int? {
        let named = named.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(named.first.map { "Tt".contains($0) } == true ? String(named.dropFirst()) : named)
    }

    /// Whether `task` waiting on `numbers` would wait on itself, through the others or directly.
    func loops(_ task: Int, waitingOn numbers: [Int], extra: [Int: [Int]] = [:]) -> Bool {
        var seen: Set<Int> = []
        var next = numbers
        while let number = next.popLast() {
            if number == task { return true }
            guard seen.insert(number).inserted else { continue }
            next += extra[number] ?? tasks.first { $0.number == number }?.waitsOn ?? []
        }
        return false
    }
}

/// What agents ask of the plan through the oricode tools (engine/plan.ts), answered from the store
/// and written to it, and what the user does to it on ⌘⇧I's screen. The plan changes on those calls
/// and clicks alone, and the screen follows the store, so nothing polls.
extension AppModel {
    static let planAsks: Set<String> = ["plan.read", "plan.add", "plan.claim", "plan.update", "plan.wait"]
    /// What a task's note keeps: a line or two the user reads under it.
    static let longestNote = 500
    /// What a task's title and what done means for it keep. Both go ahead of each message its
    /// thread is sent, so neither can grow without end.
    static let longestTitle = 120
    static let longestDone = 500
    /// The done tasks read_plan gives of the asking thread's plan, the latest done first.
    static let doneRead = 10
    /// A stuck task's note when the user stopped its thread, which agents leave to the user.
    static let stoppedByYou = "Stopped by you."

    func answerPlan(_ event: EngineEvent, from thread: UUID) throws -> JSON {
        guard let asking = chat(withID: thread), let project = planProject(of: asking) else { throw Refused(why: "The thread that asked is gone.") }
        let body = event.body
        switch event.name {
        case "plan.read":
            return readPlan(for: asking, in: project)
        case "plan.add":
            return try addTasks(body["tasks"]?.array ?? [], in: project, for: asking, run: body["run"]?.bool == true)
        case "plan.claim":
            let task = try planTask(body["task"]?.string ?? "", in: project)
            try claim(task, for: asking, in: ProjectPlan(project))
            save()
            return taskJSON(task, in: ProjectPlan(project), for: asking)
        default:
            return try updateTask(body, in: project, for: asking)
        }
    }

    /// The plan a thread works in: the one whose task it works, or last worked, which may be
    /// another project's when it was opened elsewhere for it, or else its own project's. A thread
    /// opened in beta for alpha's T2 keeps to alpha's plan once T2 is done.
    func planProject(of chat: Chat) -> Project? {
        let worked = projects.flatMap(\.tasks).filter { $0.thread == chat.id }
        let held = worked.filter { $0.state == "working" || $0.state == "stuck" }
        return (held.isEmpty ? worked : held).max { $0.updatedAt < $1.updatedAt }?.project ?? chat.project
    }

    /// The tasks a thread works, or worked and got stuck on, the latest changed first.
    func heldTasks(of chat: Chat) -> [PlanTask] {
        projects.flatMap(\.tasks)
            .filter { $0.thread == chat.id && ($0.state == "working" || $0.state == "stuck") }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// What a turn's send says of the task the thread works, which its agent hears ahead of the message.
    func taskParams(for chat: Chat) -> JSON? {
        guard let task = heldTasks(of: chat).first else { return nil }
        var params: [String: JSON] = ["id": .string(task.name), "title": .string(task.title), "done": .string(task.doneWhen)]
        if task.owner != nil { params["run"] = true }
        return .object(params)
    }

    private func planTask(_ named: String, in project: Project) throws -> PlanTask {
        let plan = ProjectPlan(project)
        guard !named.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refused(why: "Name the task by its id, which read_plan gives.") }
        guard let task = plan.task(named: named) else {
            throw Refused(why: plan.tasks.isEmpty
                ? "\(project.name)'s plan has no tasks. Add them with add_tasks."
                : "\(project.name)'s plan has no task \(named). It has \(plan.tasks.map(\.name).joined(separator: ", ")).")
        }
        return task
    }

    /// Why a thread can't take a task, or nil when it can, judged with `waits` in place of what
    /// the task waits on when a call changes both.
    func whyUnclaimable(_ task: PlanTask, for chat: Chat?, in plan: ProjectPlan, waits: [Int]? = nil) -> String? {
        switch plan.state(of: task, waits: waits) {
        case .done:
            return "\(task.name) is done. Set it ready with update_task to work it again."
        case .waiting:
            let waiting = plan.waitingOn(task, waits: waits).map(\.name)
            return "\(task.name) waits on \(waiting.joined(separator: " and ")), \(waiting.count == 1 ? "which isn't" : "which aren't") done."
        case .working:
            guard let holder = task.thread, holder != chat?.id, let thread = self.chat(withID: holder) else { return nil }
            return "\(task.name) is being worked by \(thread.title) (id \(thread.id.uuidString))."
        case .ready, .stuck:
            return nil
        }
    }

    func claim(_ task: PlanTask, for chat: Chat, in plan: ProjectPlan) throws {
        if let why = whyUnclaimable(task, for: chat, in: plan) { throw Refused(why: why) }
        task.thread = chat.id
        task.state = "working"
        task.updatedAt = .now
    }

    /// add_tasks: every task is checked before any is made, so a refusal adds none. A task waits
    /// on one in the plan, or on one of the same call by its title or by the id it's about to have.
    /// With `run` each is checked as the thread it will open would be, and the asking thread runs
    /// them: the ready ones start now, the rest as what they wait on is done.
    private func addTasks(_ asked: [JSON], in project: Project, for asking: Chat, run: Bool = false) throws -> JSON {
        let plan = ProjectPlan(project)
        guard !asked.isEmpty else { throw Refused(why: "add_tasks needs `tasks`, each with its title and what done means.") }
        let first = plan.nextNumber
        var titles: [String: Int] = [:]
        var made: [(number: Int, title: String, done: String, names: [String])] = []
        var runs: [ThreadRequest] = []
        for (offset, task) in asked.enumerated() {
            let title = task["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let done = task["done"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else { throw Refused(why: "Each task needs a title.") }
            guard !done.isEmpty else { throw Refused(why: "Each task needs what done means for it, in `done`: \(title) has none.") }
            if let why = Self.whyTooLong(title: title, done: done) { throw Refused(why: why) }
            guard titles.updateValue(first + offset, forKey: title.lowercased()) == nil else { throw Refused(why: "Two of these tasks are called \(title). Give each its own title.") }
            made.append((first + offset, title, done, (task["waitsOn"]?.array ?? []).compactMap(\.string)))
            if run { runs.append(try runRequest(task, title: title, from: asking)) }
        }
        var waits: [Int: [Int]] = [:]
        for task in made {
            waits[task.number] = try task.names.map { name in
                if let number = titles[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] { return number }
                if let number = ProjectPlan.number(in: name), number >= first, number < first + made.count { return number }
                guard let found = plan.task(named: name) else {
                    throw Refused(why: "\(task.title) waits on \(name), which is neither in the plan nor in this call. Name a task by its id, T1, or by its title.")
                }
                return found.number
            }
        }
        for task in made where plan.loops(task.number, waitingOn: waits[task.number] ?? [], extra: waits) {
            throw Refused(why: "\(task.title) would wait on itself, through what it waits on. A plan's tasks can't wait in a circle.")
        }
        for (offset, task) in made.enumerated() {
            let added = PlanTask(number: task.number, title: task.title, doneWhen: task.done, waitsOn: Array(Set(waits[task.number] ?? [])).sorted())
            if run {
                let request = runs[offset]
                added.owner = asking.id
                added.brief = request.text
                added.agent = request.agent
                added.model = request.model
                added.effort = request.effort
                added.worktree = request.worktree
            }
            context.insert(added)
            project.tasks.append(added)
        }
        project.lastTaskNumber = first + made.count - 1
        if run { asking.planHeld = false }
        save()
        let now = ProjectPlan(project)
        var answer: [String: JSON] = ["project": .string(project.name), "added": .array(now.tasks.filter { $0.number >= first }.map { taskJSON($0, in: now, for: asking) })]
        if run {
            let starting = now.tasks.filter { $0.number >= first && now.state(of: $0) == .ready }.map(\.name)
            answer["note"] = .string("\(starting.isEmpty ? "None starts yet" : "\(starting.joined(separator: " and ")) \(starting.count == 1 ? "starts" : "start") now"), each as a thread under this one, and the rest as what they wait on is done and merged. Wait for them with wait_plan.")
            runPlans()
        }
        return .object(answer)
    }

    /// The thread a task to run will open, checked now as open_thread would check it but for the
    /// ceiling, which it meets when it starts.
    private func runRequest(_ task: JSON, title: String, from asking: Chat) throws -> ThreadRequest {
        let message = task["message"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !message.isEmpty else { throw Refused(why: "With run, each task needs the first message its thread is sent, in `message`: \(title) has none.") }
        var request = ThreadRequest(parent: asking.id, text: message)
        request.title = title
        request.agent = task["agent"]?.string?.nonEmpty
        request.model = task["model"]?.string?.nonEmpty
        request.effort = task["effort"]?.string?.nonEmpty
        request.worktree = task["worktree"]?.bool ?? false
        do {
            _ = try opening(for: request, ceiling: false)
        } catch let refused as Refused {
            throw Refused(why: "\(title): \(refused.why)")
        }
        return request
    }

    /// update_task: what it names changes, all of it or none.
    private func updateTask(_ body: JSON, in project: Project, for asking: Chat) throws -> JSON {
        let plan = ProjectPlan(project)
        let task: PlanTask
        if let named = body["task"]?.string?.nonEmpty {
            task = try planTask(named, in: project)
        } else {
            let held = heldTasks(of: asking)
            guard let only = held.first else { throw Refused(why: "This thread works no task of the plan, so name the one to change in `task`.") }
            guard held.count == 1 else { throw Refused(why: "This thread works \(held.map(\.name).joined(separator: " and ")), so name the one to change in `task`.") }
            task = only
        }
        let title = body["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let done = body["done"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = body["note"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = body["state"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let names = body["waitsOn"]?.array?.compactMap(\.string)
        guard title != nil || done != nil || note != nil || state != nil || names != nil else {
            throw Refused(why: "Say what changes: state, note, waitsOn, title or done.")
        }
        if title?.isEmpty == true { throw Refused(why: "A task's title can't be empty.") }
        if done?.isEmpty == true { throw Refused(why: "What done means can't be empty.") }
        if let why = Self.whyTooLong(title: title, done: done) { throw Refused(why: why) }
        // Its title and what done means go ahead of each message its thread is sent, so a thread
        // can't rewrite them for one looser than itself, as message_thread can't message it.
        if title != nil || done != nil, let holder = task.thread, holder != asking.id, task.state == "working" || task.state == "stuck",
           let thread = chat(withID: holder), looseness(of: thread) > looseness(of: asking) {
            throw Refused(why: "\(task.name) is worked by \(thread.title), which is \(modeWords(of: thread)), looser than this thread, which is \(modeWords(of: asking)), so this thread can't change its title or what done means. Ask the user to.")
        }
        if let note, note.count > Self.longestNote { throw Refused(why: "A note keeps \(Self.longestNote) characters at most, and this has \(note.count). Say where it stands in a line or two.") }
        if let state, !["working", "done", "stuck", "ready"].contains(state) { throw Refused(why: "A task's state is working, done, stuck or ready, not \(state).") }
        var waits: [Int]?
        if let names {
            waits = try names.map { name in
                guard let found = plan.task(named: name) else { throw Refused(why: "\(project.name)'s plan has no task \(name).") }
                guard found.number != task.number else { throw Refused(why: "\(task.name) can't wait on itself.") }
                return found.number
            }
            if plan.loops(task.number, waitingOn: waits ?? []) { throw Refused(why: "\(task.name) would wait on itself, through what it waits on. A plan's tasks can't wait in a circle.") }
        }
        if state == "working", let why = whyUnclaimable(task, for: asking, in: plan, waits: waits) { throw Refused(why: why) }
        if let title { task.title = title }
        if let done { task.doneWhen = done }
        if let note { task.note = note }
        if let waits { task.waitsOn = Array(Set(waits)).sorted() }
        switch state {
        case "working":
            task.thread = asking.id
            task.state = "working"
        case "done", "stuck":
            task.state = state!
            // A thread that ends a task nobody had taken has worked it.
            if task.thread == nil { task.thread = asking.id }
            if task.owner != nil { task.heard = false }
        case "ready":
            task.state = "open"
            task.thread = nil
            task.unmerged = false
        default:
            break
        }
        task.updatedAt = .now
        save()
        if task.owner != nil { planChanged(task) }
        return taskJSON(task, in: ProjectPlan(project), for: asking)
    }

    /// Why a title or what done means is too long to be told with every message, or nil.
    static func whyTooLong(title: String?, done: String?) -> String? {
        if let title, title.count > longestTitle { return "A task's title keeps \(longestTitle) characters at most, and \(title.prefix(40))… has \(title.count). Say what it is in a few words." }
        if let done, done.count > longestDone { return "What done means keeps \(longestDone) characters at most, and this has \(done.count). Say it in a line someone can check." }
        return nil
    }

    /// A task as read_plan and the plan's other tools give it.
    func taskJSON(_ task: PlanTask, in plan: ProjectPlan, for asking: Chat?) -> JSON {
        let state = plan.state(of: task)
        var json: [String: JSON] = [
            "id": .string(task.name), "title": .string(task.title), "done": .string(task.doneWhen), "state": .string(state.rawValue),
            "waitsOn": .array(task.waitsOn.compactMap { number in plan.tasks.first { $0.number == number } }.map { .string($0.name) }),
        ]
        if state == .waiting { json["waitingOn"] = .array(plan.waitingOn(task).map { .string($0.name) }) }
        if let owner = task.owner {
            json["runBy"] = self.chat(withID: owner).map { ["id": .string($0.id.uuidString), "title": .string($0.title)] } ?? ["id": .string(owner.uuidString), "deleted": true]
            if task.unmerged { json["unmerged"] = true }
        }
        if !task.note.isEmpty { json["note"] = .string(task.note) }
        if let id = task.thread {
            json["thread"] = self.chat(withID: id).map { ["id": .string($0.id.uuidString), "title": .string($0.title)] } ?? ["id": .string(id.uuidString), "deleted": true]
            if id == asking?.id { json["yours"] = true }
        }
        return .object(json)
    }

    /// read_plan: the asking thread's plan, but of its done tasks only the latest ten, every other
    /// project's tasks not done with a count of those done, and what ⌘⇧I's screen shows of the
    /// rest: every thread at work or waiting, in every project, and every ask waiting on the user.
    func readPlan(for asking: Chat, in project: Project) -> JSON {
        let plan = ProjectPlan(project)
        let shown = plan.shown(keepingDone: Self.doneRead)
        var answer: [String: JSON] = [
            "project": .string(project.name), "folder": .string(project.path), "plan": .array(shown.tasks.map { taskJSON($0, in: plan, for: asking) }),
        ]
        if shown.doneLeftOut > 0 {
            let one = shown.doneLeftOut == 1
            answer["more"] = .string("\(shown.doneLeftOut) task\(one ? "" : "s") done before these \(one ? "isn't" : "aren't") shown. update_task still takes \(one ? "it" : "one") by its id.")
        }
        let others = projects.filter { $0.id != project.id && !$0.tasks.isEmpty }
        if !others.isEmpty {
            answer["otherPlans"] = .array(others.map { other in
                let plan = ProjectPlan(other)
                return [
                    "project": .string(other.name), "folder": .string(other.path), "done": .number(Double(plan.doneCount)),
                    "plan": .array(plan.tasks.filter { $0.state != "done" }.map { taskJSON($0, in: plan, for: asking) }),
                ]
            })
        }
        answer["working"] = .array(overview.flatMap { section in
            section.rows.compactMap { row -> JSON? in
                let status = status(of: row.chat)
                guard status.live else { return nil }
                var thread: [String: JSON] = [
                    "project": .string(section.project.name), "id": .string(row.chat.id.uuidString), "title": .string(row.chat.title), "state": .string(status.word.lowercased()),
                ]
                if let step = status.step { thread["on"] = .string(step) }
                if let opener = row.chat.openedBy { thread["openedBy"] = .string(opener.uuidString) }
                if row.chat.id == asking.id { thread["this"] = true }
                return .object(thread)
            }
        })
        answer["asks"] = .array(waitingAsks.map { waiting in
            let ask = waiting.ask
            let what = ask.kind == "question"
                ? "A question: " + (ask.input["questions"]?.array?.first?["question"]?.string ?? "")
                : ToolSummary.line(for: ask.call, cwd: waiting.holder.cwd)
            return ["thread": .string(waiting.thread.title), "id": .string(waiting.thread.id.uuidString), "project": .string(waiting.holder.project?.name ?? ""), "asks": .string(what)]
        })
        return .object(answer)
    }

    /// The task's Stop on ⌘⇧I's screen: its thread's turn stops, and it's stuck until reopened.
    func stopTask(_ task: PlanTask) {
        if let id = task.thread, let thread = chat(withID: id), conversations[id]?.running == true || thread.agentWorking {
            stop(in: thread)
        }
        task.state = "stuck"
        task.note = Self.stoppedByYou
        task.updatedAt = .now
        if task.owner != nil { task.heard = false }
        save()
        if task.owner != nil { planChanged(task) }
    }

    /// Reopen: ready again for any thread, or waiting on what it waits on. A task its plan runs
    /// starts again in a new thread once it's ready.
    func reopenTask(_ task: PlanTask) {
        task.state = "open"
        task.thread = nil
        task.note = ""
        task.unmerged = false
        task.updatedAt = .now
        save()
        if task.owner != nil { runPlans() }
    }

    /// ⌘K's way to what a task's row on ⌘⇧I offers: Stop while it works, Reopen once it's done or
    /// stuck, and Delete, for each task of the plan in order.
    func planList(of project: Project?) -> PaletteList {
        PaletteList(title: "Stop, reopen or delete a task", placeholder: "Search the plan's tasks") { [weak self] in
            guard let self, let project else { return [] }
            let plan = ProjectPlan(project)
            return plan.tasks.flatMap { task in
                let state = plan.state(of: task)
                var acts: [(String, String, @MainActor () -> Void)] = []
                if state == .working { acts.append(("Stop", "stop.circle", { [weak self] in self?.stopTask(task) })) }
                if state == .done || state == .stuck { acts.append(("Reopen", "arrow.uturn.backward", { [weak self] in self?.reopenTask(task) })) }
                acts.append(("Delete", "trash", { [weak self] in self?.deleteTask(task) }))
                return acts.map { act, icon, run in
                    PaletteItem(id: "plan.\(act.lowercased()).\(task.id.uuidString)", kind: .choice, title: "\(act) \(task.name) · \(task.title)",
                                subtitle: state.word, icon: icon, action: .run(run))
                }
            }
        }
    }

    /// Delete: gone from the plan, and from what the others wait on.
    func deleteTask(_ task: PlanTask) {
        guard let project = task.project else { return }
        for other in project.tasks where other.waitsOn.contains(task.number) {
            other.waitsOn.removeAll { $0 == task.number }
        }
        let ran = task.owner != nil
        project.tasks.removeAll { $0.id == task.id }
        context.delete(task)
        save()
        // A task its plan runs that waited on it may start now.
        if ran || project.tasks.contains(where: { $0.owner != nil }) { movePlans() }
    }
}

/// A project's plan on ⌘⇧I's screen, above its threads: a quiet line saying how far it has got,
/// then each task with where it stands. Past six tasks done only the latest three of them are
/// drawn, since a plan kept for weeks is mostly those, and the line says how many it leaves out.
struct PlanLines: View {
    let plan: ProjectPlan
    @Binding var hovered: UUID?

    static func drawn(_ plan: ProjectPlan) -> (tasks: [PlanTask], doneLeftOut: Int) {
        plan.doneCount > 6 ? plan.shown(keepingDone: 3) : (plan.tasks, 0)
    }

    var body: some View {
        let shown = Self.drawn(plan)
        VStack(alignment: .leading, spacing: 2) {
            Text("Plan · \(plan.doneCount) of \(plan.tasks.count) done" + (shown.doneLeftOut > 0 ? " · \(shown.doneLeftOut) not shown" : ""))
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
            ForEach(shown.tasks) { task in
                PlanLine(task: task, plan: plan, hovered: $hovered)
            }
        }
    }
}

/// A task's row: its thread's mark, its title over its id and what it's on, and where it stands
/// at the end, which gives way under the pointer to what can be done to it. A click opens its thread.
private struct PlanLine: View {
    @Environment(AppModel.self) private var model
    let task: PlanTask
    let plan: ProjectPlan
    @Binding var hovered: UUID?

    var body: some View {
        let state = plan.state(of: task)
        let thread = task.thread.flatMap { id in task.project?.chats.first { $0.id == id } ?? model.chat(withID: id) }
        let under = hovered == task.id
        let lit = state == .working || state == .ready || state == .stuck
        HStack(spacing: 10) {
            mark(state, thread: thread)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Type.body)
                    .foregroundStyle(lit ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail(state, thread: thread))
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                Text(state.word)
                    .font(Type.secondary)
                    .foregroundStyle(lit ? Ink.secondary : Ink.faint)
                    .fixedSize()
                    .opacity(under ? 0 : 1)
                if under {
                    HStack(spacing: 6) { actions(state) }
                        .buttonStyle(.action(small: true))
                        .fixedSize()
                        .transition(.opacity)
                        // VoiceOver has them as the row's actions. Inside the row they'd take its
                        // press, and a press would delete the task.
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(under ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onTapGesture {
            if let thread { model.openFromOverview(thread, beside: NSEvent.modifierFlags.contains(.option)) }
        }
        .onHover { inside in
            withAnimation(Motion.fade) { hovered = inside ? task.id : (hovered == task.id ? nil : hovered) }
        }
        .contextMenu { actions(state) }
        .help("\(task.name) is done when \(task.doneWhen)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(thread == nil ? [] : .isButton)
        .accessibilityAction {
            if let thread { model.openFromOverview(thread, beside: false) }
        }
        .accessibilityActions { actions(state) }
    }

    @ViewBuilder
    private func actions(_ state: TaskState) -> some View {
        if state == .working {
            Button("Stop") { model.stopTask(task) }
        }
        if state == .done || state == .stuck {
            Button("Reopen") { model.reopenTask(task) }
        }
        Button("Delete") {
            hovered = nil
            model.deleteTask(task)
        }
    }

    /// Its id, then what it waits on, or its thread and note, or what done means while nobody works it.
    private func detail(_ state: TaskState, thread: Chat?) -> String {
        var parts = [task.name]
        switch state {
        case .waiting:
            parts.append("Waits on " + plan.waitingOn(task).map { $0.state == "stuck" ? "\($0.name) (stuck)" : $0.name }.joined(separator: ", "))
        case .ready where task.owner != nil && thread == nil:
            // Its plan starts it once what it waited on is merged too.
            let unmerged = task.waitsOn.compactMap { number in plan.tasks.first { $0.number == number && $0.unmerged }?.name }
            parts.append(unmerged.isEmpty ? task.doneWhen : "Starts once \(unmerged.joined(separator: " and ")) \(unmerged.count == 1 ? "is" : "are") merged")
        default:
            // A thread named as its task, as an opener names one, isn't said twice.
            if let thread, thread.title.caseInsensitiveCompare(task.title) != .orderedSame { parts.append(thread.title) }
            if thread == nil, task.thread != nil { parts.append("Thread deleted") }
            if !task.note.isEmpty { parts.append(task.note) } else if thread == nil { parts.append(task.doneWhen) }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func mark(_ state: TaskState, thread: Chat?) -> some View {
        if let thread, let conversation = model.conversations[thread.id], conversation.working || conversation.waitingAsk != nil {
            ThreadMark(conversation: conversation, waiting: conversation.waitingAsk != nil)
        } else {
            RaysMark(restingOpacity: 0.16, dotOpacity: state == .working || state == .stuck ? 0.92 : 0.28)
        }
    }
}
