import Foundation

/// What you've marked reviewed, by repository, in Application Support/OriCode/reviewed.json.
/// A mark outlives its hunk changing, so the review can show what's new since you looked. It
/// goes once HEAD has moved and its file is no longer in the diff, committed or on another
/// branch; a stash between two looks leaves it alone. Past thirty days it goes anyway.
@MainActor
final class ReviewMarks {
    private struct Repository: Codable {
        /// HEAD when the marks were last pruned.
        var head: String?
        var marks: [String: ReviewMark] = [:]
    }

    private var byRoot: [String: Repository] = [:]
    private let file: URL
    private var loaded = false

    static var standardFile: URL {
        URL.applicationSupportDirectory.appending(path: "OriCode/reviewed.json")
    }

    init(file: URL = ReviewMarks.standardFile) {
        self.file = file
    }

    func marks(in root: String) -> [String: ReviewMark] {
        load()
        return byRoot[root]?.marks ?? [:]
    }

    /// Marks units reviewed. An older mark on the same lines of the file goes, once its hunk
    /// has left the diff: what was new in it is seen now. `current` is every hunk still there.
    func mark(_ units: [ReviewUnit], in root: String, current: Set<String>) {
        load()
        var marks = byRoot[root]?.marks ?? [:]
        for unit in units {
            let lines = unit.lines.filter { $0.kind != .context }.map(\.signed)
            if !lines.isEmpty {
                let now = Set(lines.filter(ReviewBook.significant))
                marks = marks.filter { fingerprint, mark in
                    current.contains(fingerprint) || mark.path != unit.file.path || Set(mark.lines).isDisjoint(with: now)
                }
            }
            marks[unit.fingerprint] = ReviewMark(path: unit.file.path, lines: lines, at: .now)
        }
        byRoot[root, default: Repository()].marks = marks
        save()
    }

    func unmark(_ units: [ReviewUnit], in root: String) {
        load()
        guard byRoot[root] != nil, !units.isEmpty else { return }
        for unit in units { byRoot[root]?.marks[unit.fingerprint] = nil }
        save()
    }

    /// After a read: once HEAD has moved, the marks of files no longer in the diff go, and
    /// marks older than thirty days go whatever HEAD does.
    func prune(in root: String, head: String?, keeping paths: Set<String>) {
        load()
        var repository = byRoot[root] ?? Repository(head: head)
        let moved = repository.head != head
        let old = Date.now.addingTimeInterval(-30 * 86_400)
        let kept = repository.marks.filter { _, mark in mark.at > old && (!moved || paths.contains(mark.path)) }
        guard moved || kept.count != repository.marks.count || byRoot[root] == nil else { return }
        repository.head = head
        repository.marks = kept
        byRoot[root] = repository
        save()
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        byRoot = (try? JSONDecoder().decode([String: Repository].self, from: data)) ?? [:]
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(byRoot) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
