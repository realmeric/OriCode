import AppKit
import SwiftUI

/// A branch's pull request and its checks, as the engine reads them through GitHub's CLI.
struct PullRequest: Decodable, Equatable {
    let number: Int
    let title: String
    let url: String
    /// OPEN, MERGED or CLOSED.
    let state: String
    /// The branch it's from and the one it goes into.
    var head = ""
    var base = ""
    var draft = false
    /// MERGEABLE, CONFLICTING or UNKNOWN.
    var mergeable = "UNKNOWN"
    let checks: [PullCheck]

    private enum CodingKeys: String, CodingKey {
        case number, title, url, state, head, base, draft, mergeable, checks
    }

    init(number: Int, title: String, url: String, state: String, head: String = "", base: String = "", draft: Bool = false,
         mergeable: String = "UNKNOWN", checks: [PullCheck]) {
        self.number = number
        self.title = title
        self.url = url
        self.state = state
        self.head = head
        self.base = base
        self.draft = draft
        self.mergeable = mergeable
        self.checks = checks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        title = try values.decode(String.self, forKey: .title)
        url = try values.decode(String.self, forKey: .url)
        state = try values.decode(String.self, forKey: .state)
        head = try values.decodeIfPresent(String.self, forKey: .head) ?? ""
        base = try values.decodeIfPresent(String.self, forKey: .base) ?? ""
        draft = try values.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        mergeable = try values.decodeIfPresent(String.self, forKey: .mergeable) ?? "UNKNOWN"
        checks = try values.decode([PullCheck].self, forKey: .checks)
    }

    var pending: Int { checks.count { $0.state == "pending" } }
    var failed: [PullCheck] { checks.filter { $0.state == "fail" } }
    /// The checks that count: a skipped one neither passes nor fails.
    private var counted: [PullCheck] { checks.filter { $0.state != "skipped" } }
    var open: Bool { state == "OPEN" }
    var conflicts: Bool { mergeable == "CONFLICTING" }

    /// What stands between it and a merge, or nil when nothing does.
    var blocked: String? {
        if !open { return state == "MERGED" ? "It's merged" : "It's closed" }
        if draft { return "It's a draft" }
        if conflicts { return "It conflicts with \(base.isEmpty ? "its base" : base)" }
        if !failed.isEmpty { return failed.count == 1 ? "\(failed[0].short) failed" : "\(failed.count) checks failed" }
        if pending > 0 { return pending == 1 ? "A check is still running" : "\(pending) checks are still running" }
        return nil
    }

    /// Where it stands, in a few words: the one thing worth knowing now.
    var words: String {
        if state == "MERGED" { return base.isEmpty ? "merged" : "merged into \(base)" }
        if state == "CLOSED" { return "closed" }
        if conflicts { return "conflicts with \(base.isEmpty ? "its base" : base)" }
        if !failed.isEmpty { return failed.count == 1 ? "\(failed[0].short) failed" : "\(failed.count) checks failed" }
        if pending > 0 {
            let passed = counted.count { $0.state == "pass" }
            return passed == 0 ? (pending == 1 ? "1 check running" : "\(pending) checks running") : "\(passed) of \(counted.count) checks passed"
        }
        if draft { return "draft" }
        if counted.isEmpty { return "no checks" }
        return "ready to merge"
    }

    /// Whether those words are bad news, the only time the line takes colour.
    var troubled: Bool { open && (conflicts || !failed.isEmpty) }
}

struct PullCheck: Decodable, Equatable {
    let name: String
    /// pass, fail, pending or skipped.
    let state: String
    let link: String?
    /// How long it ran, once it has finished.
    var seconds: Int?

    /// Its own name without its workflow's: "test" of "CI / test".
    var short: String {
        name.components(separatedBy: " / ").last ?? name
    }

    var bead: WorkflowRun.Agent.State {
        switch state {
        case "pass": .done
        case "fail": .failed
        case "pending": .running
        default: .queued
        }
    }

    /// "passed in 6s", "failed after 1m 4s", "running", "skipped".
    var outcome: String {
        let time = seconds.map { $0 < 60 ? "\($0)s" : "\($0 / 60)m \($0 % 60)s" }
        switch state {
        case "pass": return time.map { "passed in \($0)" } ?? "passed"
        case "fail": return time.map { "failed after \($0)" } ?? "failed"
        case "pending": return "running"
        default: return "skipped"
        }
    }
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

    /// A turn may have pushed: an open pull request without checks is worth its looks again.
    func pushedMaybe(in folder: String) {
        pullLooks[folder] = nil
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
        guard let pull, pull.state == "OPEN" else { return }
        // A push's checks take GitHub a moment to list: an open pull request with none is looked
        // at again, three times at most, since a repository may have no checks at all.
        if pull.checks.isEmpty {
            let looks = (pullLooks[folder] ?? 0) + 1
            pullLooks[folder] = looks
            guard looks <= 3 else { return }
        } else {
            pullLooks[folder] = nil
            guard pull.pending > 0 else { return }
        }
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

    /// A failing check's log, the first's unless one is named, sent to the thread as its next
    /// message; the surface folds away so the turn it starts is in view.
    func sendFailure(_ named: PullCheck? = nil) {
        guard let folder = workingFolder, let pull, let check = named ?? pull.failed.first else { return }
        if pullShown { closePull() }
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

    /// The pull request's surface grows out of the title capsule, as the heads and the review do.
    func togglePull() {
        if pullShown {
            closePull()
        } else if pull != nil {
            withAnimation(Motion.move) { openInIsland(.pull) }
            refreshPull(for: chat)
        }
    }

    func closePull() {
        withAnimation(Motion.move) { pullShown = false }
    }

    /// Merge, after the system's own question: one commit on the base, as GitHub's Squash and
    /// merge makes it.
    func mergePull() {
        guard let folder = workingFolder, let pull, pull.blocked == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Merge #\(pull.number) into \(pull.base.isEmpty ? "its base" : pull.base)?"
        alert.informativeText = "“\(pull.title)” goes in as one commit, squashed. This is done on GitHub and can't be undone from here."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pullMerging = true
        let chatID = chat?.id
        Task {
            do {
                let reply = try await engine.request("pr.merge", ["cwd": .string(folder)])
                took((try? reply["pr"]?.decode(PullRequest.self)) ?? nil, in: folder, for: chatID)
            } catch {
                say(error.localizedDescription)
            }
            pullMerging = false
        }
    }

    var pullCommands: [PaletteItem] {
        let blocked = gitUnavailable
        var items: [PaletteItem] = []
        if let pull {
            items.append(command("pr.checks", "Show pull request #\(pull.number)", icon: "arrow.triangle.pull", keywords: ["pr", "checks", "ci", "merge"]) { [weak self] in
                self?.togglePull()
            })
            items.append(command("pr.show", "Open pull request #\(pull.number) on GitHub", icon: "safari", keywords: ["pr", "github", "browser"]) { [weak self] in
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

/// The open thread's pull request in the gap under the composer: a bead for each check, lit while
/// it runs, settled once it passed and red if it failed, then its number and the one thing worth
/// knowing now. A click grows it into its surface.
struct PullLine: View {
    @Environment(AppModel.self) private var model
    let pull: PullRequest
    @State private var hovering = false

    var body: some View {
        Button {
            model.togglePull()
        } label: {
            HStack(spacing: 8) {
                if !pull.checks.isEmpty, pull.open {
                    // Room for a running bead's halo beside its neighbour's.
                    HStack(spacing: 8) {
                        ForEach(Array(pull.checks.prefix(12).enumerated()), id: \.offset) { _, check in
                            Bead(state: check.bead)
                        }
                    }
                }
                Text("#\(pull.number)")
                    .foregroundStyle(hovering ? Ink.primary : Ink.secondary)
                Text(pull.words)
                    .foregroundStyle(pull.troubled ? Ink.deleted : hovering ? Ink.primary : Ink.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(hovering ? Surface.hover : .clear, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: pull.words)
        .help("“\(pull.title)”. Click for its checks.")
        .accessibilityLabel("Pull request \(pull.number), \(pull.words)")
    }
}

/// The pull request's surface: what it is and where it goes, each check with how it went, a
/// failing one's log a click from the thread, and Merge once nothing stands in its way.
struct PullSurface: View {
    static let width: CGFloat = 560
    @Environment(AppModel.self) private var model
    @State private var hovered: String?

    var body: some View {
        if let pull = model.pull {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("#\(pull.number)")
                            .font(Type.body.weight(.medium))
                            .foregroundStyle(Ink.secondary)
                        Text(pull.title)
                            .font(Type.body.weight(.medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(pull.words.prefix(1).uppercased() + pull.words.dropFirst())
                            .font(Type.secondary)
                            .foregroundStyle(pull.troubled ? Ink.deleted : Ink.secondary)
                            .lineLimit(1)
                    }
                    if !pull.head.isEmpty {
                        Text("\(pull.head) → \(pull.base)")
                            .font(Type.mono)
                            .foregroundStyle(Ink.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
                if pull.checks.isEmpty {
                    Text(pull.open ? "No checks have reported on it yet." : "")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 14)
                        .padding(.bottom, pull.open ? 10 : 0)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(pull.checks.enumerated()), id: \.offset) { _, check in
                                row(check)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 300)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Open on GitHub") { model.showPull() }
                        .buttonStyle(.action(small: true))
                    Spacer()
                    if model.pullMerging { ProgressView().controlSize(.small) }
                    if pull.open {
                        Button("Merge") { model.mergePull() }
                            .buttonStyle(.action(prominent: pull.blocked == nil, small: true))
                            .disabled(pull.blocked != nil || model.pullMerging)
                            .help(pull.blocked.map { "\($0)." } ?? "Squash and merge into \(pull.base)")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ check: PullCheck) -> some View {
        let under = hovered == check.name
        return HStack(spacing: 10) {
            Bead(state: check.bead)
                .frame(width: 22)
            Text(check.name)
                .font(Type.body)
                .foregroundStyle(check.state == "skipped" ? Ink.faint : Ink.primary)
                .lineLimit(1)
            Text(check.outcome)
                .font(Type.secondary)
                .foregroundStyle(check.state == "fail" ? Ink.deleted : Ink.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if under {
                if check.state == "fail" {
                    Button("Send to the thread") { model.sendFailure(check) }
                        .buttonStyle(.action(small: true))
                        .help("Its failed steps' log goes out as this thread's next message")
                }
                if let link = check.link, let url = URL(string: link) {
                    Button("Log") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.action(small: true))
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(under ? Surface.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { inside in
            withAnimation(Motion.fade) { hovered = inside ? check.name : (hovered == check.name ? nil : hovered) }
        }
    }
}
