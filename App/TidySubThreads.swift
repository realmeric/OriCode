import Foundation

extension AutoArchive {
    /// Whether a finished sub-thread archives itself (K-356); on unless Settings › Archive says no.
    static let tidyKey = "archiveSubThreads"
    /// How long after its last activity.
    static let tidyAfter: TimeInterval = 3600

    static var tidies: Bool { UserDefaults.standard.object(forKey: tidyKey) as? Bool ?? true }
}

extension AppModel {
    /// The sub-threads that are done with: not a main thread by the drawer's rule (`tops`), or an
    /// agent, whose last activity is before `cutoff`, and that nothing holds: its turn has ended,
    /// no ask or message waits on it or is queued in it, it isn't pinned, open or beside, holds no
    /// draft, has no unmerged worktree, and whoever opened it isn't owed or waiting on it. A thread
    /// goes only with everything under it, since archiving takes those along, and only as the
    /// topmost of the ones that qualify, so restoring it brings them back.
    func finishedSubThreads(before cutoff: Date) -> [Chat] {
        let all = projects.flatMap(\.chats).filter { $0.started && !$0.archived }
        let tops = topThreads
        let held = Set(projects.flatMap(\.tasks).filter { $0.state != "done" || $0.unmerged || !$0.heard }.compactMap(\.thread))
        func finished(_ chat: Chat) -> Bool {
            guard chat.updatedAt < cutoff, !chat.pinned, chat.worktreeBranch == nil, chat.owesOpener != true, chat.resumeAt == nil,
                  !chat.quitMidTurn, !chat.agentWorking, chat.id != selectedChatID, chat.id != besideChatID, !held.contains(chat.id),
                  turnWaits[chat.id]?.isEmpty != false, !hasDraft(chat.id), !workflowRuns(in: chat)
            else { return false }
            if let conversation = conversations[chat.id] {
                return !(conversation.running || conversation.working || conversation.waitingAsk != nil || conversation.waitingAfterQuit || conversation.holdsMessages)
            }
            return true
        }
        let sub = Set(all.filter { chat in chat.agentID != nil || tops[chat.id].map { $0 != chat.id } == true }.map(\.id))
        let ready = Set(all.filter { sub.contains($0.id) && finished($0) }.map(\.id))
        guard !ready.isEmpty else { return [] }
        let opened = Dictionary(grouping: all.filter { $0.openedBy != nil }, by: { $0.openedBy! })
        func clear(_ chat: Chat) -> Bool {
            var pending = opened[chat.id] ?? []
            var seen: Set<UUID> = [chat.id]
            while let next = pending.popLast() {
                guard seen.insert(next.id).inserted else { continue }
                guard ready.contains(next.id) else { return false }
                pending += opened[next.id] ?? []
            }
            return true
        }
        let going = Set(all.filter { ready.contains($0.id) && clear($0) }.map(\.id))
        return all.filter { chat in going.contains(chat.id) && !(chat.openedBy.map(going.contains) ?? false) }
    }

    /// Archives the finished sub-threads, as Archive Thread does, when the app starts, a turn ends,
    /// and ⌘K or the drawer opens: nothing waits for an hour to pass, so nothing is timed, and a
    /// thread that is only then an hour old goes at the next of these. At most once a minute; a
    /// row at a time after the frame that asked, so neither ⌘K nor the drawer waits on it.
    @discardableResult
    func tidySubThreads(force: Bool = false) -> Task<Void, Never>? {
        guard AutoArchive.tidies, engineState == .ready, !tidying,
              force || tidied.map({ Date.now.timeIntervalSince($0) > 60 }) ?? true
        else { return nil }
        tidied = .now
        tidying = true
        return Task {
            await Task.yield()
            defer { tidying = false }
            for chat in finishedSubThreads(before: Date.now.addingTimeInterval(-AutoArchive.tidyAfter)) {
                guard AutoArchive.tidies, !chat.archived, chat.id != selectedChatID, chat.id != besideChatID else { continue }
                archive(chat)
                await Task.yield()
            }
        }
    }
}
