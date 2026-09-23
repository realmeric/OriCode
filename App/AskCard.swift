import MarkdownUI
import SwiftUI

/// Claude waiting on you: a permission for a tool, or a question with options.
struct AskCard: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let cwd: String
    /// Only the oldest waiting card takes Return and Esc.
    let listens: Bool

    static let skipMessage = "The user skipped the question. Carry on with your best judgement, and say what you assumed."

    var body: some View {
        if ask.state == .waiting {
            waiting
                .padding(14)
                .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
        } else {
            Text(settledLine)
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity.animation(Motion.fade.delay(0.08)))
        }
    }

    @ViewBuilder
    private var waiting: some View {
        if ask.kind == "question" {
            QuestionForm(ask: ask, listens: listens)
        } else {
            PermissionForm(ask: ask, cwd: cwd, listens: listens)
        }
    }

    private var settledLine: String {
        let what = ask.kind == "question" ? "Question" : ToolSummary.line(for: ToolCall(toolUseId: "", name: ask.tool, input: ask.input), cwd: cwd)
        switch ask.state {
        case .allowed: return ask.kind == "question" ? "Answered" : "Allowed · \(what)"
        case .denied: return "Denied · \(what)"
        case .cancelled, .waiting: return "No longer waiting · \(what)"
        }
    }
}

private struct PermissionForm: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let cwd: String
    let listens: Bool
    @State private var showDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Type.body)
                .foregroundStyle(Ink.primary)
            detail
            HStack(spacing: 8) {
                Spacer()
                Button("Deny") { model.answer(ask, allow: false) }
                Button("Allow") { model.answer(ask, allow: true) }
                    .keyboardShortcut(listens ? .defaultAction : nil)
            }
            .controlSize(.regular)
            .tint(Color(white: 0.5))
        }
    }

    private var title: String {
        switch ask.tool {
        case "Bash": "Run a command?"
        case "Edit", "MultiEdit": "Edit \(path)?"
        case "Write": "Write \(path)?"
        case "ExitPlanMode": "Start on this plan?"
        case "WebFetch": "Fetch a page?"
        default: "Use \(ask.tool)?"
        }
    }

    private var path: String {
        ToolSummary.relative(ask.input["file_path"]?.string ?? "", to: cwd)
    }

    @ViewBuilder
    private var detail: some View {
        if ask.tool == "Bash" {
            Text(ask.input["command"]?.string ?? "")
                .font(Type.mono)
                .foregroundStyle(Ink.secondary)
                .textSelection(.enabled)
        } else if ask.tool == "ExitPlanMode", let plan = ask.input["plan"]?.string {
            ScrollView {
                Markdown(plan).markdownTheme(.glass)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        } else if let diff = Diff.of(tool: ask.tool, input: ask.input, cwd: cwd) {
            DisclosureGroup(isExpanded: $showDiff) {
                DiffLinesView(lines: diff.lines)
            } label: {
                HStack(spacing: 6) {
                    Text("+\(diff.added)").foregroundStyle(Ink.added)
                    Text("−\(diff.deleted)").foregroundStyle(Ink.deleted)
                }
                .font(Type.secondary)
            }
        } else if let url = ask.input["url"]?.string {
            Text(url)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        } else {
            Text(compact(ask.input))
                .font(Type.mono)
                .foregroundStyle(Ink.secondary)
                .lineLimit(6)
                .textSelection(.enabled)
        }
    }

    private func compact(_ input: JSON) -> String {
        guard let object = input.object else { return "" }
        return object.keys.sorted().map { key in
            let value = object[key].flatMap { $0.string ?? (try? String(decoding: $0.data(), as: UTF8.self)) } ?? ""
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }
}

private struct QuestionForm: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let listens: Bool
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    private var questions: [JSON] { ask.options?.array ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                let text = question["question"]?.string ?? ""
                let multiple = question["multiSelect"]?.bool ?? false
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(Type.body)
                        .foregroundStyle(Ink.primary)
                    ForEach(Array((question["options"]?.array ?? []).enumerated()), id: \.offset) { _, option in
                        let label = option["label"]?.string ?? ""
                        if multiple {
                            Toggle(isOn: binding(text, label)) {
                                optionLabel(label, option["description"]?.string)
                            }
                            .toggleStyle(.checkbox)
                        } else {
                            Button {
                                picked[text] = [label]
                                other[text] = nil
                                if questions.count == 1 { submit() }
                            } label: {
                                optionLabel(label, option["description"]?.string)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .tint(picked[text]?.contains(label) == true ? Ink.primary : nil)
                        }
                    }
                    TextField("Other", text: Binding(get: { other[text] ?? "" }, set: { other[text] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submit)
                }
            }
            HStack {
                Spacer()
                Button("Skip") { model.answer(ask, allow: false, message: AskCard.skipMessage) }
                if questions.count > 1 || questions.contains(where: { $0["multiSelect"]?.bool == true }) {
                    Button("Answer", action: submit)
                        .keyboardShortcut(listens ? .defaultAction : nil)
                        .disabled(!complete)
                }
            }
            .tint(Color(white: 0.5))
        }
    }

    private func optionLabel(_ label: String, _ description: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Type.body)
            if let description, !description.isEmpty {
                Text(description).font(Type.secondary).foregroundStyle(Ink.secondary)
            }
        }
    }

    private func binding(_ question: String, _ label: String) -> Binding<Bool> {
        Binding {
            picked[question]?.contains(label) ?? false
        } set: { on in
            var set = picked[question] ?? []
            if on { set.insert(label) } else { set.remove(label) }
            picked[question] = set
        }
    }

    private func answer(for question: String) -> String? {
        if let typed = other[question]?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { return typed }
        guard let set = picked[question], !set.isEmpty else { return nil }
        return set.sorted().joined(separator: ", ")
    }

    private var complete: Bool {
        questions.allSatisfy { answer(for: $0["question"]?.string ?? "") != nil }
    }

    private func submit() {
        guard complete else { return }
        var answers: [String: String] = [:]
        for question in questions {
            let text = question["question"]?.string ?? ""
            answers[text] = answer(for: text)
        }
        model.answer(ask, allow: true, answers: answers)
    }
}
