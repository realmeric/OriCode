import Foundation

/// What a hunk does that a line diff doesn't say: code that moved rather than changed, a test
/// whose expectation changed or that was switched off, a lockfile. Worked out from the text, so
/// they're labels to look closer, never verdicts.
enum Signals {
    /// Marks moved lines and labels both ends of each move. A run of deleted lines counts as
    /// moved when nearly all of it, three lines or more and spacing aside, turns up in one run
    /// of added lines somewhere else: another file, or another place in the same one. The
    /// lines that did change on the way stay lit, and so does whatever came with them.
    static func findMoves(in units: inout [ReviewUnit]) {
        struct Run {
            let unit: Int
            let lines: [Int]
            /// Its lines that say something, spacing aside, by their text.
            var byText: [String: [Int]] = [:]
        }
        var deleted: [Run] = [], added: [Run] = []
        for (u, unit) in units.enumerated() {
            var index = 0
            while index < unit.lines.count {
                let kind = unit.lines[index].kind
                guard kind != .context else {
                    index += 1
                    continue
                }
                let end = unit.lines[index...].firstIndex { $0.kind != kind } ?? unit.lines.count
                var run = Run(unit: u, lines: Array(index..<end))
                for line in run.lines where meaningful(unit.lines[line].text) {
                    run.byText[normal(unit.lines[line].text), default: []].append(line)
                }
                if kind == .deleted { deleted.append(run) } else { added.append(run) }
                index = end
            }
        }
        // Past this much it's a rewrite, not a move, and the pairing would only cost time.
        guard !deleted.isEmpty, !added.isEmpty, deleted.count * added.count <= 250_000 else { return }
        for source in deleted {
            let wanted = source.lines.filter { meaningful(units[source.unit].lines[$0].text) }
            guard wanted.count >= 3 else { continue }
            var best: (run: Int, pairs: [(from: Int, to: Int)])?
            for (a, target) in added.enumerated() {
                // A deleted run right before an added one in the same hunk is lines edited in
                // place, which the words show; it isn't a move.
                if target.unit == source.unit, source.lines.last.map({ $0 + 1 }) == target.lines.first { continue }
                var open = target.byText
                var pairs: [(from: Int, to: Int)] = []
                for line in wanted {
                    let text = normal(units[source.unit].lines[line].text)
                    if let match = open[text]?.first {
                        open[text]!.removeFirst()
                        pairs.append((line, match))
                    }
                }
                if pairs.count > (best?.pairs.count ?? 0) { best = (a, pairs) }
            }
            guard let best, best.pairs.count >= 3, Double(best.pairs.count) >= Double(wanted.count) * 0.8 else { continue }
            let target = added[best.run]
            for pair in best.pairs {
                units[source.unit].lines[pair.from].moved = true
                units[target.unit].lines[pair.to].moved = true
                // One deleted line moves to one added line: this one is taken.
                let text = normal(units[target.unit].lines[pair.to].text)
                added[best.run].byText[text]?.removeAll { $0 == pair.to }
            }
            // Braces and blank lines go with the block when the other end has them too.
            var taken = Set(best.pairs.map(\.to))
            for line in source.lines where !meaningful(units[source.unit].lines[line].text) {
                let text = normal(units[source.unit].lines[line].text)
                if let match = target.lines.first(where: { !taken.contains($0) && !meaningful(units[target.unit].lines[$0].text) && normal(units[target.unit].lines[$0].text) == text }) {
                    taken.insert(match)
                    units[source.unit].lines[line].moved = true
                    units[target.unit].lines[match].moved = true
                }
            }
            let fromLine = units[source.unit].lines[best.pairs[0].from].old ?? 0
            let toLine = best.pairs.compactMap { units[target.unit].lines[$0.to].new }.min() ?? 0
            let (from, to) = (units[source.unit].file.path, units[target.unit].file.path)
            // Retyped rather than moved: a model that moves code from memory changes it on the way.
            let changed = best.pairs.count < wanted.count ? ", changed on the way" : ""
            units[target.unit].labels.append("moved from \(place(from, fromLine, beside: to))\(changed)")
            units[source.unit].labels.append("moved to \(place(to, toLine, beside: from))\(changed)")
        }
    }

    /// A place in another file by its name and line, and in the same file by its line alone.
    private static func place(_ path: String, _ line: Int, beside own: String) -> String {
        path == own ? "line \(line)" : "\((path as NSString).lastPathComponent):\(line)"
    }

    static func normal(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
    }

    private static func meaningful(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: Tests and lockfiles

    /// Labels for a hunk in a test file that takes an assertion out or changes one, or that
    /// switches a test off: what an agent does when it makes a failing test pass the wrong way.
    static func testLabels(_ unit: ReviewUnit) -> [String] {
        guard isTest(unit.file.path) else { return [] }
        var labels: [String] = []
        if unit.lines.contains(where: { $0.kind == .deleted && assertion($0.text) }) {
            labels.append(changesExpectation)
        }
        if unit.lines.contains(where: { $0.kind == .added && skips($0.text) }) {
            labels.append(switchesOff)
        }
        return labels
    }

    static let changesExpectation = "changes what a test expects"
    static let switchesOff = "switches a test off"
    static let testWarnings: Set = [changesExpectation, switchesOff]

    /// A test by where it lives or what it's called, the way the usual tools name them:
    /// Tests/, __tests__/, FooTests.swift, foo.test.ts, foo_test.go, test_foo.py. Contest.swift isn't.
    static func isTest(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.dropLast().contains(where: { ["test", "tests", "spec", "specs", "__tests__", "testing"].contains($0.lowercased()) || $0.hasSuffix("Tests") }) {
            return true
        }
        let stem = ((parts.last ?? "") as NSString).deletingPathExtension
        return ["Test", "Tests", "Spec", "_test", ".test", "-test", ".spec", "_spec"].contains { stem.hasSuffix($0) }
            || stem.lowercased().hasPrefix("test_") || ["test", "tests"].contains(stem.lowercased())
    }

    private static let assertions = try! NSRegularExpression(pattern: #"(\bassert\w*|\bXCTAssert\w*|\bXCTFail\b|#expect\b|#require\b|\bexpect\s*\(|\.to(Be|Equal|Match|Have|Throw|Contain)\w*|\bshould\w*|\brequire\.\w+|\bt\.(Error|Fatal)\w*)"#)

    private static let skipping = try! NSRegularExpression(pattern: #"(\b(it|test|describe|context)\.skip\b|\bx(it|describe|test)\s*\(|@(pytest\.mark\.)?skip\w*|@unittest\.skip\w*|\bXCTSkip\w*|\.disabled\s*\(|@Disabled\b|@Ignore\b|#\[ignore\]|\bt\.Skip\w*\()"#)

    static func assertion(_ text: String) -> Bool {
        assertions.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func skips(_ text: String) -> Bool {
        skipping.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Files a package manager writes, which are rarely worth reading line by line.
    static func isLockfile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lock", "bun.lockb", "Package.resolved", "Cargo.lock",
                "Gemfile.lock", "poetry.lock", "uv.lock", "composer.lock", "go.sum", "Podfile.lock", "pubspec.lock", "mix.lock"]
            .contains(name)
    }
}
