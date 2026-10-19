import Foundation

/// How threads' work comes back together (engine/merge.ts). merge_thread brings the work of a
/// thread its caller opened with a worktree into the caller's folder: the app says which thread
/// that is and where, the engine does the git, and the app is told what came in, which it writes
/// in both transcripts and after which it removes the worktree when nothing in it was left out.
/// And when a thread's edit lands on a file another working thread of the project has edited in
/// its turn, both get a line, and so do the threads that opened them.
extension AppModel {
    /// merge_thread asks where the thread it names is, once that thread's turn is over.
    func mergeTarget(_ named: String, from asking: UUID) throws -> JSON {
        let (chat, thread) = try other(named, from: asking, doing: "merge_thread")
        if thread.agentKind == "worker" { throw Refused(why: "\(thread.title) is a worker its opener's head sent out: its head merges it with merge_worker.") }
        guard thread.openedBy == chat.id, thread.agentID == nil else {
            throw Refused(why: "\(thread.title) wasn't opened by this thread with open_thread, so it isn't this thread's to merge.")
        }
        guard let branch = thread.worktreeBranch, thread.cwd != chat.cwd else {
            throw Refused(why: thread.cwd == chat.cwd
                ? "\(thread.title) works in this thread's folder, so its edits are here already."
                : "\(thread.title) works in \(thread.cwd), not in a worktree of its own, so there's no branch to merge.")
        }
        guard conversations[thread.id]?.running != true else { throw Refused(why: "\(thread.title) is still working. Wait for it with wait_thread, or stop it, first.") }
        // A merge writes the thread's edits into this folder without asking, so it's no way around
        // this thread's own mode.
        guard looseness(of: chat) > 0 else {
            throw Refused(why: "This thread is \(modeWords(of: chat)), which edits no files, and a merge writes them into its folder. Ask the user to take it off Plan first.")
        }
        guard looseness(of: thread) <= looseness(of: chat) else {
            throw Refused(why: "\(thread.title) is \(modeWords(of: thread)), looser than this thread, which is \(modeWords(of: chat)), so its edits don't come in from here. Ask the user to merge it.")
        }
        guard FileManager.default.fileExists(atPath: thread.cwd) else { throw Refused(why: "\(thread.title)'s worktree isn't at \(thread.cwd) any more.") }
        return ["id": .string(thread.id.uuidString), "title": .string(thread.title), "folder": .string(chat.cwd), "worktree": .string(thread.cwd), "branch": .string(branch)]
    }

    /// Its work is in: a line in both threads, and its worktree and branch go when nothing in it
    /// was left out and no other thread works there. From then on it works in the folder its work
    /// went to, where its edits are, and so do its agents and the threads it merged before.
    func merged(_ body: JSON, from asking: UUID) async throws -> JSON {
        let (chat, thread) = try other(body["thread"]?.string ?? "", from: asking, doing: "merge_thread")
        var removed = false
        var kept: String?
        let ignored = body["ignored"]?.array?.compactMap(\.string) ?? []
        if body["unmerged"]?.bool == false, let branch = thread.worktreeBranch, let followers = followers(of: thread),
           conversations[thread.id]?.running != true, let root = thread.project?.path {
            endShells(of: thread)
            do {
                _ = try await engine.request("worktree.remove", ["cwd": .string(root), "path": .string(thread.cwd), "branch": .string(branch)])
                thread.worktreeBranch = nil
                for follower in followers { follower.cwd = chat.cwd }
                thread.cwd = chat.cwd
                removed = true
            } catch {
                kept = "Its worktree stays: \(error.localizedDescription)"
            }
        } else if body["unmerged"]?.bool != false {
            kept = ignored.isEmpty
                ? "Its worktree stays, since it has work the merge didn't take."
                : "Its worktree stays, since it has work the merge didn't take: \(ignored.prefix(5).joined(separator: ", "))\(ignored.count > 5 ? " and \(ignored.count - 5) more" : ""), which git ignores."
        } else if thread.worktreeBranch != nil {
            kept = "Its worktree stays, since another thread works in it."
        }
        let summary = body["summary"]?.string ?? ""
        // What waited on its task's work can start, now that it's in.
        let merged = projects.flatMap(\.tasks).filter { $0.thread == thread.id && $0.unmerged }
        for task in merged { task.unmerged = false }
        // The thread that merged it has heard how it ended.
        for task in projects.flatMap(\.tasks) where task.thread == thread.id && task.owner == chat.id && (task.state == "done" || task.state == "stuck") { task.heard = true }
        conversation(for: chat).threadAct(ThreadAct(act: .merged, by: true, thread: thread.id, title: thread.title, reason: summary))
        let told = ThreadAct(act: .merged, by: false, thread: chat.id, title: chat.title, reason: removed ? "Its worktree is removed; this thread works in its opener's folder from here" : "")
        line("thread.act", told.json, in: thread) { $0.threadAct(told) }
        save()
        refreshBranch(for: thread)
        if !merged.isEmpty { runPlans() }
        var answer: [String: JSON] = ["worktreeRemoved": .bool(removed)]
        if let kept { answer["worktreeNote"] = .string(kept) }
        return .object(answer)
    }

    /// The threads besides `thread` that work in its worktree and go where it goes: its agents,
    /// and the threads it merged, which work in its folder since, theirs too. Nil while any of them
    /// is at work, or another thread works there.
    func followers(of thread: Chat) -> [Chat]? {
        let there = projects.flatMap(\.chats).filter { $0.id != thread.id && $0.cwd == thread.cwd }
        func under(_ chat: Chat) -> Bool {
            var seen: Set<UUID> = []
            var opener = chat.openedBy
            while let id = opener, seen.insert(id).inserted {
                if id == thread.id { return true }
                opener = self.chat(withID: id)?.openedBy
            }
            return false
        }
        let follow = there.allSatisfy { chat in
            under(chat) && (chat.agentID != nil || chat.worktreeBranch == nil) && !chat.agentWorking && conversations[chat.id]?.running != true
        }
        return follow ? there : nil
    }

    /// A line for a thread whose transcript may not be in memory: through its conversation when it
    /// is, or one on screen may be reading it, else in the store alone, as tellOpener writes one.
    func line(_ kind: String, _ json: JSON, in chat: Chat, _ live: (Conversation) -> Void) {
        if conversations[chat.id] != nil || inView(chat.id) {
            live(conversation(for: chat))
        } else {
            Conversation.line(kind, json, unread: chat, in: context)
        }
    }

    /// An edit landed in `chat`: each other working thread of the project whose turn edited the
    /// same file gets a line, this one gets one naming it, and each thread that opened either hears
    /// it, once a turn for each pair and file. Nothing is read but the turns in memory.
    func sameFile(after event: EngineEvent, in chat: Chat) {
        guard let conversation = conversations[chat.id], let project = chat.project?.id,
              let path = conversation.editedFile(event.body["toolUseId"]?.string)
        else { return }
        for other in conversations.values where other !== conversation && other.running && other.chat.agentID == nil && other.chat.project?.id == project {
            guard !conversation.sameFiles.contains(where: { $0.path == path && $0.thread == other.chat.id }),
                  other.editedThisTurn.contains(path)
            else { continue }
            conversation.sameFile(SameFile(path: path, thread: other.chat.id, title: other.chat.title))
            other.sameFile(SameFile(path: path, thread: chat.id, title: chat.title))
            for opener in Set([chat.openedBy, other.chat.openedBy].compactMap(\.self)) where opener != chat.id && opener != other.chat.id {
                guard let opener = self.chat(withID: opener) else { continue }
                let same = SameFile(path: path, thread: other.chat.id, title: other.chat.title, with: (chat.id, chat.title))
                line("thread.overlap", same.json, in: opener) { $0.sameFile(same) }
            }
        }
    }
}

/// A file two working threads both edited, as the line one of them stores: the other thread, or
/// for the thread that opened them, both.
struct SameFile {
    let path: String
    let thread: UUID
    let title: String
    /// The other thread, in a line for a thread that opened them.
    var with: (id: UUID, title: String)?

    init(path: String, thread: UUID, title: String, with: (id: UUID, title: String)? = nil) {
        self.path = path
        self.thread = thread
        self.title = title
        self.with = with
    }

    init?(_ body: JSON) {
        guard let path = body["path"]?.string, let thread = body["thread"]?.string.flatMap(UUID.init(uuidString:)) else { return nil }
        self.init(path: path, thread: thread, title: body["title"]?.string ?? Chat.untitled)
        if let id = body["with"]?.string.flatMap(UUID.init(uuidString:)) { with = (id, body["withTitle"]?.string ?? Chat.untitled) }
    }

    var json: JSON {
        var json: [String: JSON] = ["event": "thread.overlap", "path": .string(path), "thread": .string(thread.uuidString), "title": .string(title)]
        if let with {
            json["with"] = .string(with.id.uuidString)
            json["withTitle"] = .string(with.title)
        }
        return .object(json)
    }

    var words: String {
        // The file first: two long titles would cut it off a 440pt column's two lines.
        if let with { return "\(path): \(with.title) and \(title) are both editing it" }
        return "\(path): \(title) is editing it too"
    }
}
