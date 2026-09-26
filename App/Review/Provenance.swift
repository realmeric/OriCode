import Foundation

/// Which turn of a thread wrote each changed line, read from the diffs of its own edits. A line
/// is known by its file and its text, so of two identical lines in a file both belong to the
/// latest turn that wrote either. What no edit wrote (a command's change, yours, another
/// thread's) has no turn, and the review says so rather than guess.
struct Provenance {
    /// Each turn's message, by its number: the first message is turn 1.
    private(set) var prompts: [Int: String] = [:]
    private var added: [String: [String: Int]] = [:]
    private var deleted: [String: [String: Int]] = [:]
    /// For each turn, the files it edited in the order it first did.
    private var order: [Int: [String: Int]] = [:]
    /// The latest turn that edited each file at all, for files the review can't read by line.
    private var lastEdit: [String: Int] = [:]
    /// What each turn ran to check its work: builds, tests, linters, and whether they passed.
    private(set) var checks: [Int: [Check]] = [:]

    struct Check: Hashable, Sendable {
        let command: String
        let failed: Bool
    }

    init() {}

    /// `resolve` turns an edit's file_path into a path from the repository's top, or nil for a
    /// file outside it.
    init(items: [Item], resolve: (String) -> String?) {
        var turn = 0
        for item in items {
            switch item {
            case .user(_, let text, _, let midTurn):
                // Taken up in the middle of a turn, a message is part of that turn.
                guard !midTurn else { continue }
                turn += 1
                prompts[turn] = text
            case .tool(_, let call) where call.name == "Bash":
                guard let command = call.input["command"]?.string, call.result != nil, Self.checks(command) else { continue }
                let check = Check(command: command, failed: call.isError)
                checks[turn, default: []].removeAll { $0.command == command }
                checks[turn, default: []].append(check)
            case .tool(_, let call):
                guard call.isEdit, call.result != nil, !call.isError,
                      let file = call.input["file_path"]?.string, let path = resolve(file),
                      let diff = Diff.of(call, cwd: "")
                else { continue }
                lastEdit[path] = turn
                if order[turn, default: [:]][path] == nil { order[turn, default: [:]][path] = order[turn]?.count ?? 0 }
                for line in diff.lines {
                    switch line.kind {
                    case .added: added[path, default: [:]][line.text] = turn
                    case .deleted: deleted[path, default: [:]][line.text] = turn
                    case .context, .gap: break
                    }
                }
            default:
                break
            }
        }
    }

    /// The turn whose edit put this line in, or took it out: a "+" or "-" line of git's diff.
    func turn(of line: String, in path: String) -> Int? {
        guard let sign = line.first else { return nil }
        let text = String(line.dropFirst())
        return sign == "+" ? added[path]?[text] : sign == "-" ? deleted[path]?[text] : nil
    }

    func lastTurn(editing path: String) -> Int? { lastEdit[path] }

    /// Where a file comes in its turn: the order the turn first edited its files, which is the
    /// order the review tells them in.
    func rank(of path: String, in turn: Int) -> Int { order[turn]?[path] ?? Int.max }

    var isEmpty: Bool { lastEdit.isEmpty }

    /// A command that checks the work rather than looks around: a build, tests, a linter, run
    /// by a tool that does that. `cat test.txt` reads a file; `make test` checks.
    static func checks(_ command: String) -> Bool {
        let runners: Set = ["pytest", "jest", "vitest", "tsc", "eslint", "mypy", "ruff", "xcodebuild", "swiftlint", "rspec", "phpunit", "mvn", "gradle", "ctest", "tox"]
        let tools: Set = ["make", "npm", "pnpm", "yarn", "bun", "cargo", "go", "swift", "deno", "npx", "node", "python", "python3", "uv", "bundle", "dotnet", "mix", "just"]
        let asks: Set = ["test", "tests", "build", "lint", "check", "typecheck", "clippy", "vet", "--test", "pytest", "spec"]
        for segment in command.components(separatedBy: CharacterSet(charactersIn: "&;|\n")) {
            // Leading VAR=value assignments set up the command; the tool comes after them.
            let words = segment.split(separator: " ").map(String.init).drop { $0.contains("=") }
            guard let first = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            if runners.contains(first) { return true }
            if tools.contains(first), words.dropFirst().contains(where: { asks.contains($0) || $0.hasPrefix("test:") }) { return true }
        }
        return false
    }
}

enum RepoPath {
    /// An edit's file_path as a path from the repository's top, or nil when it's outside. Both
    /// sides are compared as real paths, since git reports the top with symlinks resolved.
    static func relative(_ file: String, cwd: String, root: String) -> String? {
        let absolute = file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file)
        let standard = (absolute as NSString).standardizingPath
        if let inside = strip(root, from: standard) { return inside }
        return strip(real(root), from: real(standard))
    }

    private static func strip(_ root: String, from path: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// realpath(3), for a file that may be gone: its folder's real path and its name.
    static func real(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty, folder != path else { return path }
        return (real(folder) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
