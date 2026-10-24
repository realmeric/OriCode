import MarkdownUI
import SwiftUI

/// Claude waiting on you: a permission for a tool, or a question with options.
struct AskCard: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let cwd: String
    /// The thread that asked, which an answer goes back to.
    var thread: UUID?
    /// Only the oldest waiting card takes Return and Esc.
    let listens: Bool

    static let skipMessage = "The user skipped the question. Carry on with your best judgement, and say what you assumed."

    var body: some View {
        if ask.state == .waiting {
            VStack(alignment: .leading, spacing: 10) {
                // A thread above this one answers first; the user can answer here all the same.
                if let line = model.heldLine(of: ask) {
                    HeldLine(text: line.text, hover: line.hover)
                }
                AskForm(ask: ask, cwd: cwd, thread: thread, listens: listens)
            }
                .padding(14)
                .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
        } else {
            Text(settledLine)
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ask.state == .cancelled ? "" : ask.answerReason ?? "")
                .transition(.opacity.animation(Motion.fade.delay(0.08)))
        }
    }

    private var settledLine: String {
        let what = ask.kind == "question" ? "Question" : ask.app.map { "See and use \($0)" } ?? ask.loosening ?? ToolSummary.line(for: ask.call, cwd: cwd)
        // Answered by the thread that set this one going, which the line names, its reason on hover.
        if let by = ask.answeredBy, ask.state != .cancelled {
            let done = ask.kind == "question" ? "\(by) answered" : ask.state == .allowed ? "\(by) allowed" : "\(by) denied"
            return "\(done) · \(what)"
        }
        switch ask.state {
        case .allowed: return ask.kind == "question" ? "Answered" : "Allowed · \(what)"
        case .denied: return "Denied · \(what)"
        case .cancelled, .waiting: return "No longer waiting · \(what)"
        }
    }
}

/// Who has an ask first, or who sent it up and why, over the ask in its card and in the queue.
struct HeldLine: View {
    let text: String
    var hover = ""

    var body: some View {
        Text(text)
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .help(hover)
    }
}

/// What an ask asks and its answers, in its thread's card or in the queue of everything waiting,
/// which is `compact`: the entry names who asks, and a long command or plan is cut short there.
struct AskForm: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let cwd: String
    let thread: UUID?
    let listens: Bool
    var compact = false
    /// Off on an agent's card, whose pulsing mark is the question: a command shows as its well
    /// and its answers. A question keeps its words, and an edit the file its title names.
    var titled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A head's worker asking, which the user answers here as the thread's own ask.
            if !compact, let worker = ask.worker {
                HStack(spacing: 5) {
                    AgentMark(agent: worker.agent)
                        .frame(width: 10, height: 10)
                    Text(worker.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
            }
            if ask.kind == "question" {
                QuestionForm(ask: ask, thread: thread, listens: listens)
            } else {
                PermissionForm(ask: ask, cwd: cwd, thread: thread, listens: listens, compact: compact, titled: titled || ask.toolKind != .run)
            }
        }
    }
}

private struct PermissionForm: View {
    @Environment(AppModel.self) private var model
    let ask: PendingAsk
    let cwd: String
    let thread: UUID?
    let listens: Bool
    let compact: Bool
    let titled: Bool
    @State private var showDiff = false
    @AppStorage(ReviewDesign.key) private var design = ReviewDesign.witness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if titled {
                Text(title)
                    .font(Type.body)
                    .foregroundStyle(Ink.primary)
                detail
            } else {
                // All of it, scrolling past the card's room, so Allow is never under a command cut short.
                ScrollView {
                    Text(ask.call.shown("command") ?? "")
                        .font(Type.mono)
                        .foregroundStyle(Ink.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                    .scrollIndicators(.never)
                    .frame(maxHeight: StageLayout.askTallest)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, StageLayout.wellPadding.height)
                    .padding(.horizontal, StageLayout.wellPadding.width)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10, style: .continuous))
            }
            HStack(spacing: 8) {
                Spacer()
                if ask.choices.isEmpty {
                    Button("Deny") { model.answer(ask, in: thread, allow: false) }
                        .buttonStyle(.action)
                    Button("Allow") { model.answer(ask, in: thread, allow: true) }
                        .buttonStyle(.action(prominent: listens))
                        .keyboardShortcut(listens ? .defaultAction : nil)
                } else {
                    // The agent's own answers, in its order, with the one Return gives last.
                    let main = ask.choices.first { $0.kind == "allow_once" } ?? ask.choices.first(where: \.allows)
                    ForEach(ask.choices.filter { $0 != main }, id: \.id) { choice in
                        Button(choice.name) { model.answer(ask, in: thread, allow: choice.allows, choice: choice) }
                            .buttonStyle(.action)
                            .help(choice.help ?? "")
                    }
                    if let main {
                        Button(main.name) { model.answer(ask, in: thread, allow: true, choice: main) }
                            .buttonStyle(.action(prominent: listens))
                            .help(main.help ?? "")
                            .keyboardShortcut(listens ? .defaultAction : nil)
                    }
                }
            }
        }
    }

    private var title: String {
        if let app = ask.app { return "Let this thread see and use \(app)?" }
        if let change = ask.loosening { return "\(change)?" }
        return switch ask.toolKind {
        case .run: "Run a command?"
        case .edit: "Edit \(path)?"
        case .write: "Write \(path)?"
        case .planning: "Start on this plan?"
        case .fetch: "Fetch a page?"
        default: "Use \(ask.tool)?"
        }
    }

    private var path: String {
        ToolSummary.relative(ask.call.file ?? "", to: cwd)
    }

    @ViewBuilder
    private var detail: some View {
        if ask.app != nil {
            Text("Until \(Build.name) quits.")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if ask.loosening != nil {
            Text(ask.input["reason"]?.string ?? "")
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if ask.toolKind == .run {
            // All of it, scrolling in the queue past four lines and a half, the half saying there's
            // more: Allow is never under a command cut short.
            whole(ask.call.shown("command") ?? "", tallest: compact ? 66 : nil)
        } else if ask.toolKind == .planning, let plan = ask.input["plan"]?.string {
            ScrollView {
                Markdown(plan).markdownTheme(.glass)
                    .environment(\.linkPointers, .of(plan))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // The plan scrolls in its own view, whose top edge nothing covers.
            .environment(\.codeCopyLine, 8)
            .frame(maxHeight: compact ? 160 : 320)
            .fixedSize(horizontal: false, vertical: true)
        } else if let diff = Diff.of(tool: ask.tool, input: ask.input, cwd: cwd) {
            DisclosureGroup(isExpanded: $showDiff) {
                if design == .witness {
                    // All of it, long lines wrapped, in a scroll view of its own: the edit
                    // hasn't been made, so there is no review to read the rest in.
                    ScrollView {
                        WitnessDiff(diff: diff, rows: nil)
                            .equatable()
                            .padding(.vertical, 10)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: compact ? 200 : 360)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    DiffLinesView(lines: diff.lines)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("+\(diff.added)").foregroundStyle(Ink.added)
                    Text("−\(diff.deleted)").foregroundStyle(Ink.deleted)
                }
                .font(Type.secondary)
            }
        } else if let url = ask.call.shown("url") {
            Text(url)
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
        } else {
            whole(compact(ask.input), tallest: compact ? 52 : 97)
        }
    }

    /// Mono text the user reads before allowing it, scrolling once it's taller than `tallest`.
    @ViewBuilder
    private func whole(_ text: String, tallest: CGFloat?) -> some View {
        let shown = Text(text)
            .font(Type.mono)
            .foregroundStyle(Ink.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let tallest {
            ScrollView { shown }
                .frame(maxHeight: tallest)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            shown
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
    let thread: UUID?
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
                    VStack(spacing: 2) {
                        ForEach(Array((question["options"]?.array ?? []).enumerated()), id: \.offset) { _, option in
                            let label = option["label"]?.string ?? ""
                            let lit = picked[text]?.contains(label) == true
                            if multiple {
                                // The whole lit row is the checkbox's, so the row takes the click
                                // and the box only shows it.
                                Button {
                                    withAnimation(Motion.fade) { binding(text, label).wrappedValue.toggle() }
                                } label: {
                                    OptionRow(lit: lit) {
                                        Toggle(isOn: binding(text, label)) {
                                            optionLabel(label, option["description"]?.string)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .toggleStyle(.checkbox)
                                        .allowsHitTesting(false)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(lit ? .isSelected : [])
                            } else {
                                Button {
                                    withAnimation(Motion.fade) {
                                        picked[text] = [label]
                                        other[text] = nil
                                    }
                                    if questions.count == 1 { submit() }
                                } label: {
                                    OptionRow(lit: lit) {
                                        HStack(alignment: .firstTextBaseline) {
                                            optionLabel(label, option["description"]?.string)
                                            Spacer(minLength: 12)
                                            if lit {
                                                Image(systemName: "checkmark")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(Ink.primary)
                                            }
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(lit ? .isSelected : [])
                            }
                        }
                        OtherField(text: Binding(get: { other[text] ?? "" }, set: { typed in
                            other[text] = typed
                            // What's typed is the answer, so no option stays lit beside it.
                            if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, picked[text] != nil {
                                withAnimation(Motion.fade) { picked[text] = nil }
                            }
                        }), submit: submit)
                    }
                    // The rows' light reaches past the column, so their words line up with the question's.
                    .padding(.horizontal, -10)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Skip") { model.answer(ask, in: thread, allow: false, message: AskCard.skipMessage) }
                    .buttonStyle(.action)
                if questions.count > 1 || questions.contains(where: { $0["multiSelect"]?.bool == true }) {
                    Button("Answer", action: submit)
                        .buttonStyle(.action(prominent: listens))
                        .keyboardShortcut(listens ? .defaultAction : nil)
                        .disabled(!complete)
                }
            }
        }
    }

    private func optionLabel(_ label: String, _ description: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Type.body).foregroundStyle(Ink.primary)
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
            if on { other[question] = nil }
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
        model.answer(ask, in: thread, allow: true, answers: answers)
    }
}

/// An option's row: lit while it's picked, so the choice reads at a glance, and lit less under the pointer.
private struct OptionRow<Content: View>: View {
    let lit: Bool
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(lit ? Surface.selected : hovering ? Surface.hover : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
            .onHover { hovering = $0 }
    }
}

/// Other, as one more row of the options: a field on the card's own tint, fainter than a picked
/// option so it never passes for one, and lit like one under the pointer, while you type and
/// while it holds the answer.
private struct OtherField: View {
    @Binding var text: String
    let submit: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let lit = hovering || focused || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        TextField("Other", text: $text)
            .textFieldStyle(.plain)
            .font(Type.body)
            .foregroundStyle(Ink.primary)
            .focused($focused)
            .onSubmit(submit)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(lit ? Surface.selected : Surface.card, in: .rect(cornerRadius: 10, style: .continuous))
            .onHover { hovering = $0 }
            .animation(Motion.fade, value: lit)
            .padding(.top, 4)
    }
}
