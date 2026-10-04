import AppKit
import SwiftUI

/// A branch's pull request and its checks, as the engine reads them through GitHub's CLI.
struct PullRequest: Decodable, Equatable {
    let number: Int
    let title: String
    let url: String
    /// OPEN, MERGED or CLOSED.
    let state: String
    let checks: [PullCheck]

    var pending: Int { checks.count { $0.state == "pending" } }
    var failed: [PullCheck] { checks.filter { $0.state == "fail" } }
    /// The checks that count: a skipped one neither passes nor fails.
    private var counted: [PullCheck] { checks.filter { $0.state != "skipped" } }

    /// Where the checks have got, in a few words.
    var words: String {
        if state == "MERGED" { return "merged" }
        if state == "CLOSED" { return "closed" }
        let total = counted.count
        guard total > 0 else { return "no checks" }
        let passed = counted.count { $0.state == "pass" }
        var parts: [String] = []
        if failed.isEmpty, pending == 0 { return total == 1 ? "its check passed" : "all \(total) checks passed" }
        if pending > 0 { parts.append("\(passed) of \(total) checks passed") }
        if !failed.isEmpty { parts.append(failed.count == 1 ? "\(failed[0].name) failed" : "\(failed.count) checks failed") }
        if pending > 0 { parts.append("\(pending) running") }
        return parts.joined(separator: ", ")
    }
}

struct PullCheck: Decodable, Equatable {
    let name: String
    /// pass, fail, pending or skipped.
    let state: String
    let link: String?
}

/// Pull requests: a thread's branch gets one from ⌘K, the line under the composer says where its
/// checks have got, a failing check's log goes to the thread in a click, and a notification says
/// when the checks finish. All of it is GitHub's own CLI, run by the engine.
extension AppModel {
    /// The open thread's folder's pull request, when its branch has one.
    var pull: PullRequest? {
        workingFolder.flatMap { pulls[$0] }
    }

    /// Looks for the folder's pull request when its branch could have one: pushed, and not the
    /// branch a repository starts on. Asked as a thread opens, after its turns and when the app
    /// comes forward, and while checks run, every half minute until they finish.
    func refreshPull(for chat: Chat?) {
        guard let chat, engineState == .ready, let info = branches[chat.id], info.upstream,
              !["main", "master", "HEAD"].contains(info.branch) else { return }
        readPull(in: chat.cwd, for: chat.id)
    }

    private func readPull(in folder: String, for chatID: UUID?) {
        Task {
            guard let reply = try? await engine.request("pr.status", ["cwd": .string(folder)]) else { return }
            took((try? reply["pr"]?.decode(PullRequest.self)) ?? nil, in: folder, for: chatID)
        }
    }

    /// A reading of a folder's pull request: kept, told when its checks have finished, and read
    /// again in a while when they haven't.
    func took(_ pull: PullRequest?, in folder: String, for chatID: UUID?) {
        let before = pulls[folder]
        if before != pull { pulls[folder] = pull }
        if let pull, let before, before.pending > 0, pull.pending == 0, let chatID, let chat = chat(withID: chatID) {
            let failed = pull.failed
            notifier.post(title: failed.isEmpty ? "Checks passed" : failed.count == 1 ? "\(failed[0].name) failed" : "\(failed.count) checks failed",
                          body: "#\(pull.number) \(pull.title)", chatID: chat.id)
        }
        pullWatches[folder]?.cancel()
        pullWatches[folder] = nil
        guard let pull, pull.state == "OPEN", pull.pending > 0 else { return }
        pullWatches[folder] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            self?.readPull(in: folder, for: chatID)
        }
    }

    /// ⌘K's Open a pull request: the branch pushed, and its pull request made from its commits.
    func openPull() async throws -> String? {
        guard let folder = workingFolder else { return nil }
        let reply = try await engine.request("pr.create", ["cwd": .string(folder)])
        let pull = (try? reply["pr"]?.decode(PullRequest.self)) ?? nil
        took(pull, in: folder, for: chat?.id)
        refreshBranch(for: chat)
        return pull.map { "Opened #\($0.number)." }
    }

    func showPull() {
        guard let pull, let url = URL(string: pull.url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The first failing check's log, sent to the thread as its next message.
    func sendFailure() {
        guard let folder = workingFolder, let pull, let check = pull.failed.first else { return }
        Task {
            do {
                let params: [String: JSON] = ["cwd": .string(folder), "link": check.link.map(JSON.string) ?? .null]
                let reply = try await engine.request("pr.log", .object(params))
                let log = reply["log"]?.string ?? ""
                _ = send("The check “\(check.name)” failed on pull request #\(pull.number). Its log ends:\n\n```\n\(log)\n```\n\nFind what failed and fix it.")
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    var pullCommands: [PaletteItem] {
        let blocked = gitUnavailable
        var items: [PaletteItem] = []
        if let pull {
            items.append(command("pr.show", "Open pull request #\(pull.number) on GitHub", icon: "arrow.triangle.pull", keywords: ["pr", "github", "checks", "ci"]) { [weak self] in
                self?.showPull()
            })
            if let check = pull.failed.first {
                items.append(command("pr.failure", "Send the failing check to the thread", icon: "exclamationmark.triangle", keywords: ["pr", "ci", "log", check.name]) { [weak self] in
                    self?.sendFailure()
                })
            }
        } else {
            items.append(PaletteItem(id: "pr.create", kind: .command, title: "Open a pull request", keywords: ["pr", "github", "push", "gh"], icon: "arrow.triangle.pull",
                                     unavailable: blocked, action: .task("Pushing and opening a pull request…") { [weak self] in try await self?.openPull() }))
        }
        return items
    }
}

/// The open thread's pull request in a line: its number, where its checks have got, and what to
/// do about it.
struct PullLine: View {
    @Environment(AppModel.self) private var model
    let pull: PullRequest

    var body: some View {
        HStack(spacing: 6) {
            Text("#\(pull.number)").foregroundStyle(Ink.primary)
            Text(pull.words)
                .foregroundStyle(pull.failed.isEmpty ? Ink.secondary : Ink.deleted)
                .lineLimit(1)
            Text("·").foregroundStyle(Ink.faint)
            if !pull.failed.isEmpty {
                Button("Send to the thread") { model.sendFailure() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                    .help("Send the failing check's log as this thread's next message")
            }
            Button("Open") { model.showPull() }
                .buttonStyle(.plain)
                .foregroundStyle(Ink.primary)
                .help(pull.url)
        }
        .frame(maxWidth: Column.width - 40)
    }
}
