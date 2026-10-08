import SwiftUI

/// What an agent asks the app for through OriCode's own tools (engine/threads.ts): each arrives as
/// an event with a request id and is answered with `app.reply`. A thread opened this way is a
/// thread like any other, made and sent to as the composer would. A thread it only suggests is an
/// event in its transcript, and made by the user's click. What it asks about the other threads is
/// read from the store (OtherThreads).
extension AppModel {
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
    static let asks: Set<String> = ["thread.open", "threads.list", "thread.read"]

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
            let chat = try open(opening, request, in: place)
            refreshBranch(for: chat)
            return Self.made(chat, on: opening.agent)
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
        guard parent.openedBy == nil else { throw Refused(why: "Another thread opened this one, so it can't open threads of its own.") }
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Refused(why: "A thread needs its first message.") }

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
        guard send(request.text, images: [], in: chat) else {
            conversations[chat.id] = nil
            context.delete(chat)
            save()
            throw Refused(why: "OriCode couldn't start a turn in it just now.")
        }
        save()
        return chat
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

    /// A click on that line: the thread, if it's still there.
    func openOpened(_ id: UUID) {
        guard chat(withID: id)?.project != nil else { return say("That thread was deleted") }
        open(chatID: id)
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
        conversation(for: thread).handBackQueue(with: [QueuedMessage(text: prompt, replaces: suggestedPrompt)])
        suggestedPrompt = prompt
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
    @State private var hovering = false

    var body: some View {
        Button {
            model.openOpened(thread)
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
