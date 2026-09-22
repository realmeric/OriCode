import Foundation

extension AppModel {
    func conversation(for chat: Chat) -> Conversation {
        if let existing = conversations[chat.id] { return existing }
        let created = Conversation(chat: chat, context: context)
        conversations[chat.id] = created
        return created
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let chat = chat ?? newChat() else { return }
        let conversation = conversation(for: chat)
        guard !conversation.running else { return }
        conversation.userSent(trimmed)
        var params: [String: JSON] = [
            "threadId": .string(chat.id.uuidString),
            "cwd": .string(chat.cwd),
            "text": .string(trimmed),
            "permissionMode": .string(chat.permissionMode),
        ]
        if let sessionId = chat.sessionId { params["sessionId"] = .string(sessionId) }
        if let model = chat.model { params["model"] = .string(model) }
        if let effort = chat.effort { params["effort"] = .string(effort) }
        Task {
            do {
                _ = try await engine.request("send", .object(params))
            } catch {
                conversation.sendFailed(error.localizedDescription)
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
        if let conversation = conversations[id] {
            conversation.receive(event)
        } else if let chat = try? context.fetch(.init(predicate: #Predicate<Chat> { $0.id == id })).first {
            conversation(for: chat).receive(event)
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
