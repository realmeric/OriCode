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
        throw Refused(why: "\(working) threads are working, as many as the user allows at once in Settings › Agents. Wait for one with wait_thread or stop one, then try again.")
    }

    /// Why the app didn't do what a tool asked, in words the agent reads as the tool's error.
    struct Refused: LocalizedError {
        let why: String
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
        }
    }

    /// A request worked out against the threads, projects and agents there are.
    struct Opening {
        let parent: Chat
        let project: Project
        let agent: ProviderInfo
        let model: String?
        let mode: String
        /// Whether it works where its parent does, a worktree included.
        let beside: Bool
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
    static let asks: Set<String> = ["thread.open", "thread.message", "thread.wait", "thread.stop", "threads.list", "thread.read"]

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
            let request = ThreadRequest(event.body, from: thread)
            await readModels(for: request)
            let opening = try opening(for: request)
            var place: (path: String, branch: String)?
            if request.worktree {
                let slug = "t-" + UUID().uuidString.prefix(6).lowercased()
                let prefix = UserDefaults.standard.string(forKey: NewThreads.branchPrefix) ?? NewThreads.defaultBranchPrefix
                let reply = try await engine.request("worktree.add", ["cwd": .string(opening.project.path), "slug": .string(slug), "prefix": .string(prefix)])
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
            return Self.made(chat, on: opening.agent)
        case "thread.message":
            return try message(event.body["thread"]?.string ?? "", text: event.body["text"]?.string ?? "", reason: event.body["reason"]?.string ?? "", from: thread)
        case "thread.wait":
            return try await wait(on: event.body["thread"]?.string ?? "", from: thread)
        case "thread.stop":
            return try stop(event.body["thread"]?.string ?? "", reason: event.body["reason"]?.string ?? "", from: thread)
        case "threads.list":
            return try await listThreads(for: thread, edited: event.body["edited"]?.string?.nonEmpty)
        case "thread.read":
            return try await readThread(event.body["thread"]?.string ?? "", before: event.body["before"]?.int, for: thread)
        default:
            throw Refused(why: "OriCode doesn't know what \(event.name) asks for.")
        }
    }

    /// What the tool answers: the thread as it was made, for the agent to tell the user, and the
    /// id read_thread takes to see what it did.
    static func made(_ chat: Chat, on agent: ProviderInfo) -> JSON {
        var made: [String: JSON] = [
            "thread": .string(chat.title), "id": .string(chat.id.uuidString), "agent": .string(agent.id), "mode": .string(chat.permissionMode), "folder": .string(chat.cwd),
        ]
        if let model = chat.model { made["model"] = .string(model) }
        if let branch = chat.worktreeBranch { made["branch"] = .string(branch) }
        return .object(made)
    }

    /// A named model is checked against its agent's list, which another agent's CLI gives only
    /// once a menu has asked for it: asked here when none has.
    private func readModels(for request: ThreadRequest) async {
        guard request.model != nil, let id = request.agent ?? chat(withID: request.parent)?.providerID, models(of: id).isEmpty,
              providers.first(where: { $0.id == id })?.state == .ready,
              let reply = try? await engine.request("models.list", ["provider": .string(id)]),
              let list = try? reply["models"]?.decode([ModelOption].self)
        else { return }
        modelsByAgent[id] = list
    }

    /// Checks a request before anything is made, so a refusal leaves no thread and no worktree.
    func opening(for request: ThreadRequest) throws -> Opening {
        guard let parent = chat(withID: request.parent), let own = parent.project else { throw Refused(why: "The thread that asked is gone.") }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refused(why: "A thread needs its first message.") }
        try checkCeiling()

        let id = request.agent ?? parent.providerID
        guard let agent = providers.first(where: { $0.id == id }) else {
            throw Refused(why: "No agent called \(id) is turned on in OriCode. Those that are: \(providers.map(\.id).joined(separator: ", ")).")
        }
        let same = id == parent.providerID
        guard same || agent.state == .ready else { throw Refused(why: "\(agent.name) can't run here yet\(agent.hint.map { ": \($0)" } ?? ".")") }
        if let model = request.model {
            let listed = models(of: id)
            guard !listed.isEmpty else { throw Refused(why: "\(agent.name) didn't list its models just now, so OriCode can't tell whether \(model) is one. Leave the model out, or try again.") }
            guard listed.contains(where: { $0.id == model }) else {
                throw Refused(why: "\(agent.name) has no model called \(model). It has: \(listed.map(\.id).joined(separator: ", ")).")
            }
        }
        guard let mode = Self.mode(under: parent.permissionMode, on: agent, same: same) else {
            let title = PermissionModeOption(rawValue: parent.permissionMode)?.title ?? parent.permissionMode
            throw Refused(why: agent.unsupervised || agent.modes.isEmpty
                ? "\(agent.name) asks before nothing, and this thread is on \(title)."
                : "\(agent.name) has no permission mode as tight as this thread's, \(title).")
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
        return Opening(
            parent: parent, project: project, agent: agent, model: request.model ?? (same ? parent.model : nil), mode: mode,
            beside: project.id == own.id && !request.worktree)
    }

    /// Makes the thread and sends it its first message through the composer's own send. The
    /// thread on screen stays the one on screen.
    @discardableResult
    func open(_ opening: Opening, _ request: ThreadRequest, in worktree: (path: String, branch: String)? = nil) throws -> Chat {
        // Again, since threads may have started while git made the worktree. Nothing from here to
        // the send waits, so two opens can't both pass it.
        try checkCeiling()
        let parent = opening.parent
        let chat = Chat(project: opening.project, permissionMode: opening.mode)
        chat.provider = opening.agent.id
        chat.model = opening.model
        chat.openedBy = parent.id
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
        // The name the agent gave it is the one it told the user, so the first message doesn't replace it.
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            chat.title = Chat.title(from: title)
            chat.titleIsCustom = true
        }
        context.insert(chat)
        let reason = request.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation(for: chat).threadAct(ThreadAct(act: .opened, by: false, thread: parent.id, title: parent.title, reason: reason))
        guard send(request.text, images: [], in: chat, from: parent) else {
            conversations[chat.id] = nil
            context.delete(chat)
            save()
            throw Refused(why: "OriCode couldn't start a turn in it just now.")
        }
        conversation(for: parent).threadAct(ThreadAct(act: .opened, by: true, thread: chat.id, title: chat.title, reason: reason))
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

    private func modeWords(of chat: Chat) -> String {
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
        if let longest = longestPassed(by: text, for: thread) {
            throw Refused(why: "\(agent.agent) takes messages of up to \(longest.formatted()) characters, and this one has \(text.unicodeScalars.count.formatted()).")
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.threadAct(ThreadAct(act: .messaged, by: false, thread: chat.id, title: chat.title, reason: reason))
        if busy {
            sendIntoTurn(conversation.sentIntoTurn(text, images: []), in: thread, from: chat)
        } else if !send(text, images: [], in: thread, from: chat) {
            throw Refused(why: "OriCode couldn't start a turn in \(thread.title) just now.")
        }
        self.conversation(for: chat).threadAct(ThreadAct(act: .messaged, by: true, thread: thread.id, title: thread.title, reason: reason))
        return ["thread": .string(thread.title), "id": .string(thread.id.uuidString), "sent": true, "intoTurn": .bool(busy)]
    }

    /// stop_thread: the thread's Stop, with the line in both threads.
    func stop(_ named: String, reason: String, from asking: UUID) throws -> JSON {
        let (chat, thread) = try other(named, from: asking, doing: "stop_thread")
        guard let conversation = conversations[thread.id], conversation.running || conversation.waitingAfterQuit else {
            throw Refused(why: "\(thread.title) isn't working, so there's nothing to stop.")
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        conversation.threadAct(ThreadAct(act: .stopped, by: false, thread: chat.id, title: chat.title, reason: reason))
        stop(in: thread)
        turnEnded(thread.id)
        self.conversation(for: chat).threadAct(ThreadAct(act: .stopped, by: true, thread: thread.id, title: thread.title, reason: reason))
        return ["thread": .string(thread.title), "id": .string(thread.id.uuidString), "stopped": true]
    }

    /// wait_thread: answered when the thread's turn ends, or with its state once the wait is up.
    /// A turn's end wakes it (turnEnded); nothing polls.
    func wait(on named: String, from asking: UUID, within limit: Duration = .seconds(300)) async throws -> JSON {
        let (_, thread) = try other(named, from: asking, doing: "wait_thread")
        let id = thread.id
        if conversations[id]?.running == true {
            let key = UUID()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let timer = Task {
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    self.turnWaits[id]?.removeValue(forKey: key)?.done.resume()
                }
                turnWaits[id, default: [:]][key] = TurnWait(done: done, timer: timer)
            }
        }
        guard let thread = chat(withID: id) else { throw Refused(why: "That thread was deleted while you waited on it.") }
        var answer: [String: JSON] = ["thread": .string(thread.title), "id": .string(id.uuidString), "state": .string(state(of: thread))]
        if let conversation = conversations[id], conversation.running {
            answer["note"] = .string(conversation.waitingAsk != nil
                ? "It's waiting on the user to answer it. Call wait_thread again to wait longer."
                : "Still working. Call wait_thread again to wait longer.")
            return .object(answer)
        }
        conversations[id]?.saveHeld()
        let container = context.container
        let reply = await Task.detached(priority: .userInitiated) { OtherThreads.lastReply(of: id, in: ModelContext(container)) }.value
        answer["reply"] = reply.map(JSON.string) ?? .null
        if let conversation = conversations[id] { answer["finished"] = .bool(conversation.endedByItself) }
        return .object(answer)
    }

    /// A thread's turn ended, or its work did: whoever waits on it hears now.
    func turnEnded(_ id: UUID) {
        guard conversations[id]?.running != true, let waits = turnWaits.removeValue(forKey: id) else { return }
        for wait in waits.values {
            wait.timer.cancel()
            wait.done.resume()
        }
    }

    /// The first turn of a thread another opened has ended: that thread gets its one line, from
    /// the turn.done that ended it. A parent not in memory gets it in the store alone, after its
    /// last event, and its transcript stays unread.
    func tellOpener(of chat: Chat) {
        guard let opener = chat.openedBy, let conversation = conversations[chat.id], conversation.turnsEnded == 1,
              let parent = self.chat(withID: opener)
        else { return }
        // A thread on screen may be reading its events just now, and would miss the line.
        if conversations[opener] != nil || inView(opener) {
            self.conversation(for: parent).threadDone(chat, finished: conversation.endedByItself)
        } else {
            Conversation.threadDone(chat, finished: conversation.endedByItself, unread: parent, in: context)
            save()
        }
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

/// The quiet line a thread gets when one it opened ends its first turn. A click opens that thread.
struct OpenedLine: View {
    @Environment(AppModel.self) private var model
    let thread: UUID
    let title: String
    let finished: Bool
    /// The thread the line is in; nil stands for the open one.
    var parent: UUID?
    @State private var hovering = false

    var body: some View {
        Button {
            model.openOpened(thread, from: parent)
        } label: {
            Text(Self.words(title: title, finished: finished))
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("Open the thread")
    }

    static func words(title: String, finished: Bool) -> String {
        finished ? "\(title) finished its first turn" : "\(title) stopped before its first turn finished"
    }
}

/// A wait_thread call: what wakes it, and the timer that answers it once the wait is up, called
/// off when the turn ends first so it never wakes the Mac for nothing.
struct TurnWait {
    let done: CheckedContinuation<Void, Never>
    let timer: Task<Void, Never>
}

/// What one thread did to another, as the line each of them stores: which act, whether this
/// thread did it or had it done to it, the other thread then, and the agent's reason.
struct ThreadAct: Equatable {
    enum Kind: String { case opened, messaged, stopped }

    let act: Kind
    /// This thread did it; false when the other did it to this one.
    let by: Bool
    let thread: UUID
    let title: String
    let reason: String

    init(act: Kind, by: Bool, thread: UUID, title: String, reason: String) {
        self.act = act
        self.by = by
        self.thread = thread
        self.title = title
        self.reason = reason
    }

    init?(_ body: JSON) {
        guard let act = body["act"]?.string.flatMap(Kind.init(rawValue:)), let thread = body["thread"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(act: act, by: body["by"]?.bool ?? false, thread: thread, title: body["title"]?.string ?? Chat.untitled, reason: body["reason"]?.string ?? "")
    }

    var json: JSON {
        ["event": "thread.act", "act": .string(act.rawValue), "by": .bool(by), "thread": .string(thread.uuidString), "title": .string(title), "reason": .string(reason)]
    }

    var words: String {
        let done = switch (act, by) {
        case (.opened, true): "Opened \(title)"
        case (.messaged, true): "Sent \(title) a message"
        case (.stopped, true): "Stopped \(title)"
        case (.opened, false): "\(title) opened this thread"
        case (.messaged, false): "Message from \(title)"
        case (.stopped, false): "\(title) stopped this thread"
        }
        return reason.isEmpty ? done : "\(done) · \(reason)"
    }
}

/// The line for what one thread did to another. A click opens the other thread beside this one.
struct ThreadActLine: View {
    @Environment(AppModel.self) private var model
    let thread: UUID
    let text: String
    /// The thread the line is in; nil stands for the open one.
    var parent: UUID?
    @State private var hovering = false

    var body: some View {
        Button {
            model.openOpened(thread, from: parent)
        } label: {
            Text(text)
                .underline(hovering)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help("Open the thread")
    }
}
