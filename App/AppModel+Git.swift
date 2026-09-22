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
                  let info = try? reply.decode(BranchInfo.self)
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
