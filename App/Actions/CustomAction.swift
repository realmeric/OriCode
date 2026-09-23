import Foundation

/// One of your own rows in ⌘K: a command line with placeholders, typed into the terminal or run
/// quietly by the engine.
struct CustomAction: Codable, Identifiable, Equatable, Sendable {
    enum Runs: String, Codable, CaseIterable, Sendable {
        case terminal, quietly
    }

    var id = UUID()
    var name: String
    var command: String
    var runs = Runs.terminal
    /// Shows the line it will run and waits for Return before running it.
    var asks = false
    /// Only in this project's threads; in every project when nil.
    var project: UUID?

    var wantsInput: Bool { command.contains("{input}") }

    init(name: String, command: String, runs: Runs = .terminal, asks: Bool = false, project: UUID? = nil) {
        self.name = name
        self.command = command
        self.runs = runs
        self.asks = asks
        self.project = project
    }

    // A hand-edited file can leave out everything but the name and the command.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        runs = try container.decodeIfPresent(Runs.self, forKey: .runs) ?? .terminal
        asks = try container.decodeIfPresent(Bool.self, forKey: .asks) ?? false
        project = try container.decodeIfPresent(UUID.self, forKey: .project)
    }

    /// What the first run writes, to show what an action can be.
    static let examples = [
        CustomAction(name: "Branch from origin/main", command: "git fetch origin main && git switch -c {input} origin/main"),
        CustomAction(name: "Stash changes", command: "git stash push --include-untracked", runs: .quietly),
        CustomAction(name: "Pop stash", command: "git stash pop", runs: .quietly),
        CustomAction(name: "Open pull request", command: "gh pr view --web 2>/dev/null || gh pr create --web"),
        CustomAction(
            name: "Run tests",
            command: "if [ -f Makefile ]; then make test; elif [ -f package.json ]; then npm test; elif [ -f Package.swift ]; then swift test; elif [ -f Cargo.toml ]; then cargo test; else echo 'No tests found here.'; fi"),
    ]
}

/// What each placeholder stands for in the open thread; nil where there's nothing to put.
struct ActionValues: Equatable {
    var cwd: String?
    var project: String?
    var projectName: String?
    var branch: String?
    var thread: String?
    var session: String?
}

enum ActionLine {
    /// Each placeholder with what an action that uses it says when there's no value for it.
    /// {input} isn't here: it's asked for, so it never stops an action.
    static let placeholders: [(name: String, missing: String)] = [
        ("cwd", "Add a project first"),
        ("project", "Add a project first"),
        ("projectName", "Add a project first"),
        ("branch", "There's no branch here"),
        ("thread", "Open a thread first"),
        ("session", "This thread has no session yet"),
    ]

    /// Why the command can't run with these values, or nil when it can.
    static func unavailable(_ command: String, with values: ActionValues) -> String? {
        if let problem = problem(in: command) { return problem }
        return placeholders.first { command.contains("{\($0.name)}") && value(of: $0.name, in: values) == nil }?.missing
    }

    /// What's wrong with the command whatever the values: a placeholder inside $(…) or
    /// backticks, where the quoting starts over and a value's quotes can't be made to hold.
    static func problem(in command: String) -> String? {
        scan(command) { _ in "" } == nil ? "A placeholder inside $(…) or backticks can't be quoted safely" : nil
    }

    /// The command with every placeholder replaced by its value, quoted for where it stands, so
    /// nothing in a value (a quote, `$(…)`, a space) is read by the shell: in single quotes
    /// when it stands bare, and inside "…" or '…' by closing that quote around its own. One pass:
    /// a value that holds `{input}` is never replaced again. Braces that aren't a placeholder,
    /// like awk's `{print $1}`, stay, and so does one after a backslash or a `$`.
    static func expand(_ command: String, with values: ActionValues, input: String? = nil) -> String {
        scan(command) { name in name == "input" ? input : value(of: name, in: values) } ?? command
    }

    private enum Quoting: Equatable {
        case bare, single, double, backtick
        case substitution(parens: Int)
    }

    /// Reads the command's quoting the way a shell does and replaces each placeholder that has a
    /// value; nil when one stands inside $(…) or backticks.
    private static func scan(_ command: String, value: (String) -> String?) -> String? {
        let characters = Array(command)
        var stack = [Quoting.bare]
        var line = ""
        var at = 0
        while at < characters.count {
            let character = characters[at]
            let next = at + 1 < characters.count ? characters[at + 1] : nil
            let quoting = stack[stack.count - 1]
            if character == "\\", quoting != .single {
                line.append(character)
                if let next { line.append(next) }
                at += 2
                continue
            }
            if character == "{", at == 0 || characters[at - 1] != "$",
               let name = (placeholders.map(\.name) + ["input"]).first(where: { characters[at...].starts(with: "{\($0)}") }) {
                let substituted = stack.contains { quoting in
                    if case .substitution = quoting { return true }
                    return quoting == .backtick
                }
                if substituted { return nil }
                let token = "{\(name)}"
                at += token.count
                guard let value = value(name) else {
                    line += token
                    continue
                }
                switch quoting {
                case .single: line += "'" + value.shellQuoted + "'"
                case .double: line += "\"" + value.shellQuoted + "\""
                default: line += value.shellQuoted
                }
                continue
            }
            switch quoting {
            case .single:
                if character == "'" { stack.removeLast() }
            case .double:
                if character == "\"" {
                    stack.removeLast()
                } else if character == "$", next == "(" {
                    stack.append(.substitution(parens: 0))
                    line += "$("
                    at += 2
                    continue
                } else if character == "`" {
                    stack.append(.backtick)
                }
            case .bare, .backtick, .substitution:
                if character == "'" {
                    stack.append(.single)
                } else if character == "\"" {
                    stack.append(.double)
                } else if character == "$", next == "(" {
                    stack.append(.substitution(parens: 0))
                    line += "$("
                    at += 2
                    continue
                } else if character == "`" {
                    if quoting == .backtick { stack.removeLast() } else { stack.append(.backtick) }
                } else if case .substitution(let parens) = quoting {
                    if character == "(" {
                        stack[stack.count - 1] = .substitution(parens: parens + 1)
                    } else if character == ")" {
                        if parens == 0 { stack.removeLast() } else { stack[stack.count - 1] = .substitution(parens: parens - 1) }
                    }
                }
            }
            line.append(character)
            at += 1
        }
        return line
    }

    private static func value(of name: String, in values: ActionValues) -> String? {
        switch name {
        case "cwd": values.cwd
        case "project": values.project
        case "projectName": values.projectName
        case "branch": values.branch
        case "thread": values.thread
        case "session": values.session
        default: nil
        }
    }
}

/// Your actions, in Application Support/OriCode/actions.json and never in a repository. The
/// first run writes the examples; a file that doesn't read is left as it is, and says so.
@MainActor @Observable final class CustomActionStore {
    private(set) var actions: [CustomAction] = []
    private(set) var problem: String?
    let file: URL
    /// The file's date when it was last read or written, so a change made to it elsewhere (by
    /// hand, or by the app's other build) is read before anything is saved over it.
    @ObservationIgnored private var seen: Date?

    static var standardFile: URL {
        URL.applicationSupportDirectory.appending(path: "OriCode/actions.json")
    }

    init(file: URL = CustomActionStore.standardFile) {
        self.file = file
        load()
    }

    /// Reads the file again if it changed since. Settings and ⌘K call it as they open, and every
    /// change starts with it.
    func refresh() {
        if !FileManager.default.fileExists(atPath: file.path) || modified != seen { load() }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: file.path) else {
            actions = CustomAction.examples
            problem = nil
            write()
            return
        }
        do {
            var read = try JSONDecoder().decode([CustomAction].self, from: Data(contentsOf: file))
            // An entry copied by hand keeps its id; it gets one of its own, or deleting one would
            // delete both.
            var ids = Set<UUID>()
            var repeated = false
            for index in read.indices where !ids.insert(read[index].id).inserted {
                read[index].id = UUID()
                repeated = true
            }
            actions = read
            problem = nil
            seen = modified
            if repeated { write() }
        } catch {
            seen = modified
            problem = "actions.json couldn't be read, so it's left as it is. Once it's fixed, OriCode reads it again as Settings or ⌘K opens."
        }
    }

    func save(_ action: CustomAction) {
        refresh()
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        write()
    }

    func remove(_ action: CustomAction) {
        refresh()
        actions.removeAll { $0.id == action.id }
        write()
    }

    /// One place up or down the list, which is ⌘K's order.
    func move(_ action: CustomAction, up: Bool) {
        refresh()
        guard let index = actions.firstIndex(where: { $0.id == action.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard actions.indices.contains(target) else { return }
        actions.swapAt(index, target)
        write()
    }

    /// Actions kept to a project that's been removed go back to every project, instead of
    /// vanishing from ⌘K while Settings shows them.
    func forget(project: UUID) {
        refresh()
        guard actions.contains(where: { $0.project == project }) else { return }
        for index in actions.indices where actions[index].project == project {
            actions[index].project = nil
        }
        write()
    }

    private var modified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    private func write() {
        // Never over a file that didn't read: whatever's in it is still someone's.
        guard problem == nil else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(actions).write(to: file, options: .atomic)
            seen = modified
        } catch {
            problem = "actions.json couldn't be saved: \(error.localizedDescription)"
        }
    }
}
