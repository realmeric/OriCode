import SwiftUI

/// A row of the command center (⌘K): a command, a thread, a project, or a choice from a list.
struct PaletteItem: Identifiable {
    /// Also the order ties are broken in.
    enum Kind: Int {
        case command, thread, project, choice
    }

    let id: String
    let kind: Kind
    let title: String
    var subtitle: String?
    /// Found by a search, never shown.
    var keywords: [String] = []
    var shortcut: String?
    var icon: String?
    /// Threads and projects show the project's badge.
    var project: Project?
    /// The current model, level or mode in a list.
    var checked = false
    /// Why it can't run now: drawn faint, with this as its line.
    var unavailable: String?
    let action: PaletteAction

    var opensLevel: Bool {
        switch action {
        case .list, .input: true
        case .run, .task: false
        }
    }
}

enum PaletteAction {
    /// Closes the command center, then runs.
    case run(@MainActor () -> Void)
    /// Stays open, saying what it's doing, while it runs; closes once it's done with what it
    /// returns as the note under the composer, and shows an error in place.
    case task(String, @MainActor () async throws -> String?)
    /// A level of its own: a list to pick from, or a line to type.
    case list(PaletteList)
    case input(PaletteInput)
}

struct PaletteList {
    let title: String
    let placeholder: String
    let items: @MainActor () async throws -> [PaletteItem]
    /// A row made of what's typed, when no row is called that: Create branch “name”.
    var typed: (@MainActor (String) -> PaletteItem?)? = nil
}

struct PaletteInput {
    let title: String
    let placeholder: String
    var initial = ""
    /// The line under the field for what's typed so far; a problem keeps Return from running.
    var hint: @MainActor (String) -> PaletteHint = { _ in .none }
    let submit: @MainActor (String) async throws -> String?
}

enum PaletteHint: Equatable {
    case none
    case info(String)
    case problem(String)
}

/// Where the command center is: the levels open, what's typed at each, and what it's doing.
@MainActor @Observable final class PaletteState {
    struct Level {
        enum Kind {
            case root
            case list(PaletteList)
            case input(PaletteInput)
        }

        var kind: Kind
        var query = ""
        var selected = 0
        var items: [PaletteItem] = []
        var loading = false
    }

    var stack = [Level(kind: .root)]
    /// What a running task is doing, and what went wrong last.
    var busy: String?
    var problem: String?

    var level: Level {
        get { stack[stack.count - 1] }
        set { stack[stack.count - 1] = newValue }
    }

    func reset() {
        stack = [Level(kind: .root)]
        busy = nil
        problem = nil
    }

    func push(_ kind: Level.Kind, query: String = "") {
        stack.append(Level(kind: kind, query: query))
        problem = nil
    }

    /// Back one level; false at the top, where Esc closes the command center instead.
    func pop() -> Bool {
        guard stack.count > 1 else { return false }
        stack.removeLast()
        problem = nil
        return true
    }
}

enum Palette {
    /// A typed search: the rows whose title, words or line match, best first. Rows used lately
    /// come ahead, the choices from inside lists behind, and on a tie commands come before
    /// threads, projects and choices. A blank query keeps the order given.
    static func rank(_ items: [PaletteItem], by query: String, recents: [String] = []) -> [PaletteItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items
            .compactMap { item -> (PaletteItem, Int)? in
                let line = item.kind == .thread || item.kind == .project ? [item.subtitle ?? ""] : []
                guard var score = Fuzzy.score(query, in: ([item.title] + item.keywords + line).joined(separator: " ")) else { return nil }
                if let at = recents.firstIndex(of: item.id) { score += (20 - min(at, 20)) * 2 }
                if item.kind == .choice { score -= 12 }
                return (item, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.kind.rawValue < $1.0.kind.rawValue }
            .map(\.0)
    }
}
