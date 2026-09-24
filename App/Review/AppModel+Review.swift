import AppKit
import SwiftUI

/// A note on some lines, for Claude: collected while you review and sent as one message.
struct ReviewNote: Identifiable, Hashable {
    let id = UUID()
    let unit: String
    let path: String
    /// The lines it's about, signed as the diff shows them, and where they are.
    let quote: [String]
    let place: String
    var text: String
}

/// A path's entry in git's index, as it was before a take-back put HEAD's in its place.
struct IndexEntry: Codable, Hashable, Sendable {
    let path: String
    let mode: String
    let sha: String
}

/// Something the review took back. What it did is written down as it goes, and undoing it
/// undoes exactly that, so a step that stopped halfway can still be put back.
@MainActor
final class Takeback {
    let label: String
    let folder: String
    let root: String
    /// Hunks to take out of the working tree.
    let patch: String?
    /// Files taken back whole: to the Trash, with HEAD's version and index entry put back.
    let whole: [FileDiff]
    let marked: [ReviewUnit]
    /// The hunks it took, to select again when they're put back.
    let unitIDs: [String]
    /// Whether it's in effect now.
    var applied = false
    /// The hunks came out of the working tree, and out of the index where they were staged.
    var patched = false
    var indexPatched = false
    /// Files sent to the Trash, by the path they came from.
    var trashed: [(path: String, trash: URL)] = []
    /// Paths given HEAD's version, and their index entries from before.
    var restored: [String] = []
    var index: [IndexEntry] = []

    init(label: String, folder: String, root: String, patch: String?, whole: [FileDiff], marked: [ReviewUnit], unitIDs: [String]) {
        self.label = label
        self.folder = folder
        self.root = root
        self.patch = patch
        self.whole = whole
        self.marked = marked
        self.unitIDs = unitIDs
    }
}

/// The review's state: what the working tree changes, told as the thread's story.
@MainActor
@Observable
final class ReviewState {
    /// The folder the diff was read in.
    var folder: String?
    var diff: WorkingDiff?
    /// The book before marks: chapters, lines, words and signals, worked out once per read.
    var base = ReviewBook()
    /// The book with your marks laid over it, which the review shows.
    var book = ReviewBook()
    var loading = false
    var problem: String?
    /// The hunk the keyboard is on.
    var selected: String?
    /// Reviewed hunks and chapters opened again.
    var unfolded: Set<String> = []
    /// Hunks too long to draw whole until asked.
    var expanded: Set<String> = []
    /// Files whose hunks show; a closed one is its header alone.
    var openFiles: Set<String> = []
    /// Whether the review has been seen in this folder, with its first file opened.
    var placed = false
    var notes: [ReviewNote] = []
    /// The unit a note is being written on.
    var noting: String?
    var message = ""
    /// What the review is doing to the files, one thing at a time.
    var busy: String?
    /// Haiku writing a commit message, which touches no file and waits for nothing.
    var writing = false
    /// What the last take-back did, for as long as it can be undone from here.
    var lastTakeback: Takeback?
    /// Syntax colours per hunk, by what its lines say, once they're ready.
    var colours: [String: [AttributedString]] = [:]
    /// Bumped when a click on a hunk should give the review the keyboard back from a field.
    var focusTick = 0
    /// Hunks to select once the next read has them: the ones a put-back brings back.
    @ObservationIgnored var reselect: [String] = []
    @ObservationIgnored let marks = ReviewMarks()
    @ObservationIgnored var trigger: Task<Void, Never>?
    @ObservationIgnored var reading = false
    @ObservationIgnored var wanted = false
    @ObservationIgnored var queue: Task<Void, Never>?
    @ObservationIgnored var colouring: Task<Void, Never>?

    var root: String? { diff?.root }

    var counts: (added: Int, deleted: Int)? {
        guard let diff, !diff.files.isEmpty else { return nil }
        return (diff.files.reduce(0) { $0 + $1.added }, diff.files.reduce(0) { $0 + $1.deleted })
    }

    /// A chapter whose hunks are all reviewed folds under its message until it's opened.
    func folded(_ chapter: ReviewChapter) -> Bool {
        chapter.units.allSatisfy(\.reviewed) && !unfolded.contains(chapter.id)
    }

    /// A reviewed hunk, or a lockfile's, is one line until it's opened.
    func folded(_ unit: ReviewUnit) -> Bool {
        (unit.reviewed || unit.lockfile) && !unfolded.contains(unit.id)
    }

    /// The hunks the keyboard can reach: none of a folded chapter's.
    var visibleUnits: [ReviewUnit] {
        book.chapters.filter { !folded($0) }.flatMap(\.units)
    }

    /// The hunk the keyboard is on, while its file is open.
    var selectedUnit: ReviewUnit? {
        guard let selected else { return nil }
        return book.units.first { $0.id == selected && openFiles.contains($0.section) }
    }

    /// The first look at a folder's changes opens one file, the first with something to review,
    /// and leaves the rest closed.
    func placeFiles() {
        guard !placed else { return }
        let units = visibleUnits
        guard let top = units.first(where: { !$0.reviewed }) ?? units.first else { return }
        openFiles = [top.section]
        placed = true
    }

    /// Puts the keyboard on a hunk and opens its file. Moving on from a hunk in another file
    /// closes that one, so the keyboard reads one file at a time.
    func select(_ unit: ReviewUnit?, leaving: ReviewUnit? = nil) {
        selected = unit?.id
        guard let unit else { return }
        if let leaving, leaving.section != unit.section { openFiles.remove(leaving.section) }
        openFiles.insert(unit.section)
    }

    /// ↑↓ and J K: the next hunk, never one in a folded chapter. A file closed under the
    /// keyboard is passed over whole.
    func move(_ step: Int) {
        let units = visibleUnits
        guard !units.isEmpty else { return }
        guard let index = units.firstIndex(where: { $0.id == selected }) else {
            select((step > 0 ? units.first { !$0.reviewed } : units.last { !$0.reviewed }) ?? units.first)
            return
        }
        let here = units[index]
        var next = index + step
        while units.indices.contains(next), units[next].section == here.section, !openFiles.contains(here.section) {
            next += step
        }
        guard units.indices.contains(next) else { return }
        select(units[next], leaving: here)
    }

    /// A click on a file's header opens it or folds it; with ⌥, every file goes the same way.
    func toggle(_ section: ReviewFileSection, all: Bool = false) {
        let open = !openFiles.contains(section.id)
        for id in all ? book.chapters.flatMap(\.files).map(\.id) : [section.id] {
            setOpen(id, open)
        }
    }

    /// Opens a file or folds it. Folding lets go of a note being written in it.
    func setOpen(_ section: String, _ open: Bool) {
        if open {
            openFiles.insert(section)
        } else {
            openFiles.remove(section)
            if book.units.contains(where: { $0.id == noting && $0.section == section }) { noting = nil }
        }
    }

    /// Where the keyboard goes once a hunk is marked: the next one still to review in its file,
    /// earlier ones too, so a file is finished before it's left; else the next in the files after.
    func next(after unit: ReviewUnit) -> ReviewUnit? {
        let units = visibleUnits
        guard let index = units.firstIndex(where: { $0.id == unit.id }) else { return nil }
        let rest = units[(index + 1)...] + units[..<index]
        return rest.first { !$0.reviewed && $0.section == unit.section } ?? rest.first { !$0.reviewed }
    }

    /// Where the keyboard goes once a whole file is marked: the first hunk still to review in the
    /// files after it, round to the top.
    func next(afterFile section: String) -> ReviewUnit? {
        let units = visibleUnits
        guard let index = units.firstIndex(where: { $0.section == section }) else { return nil }
        return (units[index...] + units[..<index]).first { !$0.reviewed && $0.section != section }
    }
}

extension AppModel {
    func toggleReview() {
        if reviewShown { closeReview() } else { openReview() }
    }

    func openReview() {
        guard let folder = workingFolder else { return }
        closeTerminal()
        withAnimation(Motion.move) {
            openFile = nil
            openInIsland(.review)
        }
        readReview(in: folder)
    }

    func closeReview() {
        withAnimation(Motion.move) { reviewShown = false }
        review.noting = nil
    }

    /// Reads the diff again for the open thread's folder: when the thread or the window comes
    /// back, and after every edit while the review is open, so it keeps up with Claude.
    func readReview(in folder: String? = nil, after delay: Duration = .zero) {
        guard let folder = folder ?? workingFolder, engineState == .ready else { return }
        if review.folder != folder {
            review.folder = folder
            review.diff = nil
            review.base = ReviewBook()
            review.book = ReviewBook()
            review.problem = nil
            review.selected = nil
            review.noting = nil
            review.lastTakeback = nil
            review.openFiles = []
            review.placed = false
        }
        review.wanted = true
        review.trigger?.cancel()
        review.trigger = Task {
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await pumpReview()
        }
    }

    /// One git.diff at a time: asks that come in while one runs make one more read after it.
    private func pumpReview() async {
        guard !review.reading else { return }
        review.reading = true
        review.loading = true
        defer {
            review.reading = false
            review.loading = false
        }
        while review.wanted, let folder = review.folder {
            review.wanted = false
            do {
                let reply = try await engine.request("git.diff", ["cwd": .string(folder)])
                let diff = try reply.decode(WorkingDiff.self)
                guard review.folder == folder else { continue }
                await build(diff, in: folder)
            } catch {
                guard review.folder == folder else { continue }
                review.diff = nil
                review.base = ReviewBook()
                review.book = ReviewBook()
                review.problem = error.localizedDescription
            }
        }
    }

    /// The book for a diff. The chapters, words and moves are worked out off the main thread;
    /// the marks go on after, which is all a Space has to redo.
    private func build(_ diff: WorkingDiff, in folder: String) async {
        let items = chat.map { conversation(for: $0).items } ?? []
        let base = await Task.detached(priority: .userInitiated) {
            ReviewBook(diff: diff, provenance: Provenance(items: items) { RepoPath.relative($0, cwd: folder, root: diff.root) })
        }.value
        guard review.folder == folder else { return }
        review.diff = diff
        review.base = base
        review.problem = nil
        review.marks.prune(in: diff.root, head: diff.head, keeping: Set(diff.files.map(\.path)))
        applyMarks()
        if reviewShown { review.placeFiles() }
        colour(review.book.units)
    }

    /// Lays the marks over the book. The keyboard stays on a hunk: one put back is selected
    /// again, and when the selected one is gone, the hunk that took its place is selected, the
    /// way a list moves on after a delete. A note whose hunk has no row any more is let go.
    func applyMarks() {
        guard let root = review.root else { return }
        let before = review.visibleUnits.map(\.id)
        review.book = review.base.marked(with: review.marks.marks(in: root))
        let visible = review.visibleUnits
        if let back = review.reselect.lazy.compactMap({ id in visible.first { $0.id == id } }).first {
            review.select(back)
            review.reselect = []
        } else if let selected = review.selected, !visible.contains(where: { $0.id == selected }) {
            let at = before.firstIndex(of: selected) ?? 0
            review.select(visible.isEmpty ? nil : visible[min(at, visible.count - 1)])
        }
        if let noting = review.noting, !visible.contains(where: { $0.id == noting && !review.folded($0) }) {
            review.noting = nil
        }
    }

    /// Syntax colours for each side of each hunk, worked out off the main thread. A read that
    /// comes in meanwhile starts over with its own hunks.
    private func colour(_ units: [ReviewUnit]) {
        review.colouring?.cancel()
        let keys = Set(units.map(\.colourKey))
        if review.colours.count > 4000 { review.colours = review.colours.filter { keys.contains($0.key) } }
        var seen = Set<String>()
        let missing = units.filter { $0.hunk != nil && review.colours[$0.colourKey] == nil && seen.insert($0.colourKey).inserted }
        guard !missing.isEmpty else { return }
        review.colouring = Task {
            var ready: [String: [AttributedString]] = [:]
            for unit in missing {
                guard !Task.isCancelled else { return }
                let language = CodeHighlighter.language(forPath: unit.file.path)
                let newSide = unit.lines.filter { $0.kind != .deleted }.map(\.text).joined(separator: "\n")
                let oldSide = unit.lines.filter { $0.kind != .added }.map(\.text).joined(separator: "\n")
                let new = await CodeHighlighter.shared.highlight(newSide, language: language).lines()
                let old = await CodeHighlighter.shared.highlight(oldSide, language: language).lines()
                var (n, o) = (0, 0)
                var lines: [AttributedString] = []
                for line in unit.lines {
                    switch line.kind {
                    case .deleted:
                        lines.append(o < old.count ? old[o] : AttributedString(line.text))
                        o += 1
                    case .added:
                        lines.append(n < new.count ? new[n] : AttributedString(line.text))
                        n += 1
                    case .context:
                        lines.append(n < new.count ? new[n] : AttributedString(line.text))
                        n += 1
                        o += 1
                    }
                }
                ready[unit.colourKey] = lines
                // Every view that shows colours redraws when they change, so they arrive in batches.
                if ready.count >= 24 {
                    review.colours.merge(ready) { $1 }
                    ready.removeAll()
                }
            }
            review.colours.merge(ready) { $1 }
        }
    }

    // MARK: Marking

    func setReviewed(_ units: [ReviewUnit], _ reviewed: Bool) {
        guard let root = review.root, !units.isEmpty else { return }
        if reviewed {
            review.marks.mark(units, in: root, current: Set(review.book.units.map(\.fingerprint)))
        } else {
            review.marks.unmark(units, in: root)
        }
        for unit in units { review.unfolded.remove(unit.id) }
        applyMarks()
    }

    /// Space: marks the hunk the keyboard is on, or unmarks it. Only a hunk you can see: with
    /// none selected, the first one to review in an open file, and none while the keyboard's is
    /// in a closed one.
    func toggleSelectedReviewed() {
        let shown = review.selected == nil
            ? review.visibleUnits.first { !$0.reviewed && review.openFiles.contains($0.section) }
            : review.selectedUnit
        guard let shown else { return }
        toggleReviewed(shown)
    }

    /// Space or a hunk's circle: marks it and moves the keyboard on to the next one to review,
    /// opening its file and folding the one it leaves; or unmarks it and keeps the keyboard there.
    func toggleReviewed(_ unit: ReviewUnit) {
        if unit.reviewed {
            setReviewed([unit], false)
            review.selected = unit.id
        } else {
            let next = review.next(after: unit)
            setReviewed([unit], true)
            review.select(next, leaving: unit)
        }
    }

    /// A file's circle: marks every hunk in it, folds it and opens the next file to review; or,
    /// with all of them marked, unmarks them.
    func toggleReviewed(_ section: ReviewFileSection) {
        let open = section.units.filter { !$0.reviewed }
        guard !open.isEmpty else {
            setReviewed(section.units, false)
            return
        }
        let next = review.next(afterFile: section.id)
        setReviewed(open, true)
        review.setOpen(section.id, false)
        review.select(next)
    }

    // MARK: Taking back

    /// Takes units out of the working tree: hunks through git, from the index too where they
    /// were staged, and whole files to the Trash with HEAD's version put back. ⌘Z and the
    /// footer's Undo put everything back as it was, and ⌘⇧Z takes it back again.
    func takeBack(_ units: [ReviewUnit], label: String, undoManager: UndoManager?) {
        guard let folder = review.folder, let root = review.root, !units.isEmpty else { return }
        var hunks: [String: (file: FileDiff, hunks: [DiffHunk])] = [:]
        var whole: [String: FileDiff] = [:]
        for unit in units {
            if unit.file.revertsByHunk, let hunk = unit.hunk {
                hunks[unit.file.path, default: (unit.file, [])].hunks.append(hunk)
            } else {
                whole[unit.file.path + "\u{0}" + unit.file.status] = unit.file
            }
        }
        let patch = hunks.values.sorted { $0.file.path < $1.file.path }
            .map { PatchText.of($0.file.path, hunks: $0.hunks.sorted { $0.newStart < $1.newStart }) }.joined()
        let step = Takeback(
            label: label, folder: folder, root: root, patch: patch.isEmpty ? nil : patch,
            whole: whole.values.sorted { $0.path < $1.path }, marked: units.filter(\.reviewed), unitIDs: units.map(\.id))
        // The keyboard moves on at once, so a second ⌫ takes the next hunk, not this one again.
        let taken = Set(step.unitIDs)
        if let selected = review.selected, taken.contains(selected) {
            let visible = review.visibleUnits
            let at = visible.firstIndex { $0.id == selected } ?? 0
            let rest = visible.filter { !taken.contains($0.id) }
            review.select(rest.isEmpty ? nil : rest[min(at, rest.count - 1)])
        }
        perform(step, undoManager: undoManager, redoing: false)
    }

    /// Takes a step's hunks and files out, the first time or again for Redo. The first time,
    /// Undo is offered once git has taken the hunks, since a patch git refuses changes nothing;
    /// for Redo it has to be offered at once, while the undo manager is redoing.
    private func perform(_ step: Takeback, undoManager: UndoManager?, redoing: Bool) {
        if redoing { offerUndo(step, undoManager) }
        runReview("Taking back…") { [self] in
            guard !step.applied else { return }
            // git takes all of the patch or none of it, so a failure here has changed nothing.
            if let patch = step.patch {
                let reply = try await engine.request("git.apply", [
                    "cwd": .string(step.folder), "patch": .string(patch), "reverse": true, "index": true,
                ])
                step.patched = true
                step.indexPatched = reply["index"]?.bool ?? false
            }
            step.applied = true
            review.marks.unmark(step.marked, in: step.root)
            review.lastTakeback = step
            if !redoing { offerUndo(step, undoManager) }
            // Whatever is at a path HEAD's version will take goes to the Trash first: the file
            // itself, and for a rename whatever sits at its old name.
            var restore: [String] = []
            for file in step.whole {
                for path in file.paths {
                    let url = URL(filePath: step.root).appending(path: path)
                    guard Self.exists(url) else { continue }
                    var trash: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trash)
                    if let trash = trash as URL? { step.trashed.append((path, trash)) }
                }
                // An untracked file has nothing in HEAD or the index to put back.
                if file.status != "?" { restore += file.paths }
            }
            if !restore.isEmpty {
                let reply = try await engine.request("git.restore", ["cwd": .string(step.folder), "paths": .array(restore.map(JSON.string))])
                step.restored = restore
                step.index = (try? reply["index"]?.decode([IndexEntry].self)) ?? []
            }
        } then: { [self] in
            readReview()
        }
    }

    /// Offers ⌘Z for a step. The undo manager doesn't keep its target alive, so the action holds
    /// the step itself.
    private func offerUndo(_ step: Takeback, _ undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: step) { [weak self, weak undoManager] _ in
            MainActor.assumeIsolated { self?.putBack(step, undoManager: undoManager, undoing: true) }
        }
        undoManager?.setActionName(step.label)
    }

    /// Undoes a take-back, only what it did and in reverse: HEAD's versions go to the Trash, since
    /// anything typed into them since is yours, the index entries come back, what went to the
    /// Trash comes out, and the hunks go back in. From ⌘Z it leaves Redo behind; from the
    /// footer's Undo, nothing.
    func putBack(_ step: Takeback, undoManager: UndoManager?, undoing: Bool = false) {
        if undoing {
            undoManager?.registerUndo(withTarget: step) { [weak self, weak undoManager] _ in
                MainActor.assumeIsolated { self?.perform(step, undoManager: undoManager, redoing: true) }
            }
            undoManager?.setActionName(step.label)
        } else {
            undoManager?.removeAllActions(withTarget: step)
        }
        if review.lastTakeback === step { review.lastTakeback = nil }
        review.reselect = step.unitIDs
        runReview("Putting back…") { [self] in
            guard step.applied else { return }
            let root = URL(filePath: step.root)
            if !step.restored.isEmpty {
                for path in step.restored where Self.exists(root.appending(path: path)) {
                    try FileManager.default.trashItem(at: root.appending(path: path), resultingItemURL: nil)
                }
                _ = try await engine.request("git.unrestore", [
                    "cwd": .string(step.folder),
                    "paths": .array(step.restored.map(JSON.string)),
                    "index": .array(step.index.map { ["path": .string($0.path), "mode": .string($0.mode), "sha": .string($0.sha)] }),
                ])
                step.restored = []
                step.index = []
            }
            while let (path, trash) = step.trashed.last {
                let url = root.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: trash, to: url)
                step.trashed.removeLast()
            }
            if step.patched, let patch = step.patch {
                _ = try await engine.request("git.apply", [
                    "cwd": .string(step.folder), "patch": .string(patch), "reverse": false, "index": .bool(step.indexPatched),
                ])
                step.patched = false
                step.indexPatched = false
            }
            step.applied = false
            if !step.marked.isEmpty {
                review.marks.mark(step.marked, in: step.root, current: Set(review.book.units.map(\.fingerprint)))
            }
        } then: { [self] in
            readReview()
        }
    }

    /// Whether anything is at a path, a broken symlink included: lstat, not stat.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    // MARK: Committing

    /// What a commit would take: everything, or only what's marked reviewed.
    struct CommitPlan {
        var paths: [String] = []
        var patch = ""
        var partial: [String] = []
        /// The units it commits, whose marks go once it has.
        var units: [ReviewUnit] = []
        /// Files with reviewed hunks that can only be committed whole, left out.
        var left: [String] = []
        var text = ""
    }

    func commitPlan(reviewedOnly: Bool) -> CommitPlan {
        var plan = CommitPlan()
        guard let diff = review.diff else { return plan }
        let units = Dictionary(grouping: review.book.units) { $0.file.path + "\u{0}" + $0.file.status }
        for file in diff.files {
            let all = units[file.path + "\u{0}" + file.status] ?? []
            let chosen = reviewedOnly ? all.filter(\.reviewed) : all
            guard !chosen.isEmpty else { continue }
            if chosen.count == all.count {
                plan.units += chosen
                plan.paths += file.paths
                plan.text += Self.describe(file, hunks: file.hunks)
            } else if file.commitsByHunk {
                plan.units += chosen
                let hunks = chosen.compactMap(\.hunk).sorted { $0.oldStart < $1.oldStart }
                plan.patch += PatchText.of(file.path, hunks: hunks)
                plan.partial.append(file.path)
                plan.text += Self.describe(file, hunks: hunks)
            } else {
                plan.left.append(file.path)
            }
        }
        return plan
    }

    private static func describe(_ file: FileDiff, hunks: [DiffHunk]) -> String {
        if file.binary { return "Binary file \(file.path) changed.\n" }
        if file.cut { return "\(file.path): +\(file.added) −\(file.deleted), not shown.\n" }
        return PatchText.of(file.path, hunks: hunks)
    }

    /// Haiku writes a message from the diff about to be committed. It changes no file, so it
    /// doesn't wait its turn behind a take-back.
    func writeReviewMessage(reviewedOnly: Bool) {
        guard let folder = review.folder, !review.writing else { return }
        let text = commitPlan(reviewedOnly: reviewedOnly).text
        review.writing = true
        review.problem = nil
        Task {
            do {
                let reply = try await engine.request("git.message", ["cwd": .string(folder), "diff": .string(text)])
                review.message = reply["message"]?.string ?? ""
            } catch {
                review.problem = error.localizedDescription
            }
            review.writing = false
        }
    }

    func commitReview(reviewedOnly: Bool) {
        guard let folder = review.folder, let root = review.root else { return }
        let plan = commitPlan(reviewedOnly: reviewedOnly)
        let message = review.message
        runReview("Committing…") { [self] in
            if reviewedOnly {
                _ = try await engine.request("git.commitReviewed", [
                    "cwd": .string(folder),
                    "paths": .array(plan.paths.map(JSON.string)),
                    "patch": .string(plan.patch),
                    "partial": .array(plan.partial.map(JSON.string)),
                    "message": .string(message),
                ])
            } else {
                _ = try await engine.request("git.commit", [
                    "cwd": .string(folder),
                    "paths": .array(plan.paths.map(JSON.string)),
                    "message": .string(message),
                ])
            }
            // Committed hunks are done with; their marks would only make the rest look seen.
            review.marks.unmark(plan.units, in: root)
            if review.message == message { review.message = "" }
            if !plan.left.isEmpty {
                let names = plan.left.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                review.problem = "Left out \(names): a renamed, new or unreadable file is committed whole, once all of it is reviewed."
            }
        } then: { [self] in
            readReview()
            refreshBranch(for: chat)
        }
    }

    func pushReview() {
        guard let folder = review.folder else { return }
        runReview("Pushing…") { [self] in
            _ = try await engine.request("git.push", ["cwd": .string(folder)])
        } then: { [self] in
            refreshBranch(for: chat)
        }
    }

    /// Runs what the review does to the files one at a time, in the order asked: an Undo pressed
    /// while a take-back is still going waits for it instead of being lost.
    private func runReview(_ label: String, _ work: @escaping @MainActor () async throws -> Void, then: (@MainActor () -> Void)? = nil) {
        let previous = review.queue
        review.queue = Task {
            await previous?.value
            review.busy = label
            review.problem = nil
            do {
                try await work()
            } catch {
                review.problem = error.localizedDescription
            }
            review.busy = nil
            then?()
        }
    }

    // MARK: Notes

    func addNote(on unit: ReviewUnit, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let changed = unit.lines.filter { $0.kind != .context }
        let shown = changed.isEmpty ? unit.lines : changed
        let numbers = shown.compactMap { $0.new ?? $0.old }
        let place = numbers.isEmpty ? unit.file.path
            : numbers.min() == numbers.max() ? "\(unit.file.path):\(numbers.min()!)"
            : "\(unit.file.path):\(numbers.min()!)-\(numbers.max()!)"
        let quote = Array(shown.prefix(12).map(\.signed)) + (shown.count > 12 ? ["…"] : [])
        withAnimation(Motion.move) {
            review.notes.append(ReviewNote(unit: unit.id, path: unit.file.path, quote: quote, place: place, text: trimmed))
            review.noting = nil
        }
    }

    func removeNote(_ note: ReviewNote) {
        withAnimation(Motion.move) { review.notes.removeAll { $0.id == note.id } }
    }

    /// The notes as one message: each place, the lines it's about, and what you said.
    var notesMessage: String {
        let parts = review.notes.map { note in
            "\(note.place)\n" + note.quote.map { "    " + $0 }.joined(separator: "\n") + "\n" + note.text
        }
        return "Notes from reviewing your changes:\n\n" + parts.joined(separator: "\n\n")
    }

    /// Sends the notes as the next message, and keeps the review open to watch what comes back.
    func sendNotes() {
        guard !review.notes.isEmpty, !(currentConversation?.running ?? false) else { return }
        if send(notesMessage) {
            withAnimation(Motion.move) { review.notes.removeAll() }
        }
    }
}

extension AttributedString {
    /// The string cut at each newline, the newlines left out. It's cut by scalar: in a file with
    /// CRLF endings "\r\n" is one character, which a cut by character never finds.
    func lines() -> [AttributedString] {
        var lines: [AttributedString] = []
        var start = startIndex
        var index = unicodeScalars.startIndex
        while index < unicodeScalars.endIndex {
            if unicodeScalars[index] == "\n" {
                lines.append(AttributedString(self[start..<index]))
                start = unicodeScalars.index(after: index)
            }
            index = unicodeScalars.index(after: index)
        }
        lines.append(AttributedString(self[start..<endIndex]))
        return lines
    }
}
