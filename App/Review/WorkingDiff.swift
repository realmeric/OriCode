import CryptoKit
import Foundation

/// The working tree against HEAD, as the engine's git.diff reads it. Paths are from the
/// repository's top.
struct WorkingDiff: Decodable, Sendable {
    let root: String
    /// HEAD's commit, nil before the first one.
    let head: String?
    let files: [FileDiff]
}

struct FileDiff: Decodable, Hashable, Sendable {
    let path: String
    /// A rename's path before it.
    let oldPath: String?
    /// "M" modified, "A" added, "D" deleted, "R" renamed, "T" changed type, "?" untracked.
    let status: String
    let binary: Bool
    let executable: Bool
    let hunks: [DiffHunk]
    let added: Int
    let deleted: Int
    /// Too large to show: the counts are right and the hunks are left out.
    let cut: Bool
    /// Size and date, for a file that can't be shown line by line.
    let stamp: String?
    /// Some of its text isn't UTF-8, so the lines shown can't be written back byte for byte.
    let lossy: Bool

    var isNew: Bool { status == "?" || status == "A" }

    /// Whether git can take one hunk back out of the working tree on its own. A deleted file
    /// has nothing there to take it from, and a new one is all one hunk.
    var revertsByHunk: Bool { !binary && !cut && !lossy && !hunks.isEmpty && (status == "M" || status == "R") }

    /// Whether some of its hunks can be committed without the rest: the index has to hold the
    /// file under the same name.
    var commitsByHunk: Bool { !binary && !cut && !lossy && !hunks.isEmpty && (status == "M" || status == "D") }

    /// The paths a whole-file commit has to name, a rename's old one too.
    var paths: [String] { [oldPath, path].compactMap { $0 } }
}

struct DiffHunk: Decodable, Hashable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    /// What git puts after the second @@: the function or type the hunk is in.
    let context: String
    /// "+", "-" and " " lines, and "\" for a missing newline at the end.
    let lines: [String]

    var changed: [String] { lines.filter { $0.hasPrefix("+") || $0.hasPrefix("-") } }
}

enum PatchText {
    /// Hunks of one file as `git apply` takes them. The file is named the same on both sides,
    /// since a hunk on its own neither creates, deletes nor renames it.
    static func of(_ path: String, hunks: [DiffHunk]) -> String {
        var text = "diff --git \(quoted("a/" + path)) \(quoted("b/" + path))\n--- \(quoted("a/" + path))\n+++ \(quoted("b/" + path))\n"
        for hunk in hunks {
            text += "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@\n"
            text += hunk.lines.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// git's C-style quoting, for a name git would quote: one with a quote, a backslash or a
    /// control character in it.
    static func quoted(_ name: String) -> String {
        guard name.unicodeScalars.contains(where: { $0 == "\"" || $0 == "\\" || $0.value < 0x20 || $0.value == 0x7F }) else { return name }
        var out = "\""
        for scalar in name.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\%03o", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

enum Fingerprint {
    /// What a hunk changes, wherever it has moved to in its file: the lines it takes out and
    /// puts in. The same change keeps its mark as edits above it shift it down, and as a new
    /// file goes from untracked to added.
    static func of(path: String, status: String, hunk: DiffHunk) -> String {
        digest([path, same(status)] + hunk.changed)
    }

    /// A file the review can't read line by line is known by its size and date.
    static func of(file: FileDiff) -> String {
        digest([file.path, same(file.status), "file", file.stamp ?? "", "\(file.added)", "\(file.deleted)"])
    }

    /// Every line of a hunk, for caching what's drawn from all of them.
    static func colours(path: String, hunk: DiffHunk) -> String {
        digest([path] + hunk.lines)
    }

    private static func same(_ status: String) -> String {
        status == "?" ? "A" : status
    }

    private static func digest(_ parts: [String]) -> String {
        let data = Data(parts.joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
