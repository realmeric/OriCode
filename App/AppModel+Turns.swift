import AppKit
import Foundation

extension AppModel {
    /// The selected thread's transcript, for views. Views only read; the conversation is
    /// created when the thread is selected, because creating it inside a view update
    /// mutates observed state mid-render and SwiftUI aborts.
    var currentConversation: Conversation? {
        selectedChatID.flatMap { conversations[$0] }
    }

    func conversation(for chat: Chat) -> Conversation {
        if let existing = conversations[chat.id] { return existing }
        let created = Conversation(chat: chat, context: context)
        conversations[chat.id] = created
        return created
    }

    func send(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftAttachments
        guard !trimmed.isEmpty || !images.isEmpty, let chat = chat ?? newChat() else { return }
        let conversation = conversation(for: chat)
        guard !conversation.running else { return }
        if trimmed.isEmpty { trimmed = "What's in \(images.count == 1 ? "this image" : "these images")?" }
        draftAttachments = []
        conversation.userSent(trimmed, previews: images.compactMap(\.preview))
        var params: [String: JSON] = [
            "threadId": .string(chat.id.uuidString),
            "cwd": .string(chat.cwd),
            "text": .string(trimmed),
            "permissionMode": .string(chat.permissionMode),
            "costSoFar": .number(chat.costUSD),
        ]
        if let sessionId = chat.sessionId { params["sessionId"] = .string(sessionId) }
        if let model = chat.model { params["model"] = .string(model) }
        if let effort = chat.effort { params["effort"] = .string(effort) }
        if !images.isEmpty {
            params["attachments"] = .array(images.map {
                ["mediaType": .string($0.mediaType), "data": .string($0.data.base64EncodedString())]
            })
        }
        Task {
            do {
                _ = try await engine.request("send", .object(params))
            } catch {
                conversation.sendFailed(error.localizedDescription)
            }
        }
    }

    func answer(_ ask: PendingAsk, allow: Bool, answers: [String: String]? = nil, message: String? = nil) {
        guard let chat else { return }
        var params: [String: JSON] = ["requestId": .string(ask.requestId), "allow": .bool(allow)]
        if let answers { params["answers"] = .object(answers.mapValues(JSON.string)) }
        if !allow {
            params["message"] = .string(message ?? "The user denied this. Tell them you stopped, and wait for what they want instead.")
        }
        conversation(for: chat).answered(ask.requestId, allow: allow)
        Task {
            do {
                _ = try await engine.request("answer", .object(params))
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard let chat else { return }
        Task { _ = try? await engine.request("interrupt", ["threadId": .string(chat.id.uuidString)]) }
    }

    func route(_ event: EngineEvent) {
        guard let threadId = event.threadId, let id = UUID(uuidString: threadId) else {
            if event.name == "error", let message = event.body["message"]?.string {
                say(message)
            }
            return
        }
        guard let chat = try? context.fetch(.init(predicate: #Predicate<Chat> { $0.id == id })).first else { return }
        conversation(for: chat).receive(event)
        tellIfAway(event, chat: chat)
        if event.name == "turn.done" {
            refreshBranch(for: chat)
            refreshUsage(fresh: true)
        }
    }

    /// A turn that ends or asks while OriCode isn't the window you're in gets one notification.
    private func tellIfAway(_ event: EngineEvent, chat: Chat) {
        notifier.badge(conversations.values.count { $0.waitingAsk != nil })
        guard event.name == "turn.done" || event.name == "ask" else { return }
        let away = !NSApp.isActive || chat.id != selectedChatID
        guard away else { return }
        if event.name == "ask" {
            let tool = event.body["tool"]?.string ?? ""
            let summary = event.body["kind"]?.string == "question"
                ? "Claude has a question for you."
                : "Waiting on you: " + ToolSummary.line(for: ToolCall(toolUseId: "", name: tool, input: event.body["input"] ?? .null), cwd: chat.cwd)
            notifier.post(title: chat.title, body: summary, chatID: chat.id)
        } else if event.body["stopReason"]?.string != "interrupted" {
            notifier.post(title: chat.title, body: "Finished.", chatID: chat.id)
        }
    }

    func engineStopped() {
        for conversation in conversations.values where conversation.running {
            conversation.stopped()
            conversation.note("The engine stopped in the middle of this turn.")
        }
    }
}

extension AppModel {
    func setModel(_ id: String, for chat: Chat?) {
        lastModel = id
        guard let chat else { return }
        chat.model = id
        if let efforts = models.first(where: { $0.id == id })?.efforts, let effort = chat.effort, !efforts.contains(effort) {
            chat.effort = nil
        }
        save()
    }

    func setEffort(_ effort: String?, for chat: Chat?) {
        lastEffort = effort
        guard let chat else { return }
        chat.effort = effort
        save()
    }

    func setPermissionMode(_ mode: String, for chat: Chat?) {
        lastPermissionMode = mode
        guard let chat else { return }
        chat.permissionMode = mode
        save()
        let running = conversation(for: chat).running
        Task {
            let reply = try? await engine.request("setMode", ["threadId": .string(chat.id.uuidString), "permissionMode": .string(mode)])
            if running, reply?["applied"]?.bool == false {
                modeNote = "from the next reply"
                try? await Task.sleep(for: .seconds(2))
                modeNote = nil
            }
        }
    }
}
