import SwiftUI

/// A line diff of what an edit does, from the tool's input rather than from git.
struct Diff: Hashable {
    enum Kind: Hashable {
        case context, added, deleted, gap
    }

    struct Line: Hashable {
        let kind: Kind
        let text: String
    }

    let path: String
    let lines: [Line]

    var added: Int { lines.count { $0.kind == .added } }
    var deleted: Int { lines.count { $0.kind == .deleted } }

    static func between(_ old: String, _ new: String) -> [Line] {
        let before = old.components(separatedBy: "\n")
        let after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [Line] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                lines.append(Line(kind: .deleted, text: before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                lines.append(Line(kind: .added, text: after[j]))
                j += 1
            } else {
                if j < after.count { lines.append(Line(kind: .context, text: after[j])) }
                i += 1
                j += 1
            }
        }
        return lines
    }

    /// What an edit did: the hunks it reported once it ran, or the diff of its input before then.
    static func of(_ call: ToolCall, cwd: String) -> Diff? {
        guard call.isEdit else { return nil }
        guard let patch = call.patch, !patch.isEmpty else { return of(tool: call.name, input: call.input, cwd: cwd) }
        var lines: [Line] = []
        for (index, hunk) in patch.enumerated() {
            if index > 0 { lines.append(Line(kind: .gap, text: "")) }
            for raw in hunk.lines {
                let text = String(raw.dropFirst())
                switch raw.first {
                case "+": lines.append(Line(kind: .added, text: text))
                case "-": lines.append(Line(kind: .deleted, text: text))
                case "\\": continue
                default: lines.append(Line(kind: .context, text: text))
                }
            }
        }
        return Diff(path: ToolSummary.relative(call.input["file_path"]?.string ?? "", to: cwd), lines: lines)
    }

    /// The diff an Edit, MultiEdit or Write call would make, or nil for any other tool.
    static func of(tool: String, input: JSON, cwd: String) -> Diff? {
        let path = ToolSummary.relative(input["file_path"]?.string ?? "", to: cwd)
        switch tool {
        case "Edit":
            return Diff(path: path, lines: between(input["old_string"]?.string ?? "", input["new_string"]?.string ?? ""))
        case "MultiEdit":
            let lines = (input["edits"]?.array ?? []).flatMap {
                between($0["old_string"]?.string ?? "", $0["new_string"]?.string ?? "")
            }
            return Diff(path: path, lines: lines)
        case "Write":
            let content = input["content"]?.string ?? ""
            return Diff(path: path, lines: content.components(separatedBy: "\n").map { Line(kind: .added, text: $0) })
        default:
            return nil
        }
    }
}

struct DiffLinesView: View {
    let lines: [Diff.Line]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: prefix(line.kind) + line.text)
                        .font(Type.mono)
                        .foregroundStyle(color(line.kind))
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tint(line.kind))
                }
            }
            .padding(.vertical, 10)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: 360)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func prefix(_ kind: Diff.Kind) -> String {
        switch kind {
        case .context: "  "
        case .added: "+ "
        case .deleted: "− "
        case .gap: "⋯"
        }
    }

    private func color(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .context: Ink.secondary
        case .gap: Ink.faint
        case .added: Ink.added
        case .deleted: Ink.deleted
        }
    }

    private func tint(_ kind: Diff.Kind) -> Color {
        switch kind {
        case .context, .gap: .clear
        case .added: Ink.added.opacity(0.10)
        case .deleted: Ink.deleted.opacity(0.10)
        }
    }
}
