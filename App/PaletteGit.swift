import AppKit
import SwiftUI

/// One of the folder's branches, as the engine's git.branches lists it.
struct GitBranch: Codable, Hashable, Sendable {
    let name: String
    let current: Bool
    let upstream: String?
    let track: String
    let elsewhere: String?
}

/// Branches from ⌘K: switch, create, go back, pull, push, copy the name and open the repository's
/// page. Git runs in the engine, in the open thread's folder.
extension AppModel {
    /// The folder the thread works in: its worktree, or the project.
    var workingFolder: String? {
        chat?.cwd ?? project?.path
    }

    /// Why branches can't change here now, or nil when they can.
    var gitUnavailable: String? {
        if engineState != .ready { return "The engine isn't running" }
        guard let folder = workingFolder else { return "Add a project first" }
        if chat?.worktreeBranch != nil { return "This thread's branch is its own" }
        let working = projects.flatMap(\.chats).contains { $0.cwd == folder && conversations[$0.id]?.running == true }
        return working ? "A thread is working in this folder" : nil
    }

    var gitCommands: [PaletteItem] {
        let blocked = gitUnavailable
        let branch = currentBranch?.branch
        let onBranch: String? = branch == nil ? "No branch here" : branch == "HEAD" ? "Not on a branch" : nil
        var items: [PaletteItem] = []
        items.append(PaletteItem(id: "git.switch", kind: .command, title: "Switch branch…", subtitle: branch, keywords: ["checkout", "git"],
                                 shortcut: shortcuts.label(.switchBranch), icon: "arrow.triangle.swap", unavailable: blocked, action: .list(branchList)))
        items.append(PaletteItem(id: "git.create", kind: .command, title: "Create branch…", keywords: ["new branch", "checkout -b", "git"],
                                 icon: "plus.square.on.square", unavailable: blocked, action: .input(createBranchInput)))
        items.append(PaletteItem(id: "git.previous", kind: .command, title: "Previous branch", keywords: ["switch -", "back", "git"],
                                 icon: "arrow.uturn.backward", unavailable: blocked,
                                 action: .task("Switching back…") { [weak self] in try await self?.branchCall("git.previous", [:]).map { "On \($0)." } }))
        items.append(PaletteItem(id: "git.pull", kind: .command, title: "Pull", keywords: ["fetch", "update", "git"], icon: "arrow.down.circle",
                                 unavailable: blocked ?? onBranch, action: .task("Pulling…") { [weak self] in try await self?.pullBranch() }))
        items.append(PaletteItem(id: "git.push", kind: .command, title: "Push", keywords: ["upload", "git"], icon: "arrow.up.circle",
                                 unavailable: (engineState == .ready ? nil : "The engine isn't running") ?? onBranch,
                                 action: .task("Pushing…") { [weak self] in try await self?.pushBranch() }))
        items.append(command("git.copyBranch", "Copy branch name", icon: "doc.on.clipboard", keywords: ["git"], unavailable: onBranch) { [weak self] in
            self?.copy(branch, saying: "Copied \(branch ?? "the branch name").")
        })
        items.append(PaletteItem(id: "git.web", kind: .command, title: "Open on GitHub", keywords: ["browser", "remote", "web", "repository"],
                                 icon: "safari", unavailable: engineState == .ready ? (workingFolder == nil ? "Add a project first" : nil) : "The engine isn't running",
                                 action: .task("Finding the repository's page…") { [weak self] in try await self?.openRepositoryPage() }))
        return items
    }

    /// The folder's branches, latest first, with the one checked out ticked, and a row to create
    /// one from what's typed when no branch is called that.
    var branchList: PaletteList {
        PaletteList(title: "Switch branch", placeholder: "Search branches, or type a new name") { [weak self] in
            guard let self, let folder = workingFolder else { return [] }
            let reply = try await engine.request("git.branches", ["cwd": .string(folder)])
            let listed = try reply["branches"]?.decode([GitBranch].self) ?? []
            return listed.map { branch in self.row(for: branch) }
        } typed: { [weak self] name in
            let name = Self.branchName(name)
            guard self != nil, !name.isEmpty else { return nil }
            return PaletteItem(id: "git.create.typed", kind: .command, title: "Create branch “\(name)”", icon: "plus.square.on.square",
                               unavailable: Self.nameProblem(name),
                               action: .task("Creating \(name)…") { [weak self] in
                                   try await self?.branchCall("git.create", ["name": .string(name)]).map { "On \($0)." }
                               })
        }
    }

    private func row(for branch: GitBranch) -> PaletteItem {
        let where_ = [branch.upstream, branch.track.isEmpty ? nil : branch.track].compactMap { $0 }.joined(separator: " ")
        if let elsewhere = branch.elsewhere {
            // Checked out in another worktree: its thread, when there is one, is where it lives. Git
            // gives the real path, which for a folder under /tmp starts /private.
            let real = URL(filePath: elsewhere).resolvingSymlinksInPath().path
            let thread = projects.flatMap(\.chats).first { URL(filePath: $0.cwd).resolvingSymlinksInPath().path == real }
            return PaletteItem(id: "branch." + branch.name, kind: .choice, title: branch.name, subtitle: "Open in its own thread", icon: "arrow.triangle.branch",
                               unavailable: thread == nil ? "Checked out in another worktree" : nil,
                               action: .run { [weak self] in if let thread { self?.open(chatID: thread.id) } })
        }
        return PaletteItem(id: "branch." + branch.name, kind: .choice, title: branch.name, subtitle: where_.isEmpty ? nil : where_,
                           icon: "arrow.triangle.branch", checked: branch.current,
                           unavailable: branch.current ? "You're on it" : nil,
                           action: .task("Switching to \(branch.name)…") { [weak self] in
                               try await self?.branchCall("git.switch", ["branch": .string(branch.name)]).map { "On \($0)." }
                           })
    }

    private var createBranchInput: PaletteInput {
        let from = currentBranch?.branch
        return PaletteInput(title: "Create branch", placeholder: "Branch name") { typed in
            let name = Self.branchName(typed)
            guard !name.isEmpty else { return .none }
            if let problem = Self.nameProblem(name) { return .problem(problem) }
            return .info([from.map { "From \($0)." }, "Uncommitted changes come along."].compactMap { $0 }.joined(separator: " "))
        } submit: { [weak self] typed in
            try await self?.branchCall("git.create", ["name": .string(Self.branchName(typed))]).map { "On \($0)." }
        }
    }

    /// Spaces become dashes, the way a branch name is usually written.
    static func branchName(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// A quick look at a name before git's own: what git never takes in a branch name.
    static func nameProblem(_ name: String) -> String? {
        let refused = ["..", "~", "^", ":", "?", "*", "[", "\\", "@{"]
        if name.hasPrefix("-") || name.hasSuffix(".") || name.hasSuffix("/") || name.hasSuffix(".lock") || refused.contains(where: name.contains) {
            return "Not a name git takes for a branch"
        }
        return nil
    }

    /// A git call that moves the folder's branch, which every thread in that folder then shows.
    /// Returns the branch it's on.
    private func branchCall(_ method: String, _ params: [String: JSON]) async throws -> String? {
        guard let folder = workingFolder else { return nil }
        var params = params
        params["cwd"] = .string(folder)
        let reply = try await engine.request(method, .object(params))
        adopt(reply, in: folder)
        if reviewShown { readReview() }
        return try? reply.decode(BranchInfo.self).branch
    }

    private func adopt(_ reply: JSON, in folder: String) {
        guard let info = try? reply.decode(BranchInfo.self) else { return }
        for chat in projects.flatMap(\.chats) where chat.cwd == folder {
            branches[chat.id] = info
        }
    }

    private func pullBranch() async throws -> String? {
        guard let folder = workingFolder else { return nil }
        let reply = try await engine.request("git.pull", ["cwd": .string(folder)])
        adopt(reply, in: folder)
        return reply["summary"]?.string
    }

    private func pushBranch() async throws -> String? {
        guard let folder = workingFolder else { return nil }
        _ = try await engine.request("git.push", ["cwd": .string(folder)])
        refreshBranch(for: chat)
        return "Pushed \(currentBranch?.branch ?? "the branch")."
    }

    private func openRepositoryPage() async throws -> String? {
        guard let folder = workingFolder else { return nil }
        let reply = try await engine.request("git.remote", ["cwd": .string(folder)])
        guard let web = reply["web"]?.string, var url = URL(string: web) else {
            throw EngineError.remote("This repository has no web page git knows of.")
        }
        if let branch = currentBranch?.branch, branch != "HEAD" { url.append(path: "tree/" + branch) }
        NSWorkspace.shared.open(url)
        return nil
    }
}
