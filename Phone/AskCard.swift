import Link
import SwiftUI

/// An ask waiting on you, as the Mac's queue has it: who asks, what it asks, and its answers. A
/// permission's Deny and Allow, or the agent's own choices; a question's options, several of them
/// for a question that takes several, and Other to type.
struct AskCard: View {
    @Environment(PhoneClient.self) private var store
    let ask: AskInfo
    /// On home, the asking thread's badge and title head the card.
    var named = true
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var sentAt = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if named, let thread = store.threads[ask.thread] {
                HStack(spacing: 8) {
                    Badge(project: store.projects[thread.project])
                    Text(thread.title)
                        .font(.subheadline)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(1)
                }
            }
            if let worker = ask.worker {
                Text(worker)
                    .font(.footnote)
                    .foregroundStyle(Ink.faint)
                    .lineLimit(1)
            }
            if ask.isQuestion {
                questions
            } else {
                permission
            }
            if let refused = refusal {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    if !refused.isEmpty { Text(refused) }
                }
                .font(.footnote)
                .foregroundStyle(Ink.red)
            }
        }
        .padding(14)
        .background(Ink.asking, in: .rect(cornerRadius: 14, style: .continuous))
        .opacity(waiting ? 0.5 : 1)
        .disabled(waiting)
        .sensoryFeedback(.impact(weight: .light), trigger: sentAt)
    }

    /// An answer sent for this ask that the Mac hasn't taken or refused yet.
    private var answer: PhoneClient.Sent? {
        store.sent.values.filter {
            if case .answer(let id, _, _, _, _, _) = $0.action { id == ask.id } else { false }
        }.max { $0.at < $1.at }
    }

    private var waiting: Bool { answer?.state == .waiting && answer?.undelivered() == false }

    private var refusal: String? {
        guard let answer, answer.undelivered() else { return nil }
        if case .refused(let reason) = answer.state { return reason }
        return ""
    }

    private func send(allow: Bool, choice: String? = nil, answers: [String: String]? = nil, message: String? = nil) {
        if let old = answer { store.clear(old.id) }
        store.send(.answer(ask: ask.id, thread: ask.thread, allow: allow, choice: choice, answers: answers, message: message))
        sentAt += 1
    }

    // MARK: Permission

    private var permission: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.title)
                .font(.body)
                .foregroundStyle(Ink.primary)
            if let detail = ask.detail {
                Text(detail)
                    .font(ask.code ? .system(.footnote, design: .monospaced) : .subheadline)
                    .foregroundStyle(Ink.secondary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer()
                if ask.choices.isEmpty {
                    Button("Deny") { send(allow: false) }
                        .buttonStyle(.glass)
                    Button("Allow") { send(allow: true) }
                        .lit()
                } else {
                    let main = ask.choices.first { $0.allows }
                    ForEach(ask.choices.filter { $0 != main }, id: \.id) { choice in
                        Button(choice.name) { send(allow: choice.allows, choice: choice.id) }
                            .buttonStyle(.glass)
                    }
                    if let main {
                        Button(main.name) { send(allow: true, choice: main.id) }
                            .lit()
                    }
                }
            }
            .controlSize(.regular)
        }
    }

    // MARK: Question

    private var questions: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(ask.questions.enumerated()), id: \.offset) { _, question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.text)
                        .font(.body)
                        .foregroundStyle(Ink.primary)
                        .padding(.bottom, 2)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        let lit = picked[question.text]?.contains(option.label) == true
                        Button {
                            pick(option.label, in: question)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).foregroundStyle(Ink.primary)
                                    if let detail = option.detail, !detail.isEmpty {
                                        Text(detail).font(.footnote).foregroundStyle(Ink.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if lit { Image(systemName: "checkmark").foregroundStyle(Ink.primary) }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(lit ? Color.white.opacity(0.12) : Ink.card, in: .rect(cornerRadius: 10, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(lit ? .isSelected : [])
                    }
                    TextField("Other", text: Binding(get: { other[question.text] ?? "" }, set: { typed in
                        other[question.text] = typed
                        if !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { picked[question.text] = nil }
                    }))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Ink.card, in: .rect(cornerRadius: 10, style: .continuous))
                    .submitLabel(.send)
                    .onSubmit(submit)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Skip") { send(allow: false, message: Self.skipped) }
                    .buttonStyle(.glass)
                if needsAnswerButton {
                    Button("Answer", action: submit)
                        .lit()
                        .disabled(!complete)
                }
            }
        }
    }

    /// What the Mac's card tells an agent whose question was skipped.
    static let skipped = "The user skipped the question. Carry on with your best judgement, and say what you assumed."

    private var needsAnswerButton: Bool {
        ask.questions.count > 1 || ask.questions.contains(where: \.multiple)
    }

    private func pick(_ label: String, in question: AskInfo.Question) {
        other[question.text] = nil
        if question.multiple {
            var set = picked[question.text] ?? []
            if set.contains(label) { set.remove(label) } else { set.insert(label) }
            picked[question.text] = set
        } else {
            picked[question.text] = [label]
            if ask.questions.count == 1 { submit() }
        }
    }

    private func answer(for question: String) -> String? {
        if let typed = other[question]?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { return typed }
        guard let set = picked[question], !set.isEmpty else { return nil }
        return set.sorted().joined(separator: ", ")
    }

    private var complete: Bool {
        ask.questions.allSatisfy { answer(for: $0.text) != nil }
    }

    private func submit() {
        guard complete else { return }
        send(allow: true, answers: Dictionary(uniqueKeysWithValues: ask.questions.map { ($0.text, answer(for: $0.text) ?? "") }))
    }
}
