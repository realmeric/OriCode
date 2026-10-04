import SwiftUI

/// A question asked beside the open thread, and its answer. Neither joins the thread: the engine
/// answers from a copy of the thread's session that it never saves.
struct SideAnswer {
    var id = UUID()
    var thread: UUID?
    var question = ""
    var text = ""
    var running = false
    var problem: String?
}

extension AppModel {
    /// Why the open thread can't be asked a side question, or nil when it can.
    var sideUnavailable: String? {
        guard let chat else { return "Open a thread first" }
        guard agent(for: chat).capabilities.aside == true else { return "\(agent(for: chat).name) has no side questions" }
        return chat.sessionId == nil ? "Send it a message first" : nil
    }

    /// ⌘⇧A: the side question grows out of the capsule, and folds back with what it was asked.
    func toggleSide() {
        if sideShown {
            closeSide()
            return
        }
        if let why = sideUnavailable {
            say(why)
            return
        }
        // Another thread's question isn't this one's.
        if side.thread != chat?.id { side = SideAnswer(thread: chat?.id) }
        withAnimation(Motion.move) { openInIsland(.side) }
    }

    func closeSide() {
        stopSide()
        withAnimation(Motion.move) { sideShown = false }
    }

    func askSide(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let chat, let session = chat.sessionId else { return }
        let asked = SideAnswer(thread: chat.id, question: question, running: true)
        side = asked
        var params: [String: JSON] = [
            "threadId": .string(chat.id.uuidString), "sessionId": .string(session), "cwd": .string(chat.cwd), "text": .string(question),
        ]
        // The thread's own model, so the question reads the prompt the thread has cached.
        if let model = modelSent(in: chat) { params["model"] = .string(model) }
        Task {
            do {
                let reply = try await engine.request("side", .object(params.naming(chat.providerID)))
                guard side.id == asked.id else { return }
                if let text = reply["text"]?.string, !text.isEmpty { side.text = text }
            } catch {
                guard side.id == asked.id else { return }
                side.problem = error.localizedDescription
            }
            side.running = false
        }
    }

    func stopSide() {
        guard side.running, let thread = side.thread else { return }
        side.running = false
        side.id = UUID()
        Task { _ = try? await engine.request("side.stop", ["threadId": .string(thread.uuidString)]) }
    }

    /// The answer as it streams.
    func sideStreamed(_ delta: String, thread: UUID) {
        guard side.running, side.thread == thread else { return }
        side.text += delta
    }
}

/// The side question's surface: a field, then the answer under what was asked.
struct SideQuestion: View {
    static let width: CGFloat = 560
    private static let header: CGFloat = 41
    @Environment(AppModel.self) private var model
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let side = model.side
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                TextField("Ask on the side", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(Ink.primary)
                    .focused($focused)
                    .onSubmit {
                        model.askSide(draft)
                        draft = ""
                    }
                if side.running {
                    ProgressView().controlSize(.small).tint(Ink.secondary)
                    Button("Stop") { model.stopSide() }
                        .buttonStyle(.action(small: true))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Self.header)
            if !side.question.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(side.question)
                            .font(Type.secondary)
                            .foregroundStyle(Ink.secondary)
                            .textSelection(.enabled)
                        if let problem = side.problem {
                            Text(problem)
                                .font(Type.secondary)
                                .foregroundStyle(Ink.secondary)
                        } else if !side.text.isEmpty {
                            Reply(id: side.id, text: side.text, live: side.running)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Answered from what this thread knows. Neither the question nor the answer joins it.")
                    .font(Type.secondary)
                    .foregroundStyle(Ink.faint)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
    }
}
