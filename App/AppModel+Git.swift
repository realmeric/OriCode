import Foundation
import SwiftUI

struct BranchInfo: Codable, Hashable, Sendable {
    let branch: String
    let ahead: Int
    let upstream: Bool
}

extension AppModel {
    var currentBranch: BranchInfo? {
        selectedChatID.flatMap { branches[$0] }
    }

    func refreshBranch(for chat: Chat?) {
        guard let chat, engineState == .ready else { return }
        let id = chat.id, cwd = chat.cwd
        Task {
            guard let reply = try? await engine.request("git.branch", ["cwd": .string(cwd)]),
                  let info = try? reply.decode(BranchInfo.self),
                  chat.cwd == cwd
            else { return }
            if branches[id] != info { branches[id] = info }
        }
    }
}

struct ChangedFile: Codable, Hashable, Sendable, Identifiable {
    let path: String
    let status: String

    var id: String { path }
}

/// The Changes sheet's state: what git reports, what's ticked, and the message.
@MainActor
@Observable
final class ChangesState {
    var files: [ChangedFile] = []
    var picked: Set<String> = []
    var message = ""
    var busy: String?
    var problem: String?
}

extension AppModel {
    func toggleChanges() {
        if changesShown { closeChanges() } else { openChanges() }
    }

    func openChanges() {
        guard let chat else { return }
        withAnimation(Motion.move) { changesShown = true }
        loadChanges(cwd: chat.cwd)
    }

    func closeChanges() {
        withAnimation(Motion.move) { changesShown = false }
    }

    func loadChanges(cwd: String) {
        Task {
            do {
                let reply = try await engine.request("git.status", ["cwd": .string(cwd)])
                let files = try reply["files"]?.decode([ChangedFile].self) ?? []
                changes.files = files
                changes.picked = Set(files.map(\.path))
                changes.problem = nil
            } catch {
                changes.problem = error.localizedDescription
            }
        }
    }

    func writeCommitMessage() {
        guard let chat else { return }
        run("Writing…") { [self] in
            let reply = try await engine.request("git.message", ["cwd": .string(chat.cwd), "paths": .array(changes.picked.sorted().map(JSON.string))])
            changes.message = reply["message"]?.string ?? ""
        }
    }

    func commitChanges() {
        guard let chat else { return }
        run("Committing…") { [self] in
            _ = try await engine.request("git.commit", [
                "cwd": .string(chat.cwd),
                "paths": .array(changes.picked.sorted().map(JSON.string)),
                "message": .string(changes.message),
            ])
            changes.message = ""
            loadChanges(cwd: chat.cwd)
            refreshBranch(for: chat)
        }
    }

    func pushChanges() {
        guard let chat else { return }
        run("Pushing…") { [self] in
            _ = try await engine.request("git.push", ["cwd": .string(chat.cwd)])
            refreshBranch(for: chat)
        }
    }

    private func run(_ label: String, _ work: @escaping @MainActor () async throws -> Void) {
        guard changes.busy == nil else { return }
        changes.busy = label
        changes.problem = nil
        Task {
            do {
                try await work()
            } catch {
                changes.problem = error.localizedDescription
            }
            changes.busy = nil
        }
    }
}

struct WorktreeLoss: Codable, Hashable, Sendable {
    let dirty: Int
    let unpushed: Int

    var isEmpty: Bool { dirty == 0 && unpushed == 0 }

    var sentence: String {
        var parts: [String] = []
        if dirty > 0 { parts.append("\(dirty) uncommitted \(dirty == 1 ? "file" : "files")") }
        if unpushed > 0 { parts.append("\(unpushed) \(unpushed == 1 ? "commit" : "commits") no other branch has") }
        let one = dirty + unpushed == 1
        return "Its worktree has " + parts.joined(separator: " and ") + (one ? ". Removing it loses that." : ". Removing it loses them.")
    }
}

extension AppModel {
    /// ⌘⇧N: a thread on a new branch in its own worktree, so parallel threads can't see each other's edits.
    func newWorktreeChat() {
        guard let project else { return }
        let slug = "t-" + UUID().uuidString.prefix(6).lowercased()
        Task {
            do {
                let reply = try await engine.request("worktree.add", ["cwd": .string(project.path), "slug": .string(slug)])
                guard let path = reply["path"]?.string, let branch = reply["branch"]?.string else { return }
                guard let chat = newChat() else { return }
                chat.cwd = path
                chat.worktreeBranch = branch
                // It has a worktree to come back to, so it's in the list from the start.
                chat.started = true
                save()
                refreshBranch(for: chat)
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    /// Delete asks first; for a worktree thread it first finds out what removing the worktree would lose.
    func askToDelete(_ chat: Chat?) {
        guard let chat else { return }
        deletingLoss = nil
        guard let branch = chat.worktreeBranch, FileManager.default.fileExists(atPath: chat.cwd) else {
            deletingChat = chat
            return
        }
        Task {
            let reply = try? await engine.request("worktree.loss", ["path": .string(chat.cwd), "branch": .string(branch)])
            deletingLoss = (try? reply?.decode(WorktreeLoss.self)) ?? WorktreeLoss(dirty: 0, unpushed: 0)
            deletingChat = chat
        }
    }

    func delete(_ chat: Chat, removingWorktree: Bool) {
        if removingWorktree, let branch = chat.worktreeBranch, let root = chat.project?.path {
            let path = chat.cwd
            Task {
                do {
                    _ = try await engine.request("worktree.remove", ["cwd": .string(root), "path": .string(path), "branch": .string(branch)])
                } catch {
                    say(error.localizedDescription)
                }
            }
        }
        delete(chat)
    }
}
