import Foundation

/// A thread answers for the threads it sets going (K-296). An ask from a thread whose turn another
/// thread started, with open_thread or message_thread, goes to that thread first while its own turn
/// runs: its wait_thread answers at once with the ask, and it settles it with answer_ask within its
/// own permission mode, or sends it up with a reason, to the thread that set it going in turn and
/// from the top to the user. The asking thread's card says who has it, and the user can answer it
/// there all the same. An ask still with a thread when that thread's turn ends goes up by itself,
/// and so does one it hasn't read in a wait_thread within `holdLimits.unread`, or answered within
/// `holdLimits.unanswered` of reading it. Settings › Agents can send every ask straight to the user.
extension AppModel {
    nonisolated static let openersAnswerKey = "openersAnswer"

    static var openersAnswer: Bool {
        UserDefaults.standard.object(forKey: openersAnswerKey) as? Bool ?? true
    }

    /// The thread that answers an ask of `chat`'s before the user: the one that set its turn going,
    /// while that one's own turn runs and its own loop isn't waiting on an ask, which would keep it
    /// from calling wait_thread. Nil is the user.
    func answerer(above chat: Chat) -> Chat? {
        guard Self.openersAnswer, chat.agentID == nil, let opener = chat.openedBy, chat.turnFrom == opener,
              let conversation = conversations[opener], conversation.running, !conversation.waitingAfterQuit,
              conversation.chat.agentID == nil, !conversation.waitingAsks.contains(where: { asker(of: $0) == nil })
        else { return nil }
        return conversation.chat
    }

    /// A thread can answer it: a permission or a question the asking thread's own loop asked.
    /// Seeing and using the Mac, a finished plan and what a worker, subagent or workflow agent
    /// asks stay the user's.
    static func answerable(_ ask: PendingAsk) -> Bool {
        ask.agentID == nil && ask.worker == nil && ask.app == nil && ask.loosening == nil && ask.toolKind != .planning
    }

    /// The thread an ask is with now, while its conversation is still here: one deleted or let go
    /// meanwhile leaves the ask the user's.
    func holder(of requestId: String) -> Chat? {
        askHolders[requestId].flatMap { conversations[$0]?.chat }
    }

    /// The line over an ask still waiting, in its thread's card and in the queue: who has it first,
    /// or who sent it up and why. A pass names the thread it went to only while that thread still
    /// has it; since then it may have come to the user without one, a holder having gone.
    func heldLine(of ask: PendingAsk, in thread: Chat?) -> String? {
        let pass = ask.passes.last
        let reason = pass.flatMap { $0.reason.nonEmpty.map { " · \($0)" } } ?? ""
        if let holder = holder(of: ask.requestId) {
            if let pass, pass.to == holder.title { return "\(pass.by) passed this to \(holder.title)" + reason }
            return holder.id == thread?.openedBy ? "With \(holder.title) first, which set this thread going" : "With \(holder.title) first"
        }
        guard let pass else { return nil }
        return (pass.to == nil ? "\(pass.by) passed this to you" : "\(pass.by) passed this up") + reason
    }

    /// An ask just came: it goes to the thread above when there is one, and wakes its wait.
    func routeAsk(_ requestId: String, in chat: Chat) {
        guard let ask = conversations[chat.id]?.waitingAsks.first(where: { $0.requestId == requestId }), Self.answerable(ask),
              let opener = answerer(above: chat)
        else { return }
        hold(requestId, with: opener.id)
        wakeWaits(of: opener.id)
    }

    /// The ask is with `holder` now, until it answers, sends it up or lets the deadline pass.
    func hold(_ requestId: String, with holder: UUID) {
        askHolders[requestId] = holder
        holdDeadlines.removeValue(forKey: requestId)?.timer.cancel()
        holdDeadlines[requestId] = (read: false, timer: deadline(requestId, holder, after: holdLimits.unread))
    }

    /// Its holder read it in a wait_thread: the clock starts again, for the answer this time.
    func heldAskRead(_ requestId: String) {
        guard let holder = askHolders[requestId], holdDeadlines[requestId]?.read == false else { return }
        holdDeadlines[requestId]?.timer.cancel()
        holdDeadlines[requestId] = (read: true, timer: deadline(requestId, holder, after: holdLimits.unanswered))
    }

    /// The ask is nobody's but the user's now, or settled.
    func release(_ requestId: String) {
        askHolders[requestId] = nil
        holdDeadlines.removeValue(forKey: requestId)?.timer.cancel()
    }

    private func deadline(_ requestId: String, _ holder: UUID, after limit: Duration) -> Task<Void, Never> {
        Task {
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            self.overdue(requestId, holder)
        }
    }

    /// The deadline passed with the ask still with the same thread: it goes up as a pass would.
    func overdue(_ requestId: String, _ holderID: UUID) {
        guard askHolders[requestId] == holderID, let read = holdDeadlines[requestId]?.read, let holder = chat(withID: holderID),
              let waiting = asksHeld(by: holderID).first(where: { $0.id == requestId })
        else { return }
        let reason = read
            ? "Not answered within \(Self.words(for: holdLimits.unanswered)) of being read"
            : "Not taken up within \(Self.words(for: holdLimits.unread))"
        pass(waiting.ask, of: waiting.holder, from: holder, reason: reason)
    }

    static func words(for limit: Duration) -> String {
        let seconds = Int(limit.components.seconds)
        if seconds >= 60, seconds % 60 == 0 { return seconds == 60 ? "a minute" : "\(seconds / 60) minutes" }
        return seconds == 1 ? "a second" : "\(seconds) seconds"
    }

    /// The asks with a thread now, oldest first, each in the conversation of the thread that asks.
    func asksHeld(by id: UUID) -> [WaitingAsk] {
        guard askHolders.values.contains(id) else { return [] }
        return conversations.values
            .flatMap { conversation in
                conversation.waitingAsks.filter { askHolders[$0.requestId] == id }.map { WaitingAsk(ask: $0, holder: conversation.chat, thread: conversation.chat) }
            }
            .sorted { ($0.ask.askedAt, $0.ask.requestId) < ($1.ask.askedAt, $1.ask.requestId) }
    }

    /// Every wait_thread the thread has running answers now, so it reads the ask.
    func wakeWaits(of waiter: UUID) {
        for (id, waits) in turnWaits {
            for (key, wait) in waits where wait.waiter == waiter {
                wait.timer.cancel()
                wait.done.resume()
                turnWaits[id]?[key] = nil
            }
            if turnWaits[id]?.isEmpty == true { turnWaits[id] = nil }
        }
    }

    /// The ask as wait_thread gives it: who asks, what, and whether this thread's mode lets it allow it.
    func told(_ waiting: WaitingAsk, to holder: Chat) -> JSON {
        let ask = waiting.ask
        let asker = waiting.holder
        var told: [String: JSON] = ["ask": .string(ask.requestId), "thread": .string(asker.title), "id": .string(asker.id.uuidString)]
        if ask.kind == "question" {
            told["kind"] = "question"
            told["questions"] = ask.options ?? ask.input["questions"] ?? .null
        } else {
            told["kind"] = "permission"
            told["asks"] = .string(ToolSummary.line(for: ask.call, cwd: asker.cwd))
            told["input"] = Self.cut(ask.input)
            if let why = whyCantAllow(ask, by: holder, for: asker) {
                told["youMayAllow"] = false
                told["why"] = .string(why)
            } else {
                told["youMayAllow"] = true
            }
        }
        if !ask.passes.isEmpty {
            told["passedUp"] = .array(ask.passes.map { ["by": .string($0.by), "reason": .string($0.reason)] })
        }
        return .object(told)
    }

    /// An input as the agent reads it: a file's whole new text is more than an answer needs.
    static func cut(_ input: JSON, at most: Int = 2000) -> JSON {
        switch input {
        case .string(let text) where text.count > most: .string(String(text.prefix(most)) + "…")
        case .object(let fields): .object(fields.mapValues { cut($0, at: most) })
        case .array(let items): .array(items.map { cut($0, at: most) })
        default: input
        }
    }

    /// Why a thread can't allow the call, or nil when its own mode would have run it without
    /// asking the user: on Don't ask, or on an agent that asks before nothing, anything; on Accept
    /// edits or Auto, an edit to files in its folder, or in the asking thread's when that is a
    /// worktree or folder of the same project, since neither mode asks about one and OriCode can't
    /// judge a command for Auto as its model would; on Ask or Plan, nothing. Every file the edit
    /// changes is checked where its links lead, and an edit that can't name them all, or that
    /// deletes or moves one, stays the user's.
    func whyCantAllow(_ ask: PendingAsk, by holder: Chat, for asker: Chat) -> String? {
        let looseness = looseness(of: holder)
        if looseness >= Self.tightness.count - 1 { return nil }
        let edits = Self.tightness.firstIndex(of: "acceptEdits") ?? 2
        let what = ToolSummary.line(for: ask.call, cwd: asker.cwd)
        let mode = modeWords(of: holder)
        guard looseness >= edits else { return "This thread is \(mode), which lets nothing run without the user, so it can't allow \(what)." }
        guard [.edit, .write, .notebook].contains(ask.toolKind) else {
            return "This thread is \(mode), which allows edits to files and nothing else without the user, so it can't allow \(what)."
        }
        guard let files = Self.files(of: ask, on: asker) else {
            return "This thread is \(mode), which allows edits to files in its folder, and \(what) may delete, move or change a file the ask doesn't name, so it can't allow it."
        }
        let theirs = sameProject(asker, as: holder)
        let folders = ([holder.cwd] + (theirs ? [asker.cwd] : [])).compactMap(Self.real)
        let base = URL(fileURLWithPath: asker.cwd, isDirectory: true)
        let outside = files.first { file in
            let path = URL(fileURLWithPath: file, relativeTo: base).standardizedFileURL.path
            guard let real = Self.real(path) else { return true }
            return !folders.contains { Self.inside(real, $0) }
        }
        guard let outside else { return nil }
        if theirs { return "This thread is \(mode), which allows edits to files in its own folder or the asking thread's, and \(outside) is outside both." }
        return "This thread is \(mode), which allows edits to files in its own folder, and \(outside) is outside it, in \(asker.project?.name ?? "another project")'s folder."
    }

    /// Every file an edit ask changes, nil when the ask can't name them all or one is deleted or
    /// moved: a Codex patch lists each change in its view's `paths`, and Claude Code's Edit, Write
    /// and NotebookEdit change the one file they name. Another agent's edit may say only its first.
    static func files(of ask: PendingAsk, on asker: Chat) -> [String]? {
        if let changes = ask.call.view["paths"]?.array {
            let files = changes.compactMap { change in
                ["edit", "write"].contains(change["kind"]?.string) ? change["path"]?.string?.nonEmpty : nil
            }
            return !files.isEmpty && files.count == changes.count ? files : nil
        }
        guard asker.providerID == ProviderInfo.claudeID, let file = ask.input["file_path"]?.string ?? ask.input["notebook_path"]?.string else { return nil }
        return [file]
    }

    /// The asking thread works in the same project as the thread answering for it, in a worktree
    /// of its own or in the project's folder, so its folder is the answering thread's work too.
    func sameProject(_ asker: Chat, as holder: Chat) -> Bool {
        guard let project = holder.project, !project.isNoFolder, asker.project?.id == project.id else { return false }
        return asker.worktreeBranch != nil || (Self.real(asker.cwd).flatMap { cwd in Self.real(project.path).map { Self.inside(cwd, $0) } } ?? false)
    }

    /// Compares paths as given, so both go through `real` first: standardizing would take
    /// /private off one that exists and leave it on one that doesn't.
    static func inside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The path with every link in it followed, for a file that may not exist yet: the part that
    /// exists is resolved and the rest put back on. Nil for a link that leads nowhere.
    static func real(_ path: String) -> String? {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        // attributesOfItem doesn't follow a link, so a link to nowhere is found here, not skipped.
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return nil }
        defer { free(resolved) }
        return rest.reduce(URL(fileURLWithPath: String(cString: resolved))) { $0.appending(path: $1) }.path
    }

    /// answer_ask: the thread settles an ask that's with it, as the user's card would, or sends it up.
    func answerAsk(_ body: JSON, from asking: UUID) throws -> JSON {
        let requestId = body["ask"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let holder = chat(withID: asking) else { throw Refused(why: "The thread that asked is gone.") }
        guard let waiting = asksHeld(by: asking).first(where: { $0.id == requestId }) else {
            throw Refused(why: "No ask \(requestId) is waiting on this thread: it was answered, or went up. wait_thread gives the asks of the threads you set going.")
        }
        let ask = waiting.ask
        let asker = waiting.holder
        let reason = body["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let what = ask.kind == "question" ? "a question" : ToolSummary.line(for: ask.call, cwd: asker.cwd)
        let by = (title: holder.title, reason: reason)
        let decision = body["answer"]?.string ?? ""
        switch decision {
        case "allow":
            guard ask.kind != "question" else { throw Refused(why: "That ask is a question: answer it with \"answer\" and `answers`.") }
            if let why = whyCantAllow(ask, by: holder, for: asker) { throw Refused(why: "\(why) Pass it up with \"pass\" and your reason, or deny it.") }
            let choice = ask.choices.first { $0.kind == "allow_once" } ?? ask.choices.first(where: \.allows)
            guard ask.choices.isEmpty || choice != nil else { throw Refused(why: "\(asker.title)'s agent offers no way to allow it. Pass it up or deny it.") }
            answer(ask, in: asker.id, allow: true, choice: choice, by: by)
            conversation(for: holder).threadAct(ThreadAct(act: .allowed, by: true, thread: asker.id, title: asker.title, reason: reason, what: what))
        case "deny":
            let choice = ask.choices.first { $0.kind == "reject_once" } ?? ask.choices.first { !$0.allows }
            answer(ask, in: asker.id, allow: false, message: "\(holder.title), the thread that set this one going, denied it: \(reason)", choice: choice, by: by)
            conversation(for: holder).threadAct(ThreadAct(act: .denied, by: true, thread: asker.id, title: asker.title, reason: reason, what: what))
        case "answer":
            guard ask.kind == "question" else { throw Refused(why: "That ask is a permission: allow, deny or pass it.") }
            let answers = try Self.answers(body["answers"], to: ask)
            answer(ask, in: asker.id, allow: true, answers: answers, by: by)
            conversation(for: holder).threadAct(ThreadAct(act: .answered, by: true, thread: asker.id, title: asker.title, reason: reason, what: answers.values.sorted().joined(separator: ", ")))
        case "pass":
            let to = pass(ask, of: asker, from: holder, reason: reason)
            return ["ask": .string(requestId), "thread": .string(asker.title), "passedTo": .string(to?.title ?? "the user")]
        default:
            throw Refused(why: "Say allow, deny, answer or pass in `answer`.")
        }
        return ["ask": .string(requestId), "thread": .string(asker.title), "answered": .string(decision)]
    }

    /// A question's answers by its questions' own words. With one question, an answer under any
    /// key is its answer.
    static func answers(_ given: JSON?, to ask: PendingAsk) throws -> [String: String] {
        let questions = (ask.options?.array ?? ask.input["questions"]?.array ?? []).compactMap { $0["question"]?.string }
        guard case .object(let fields) = given ?? .null, !fields.isEmpty else {
            throw Refused(why: "Give `answers`, each question's text to its answer.")
        }
        let given = fields.compactMapValues { $0.string?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
        if questions.count == 1, given.count == 1, let only = given.values.first { return [questions[0]: only] }
        var answers: [String: String] = [:]
        for question in questions {
            guard let answer = given[question] else { throw Refused(why: "No answer for \"\(question)\". Give each question's text as it was asked, to its answer.") }
            answers[question] = answer
        }
        return answers
    }

    /// Sends an ask up from the thread that has it, to the thread above or to the user, with a
    /// line in both. Returns the thread it went to, nil for the user.
    @discardableResult
    func pass(_ ask: PendingAsk, of asker: Chat, from holder: Chat, reason: String) -> Chat? {
        let next = answerer(above: holder)
        let what = ask.kind == "question" ? "a question" : ToolSummary.line(for: ask.call, cwd: asker.cwd)
        conversation(for: asker).askPassed(ask.requestId, PendingAsk.Pass(by: holder.title, to: next?.title, reason: reason))
        conversation(for: holder).threadAct(ThreadAct(act: .passed, by: true, thread: asker.id, title: asker.title, reason: reason, what: what, to: next?.title))
        if let next {
            hold(ask.requestId, with: next.id)
            wakeWaits(of: next.id)
        } else {
            release(ask.requestId)
            notifier.badge(waitingCount)
            if isAway(asker), let passed = conversations[asker.id]?.waitingAsks.first(where: { $0.requestId == ask.requestId }) { postAsk(passed, in: asker) }
        }
        return next
    }

    /// Settings › Agents turned it off: what threads had is the user's now.
    func handAsksToUser() {
        guard !askHolders.isEmpty else { return }
        releaseAll()
        notifier.badge(waitingCount)
    }

    func releaseAll() {
        for (_, deadline) in holdDeadlines { deadline.timer.cancel() }
        holdDeadlines = [:]
        askHolders = [:]
    }

    /// A thread's turn ended with asks still with it: each goes up as if it had passed it, but one
    /// from a thread Stop is interrupting stays until its cancel comes, the deadline behind it.
    func passHeld(by chat: Chat) {
        for waiting in asksHeld(by: chat.id) where !interrupting.contains(waiting.holder.id) {
            pass(waiting.ask, of: waiting.holder, from: chat, reason: "Its turn ended before it answered")
        }
    }
}
