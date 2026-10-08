import AppKit
import SwiftData
import SwiftUI

extension AppModel {
    /// The selected thread's transcript, for views. Views only read; the conversation is
    /// created when the thread is selected, because creating it inside a view update
    /// mutates observed state mid-render and SwiftUI aborts.
    var currentConversation: Conversation? {
        selectedChatID.flatMap { conversations[$0] }
    }

    /// A conversation not open, not running, not waiting on you and holding no messages is dropped
    /// from memory; reopening it reads it back off the main thread.
    func letGo(_ id: UUID) {
        guard id != selectedChatID, let conversation = conversations[id], !conversation.working, conversation.waitingAsk == nil,
              !conversation.waitingAfterQuit, !conversation.holdsMessages
        else { return }
        conversation.flush()
        conversations[id] = nil
    }

    /// Lets the thread just left go once it has been away `awayLimit`, so memory stays flat however
    /// many threads are browsed. One that's running then goes on its `released` event instead.
    func letGoSoon(_ id: UUID) {
        guard conversations[id] != nil else { return }
        leaving[id]?.cancel()
        // Weakly, so a model that's gone isn't kept alive by the wait.
        leaving[id] = Task { [weak self, awayLimit] in
            try? await Task.sleep(for: awayLimit)
            guard !Task.isCancelled, let self else { return }
            leaving[id] = nil
            letGo(id)
        }
    }

    func conversation(for chat: Chat) -> Conversation {
        if let existing = conversations[chat.id] { return existing }
        let created = Conversation(chat: chat, context: context, said: said, pictures: SentPictures.standard)
        conversations[chat.id] = created
        return created
    }

    /// Starts a turn with what's typed, or sends it into the one running; false when it did
    /// neither, so the composer keeps the text.
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftAttachments
        guard !trimmed.isEmpty || !images.isEmpty, let chat = chat ?? newChat() else { return false }
        let conversation = conversation(for: chat)
        // Waiting on you from before a quit, the thread has no CLI to send into.
        guard !conversation.waitingAfterQuit else { return false }
        if conversation.running || !conversation.waiting.isEmpty {
            // An agent that can't take a message mid-turn gets it after the turn, as ⌥Return would.
            guard agent(for: chat).capabilities.steer else {
                conversation.enqueue(trimmed, images: images)
                draftAttachments = []
                return true
            }
            sendIntoTurn(conversation.sentIntoTurn(Self.asked(trimmed, images), typed: trimmed, images: images), in: chat)
        } else {
            guard send(trimmed, images: images, in: chat) else { return false }
        }
        draftAttachments = []
        conversation.sentByHand()
        return true
    }

    /// A queued message sent into the running turn instead of after it, or as a turn of its own
    /// when none runs; an agent that can't take one mid-turn keeps it queued.
    func sendQueuedNow(_ id: UUID) {
        guard let chat, let conversation = currentConversation, let message = conversation.queue.first(where: { $0.id == id }) else { return }
        // Waiting on you from before a quit, the thread has no CLI to send into.
        guard !conversation.waitingAfterQuit else { return }
        if conversation.running || !conversation.waiting.isEmpty {
            guard agent(for: chat).capabilities.steer else { return }
            conversation.removeQueued(id)
            sendIntoTurn(conversation.sentIntoTurn(Self.asked(message.text, message.images), typed: message.text, images: message.images), in: chat)
        } else {
            guard !heldInBlock(chat) else { return }
            conversation.removeQueued(id)
            _ = send(message.text, images: message.images, in: chat)
        }
        conversation.sentByHand()
    }

    /// ⌥Return: while the thread works, what's typed waits in its queue to go out once the turn
    /// ends; false when there's nothing to queue or no turn to wait for.
    @discardableResult
    func queue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = draftAttachments
        guard !trimmed.isEmpty || !images.isEmpty, let conversation = currentConversation,
              conversation.running || !conversation.waiting.isEmpty
        else { return false }
        conversation.enqueue(trimmed, images: images)
        draftAttachments = []
        return true
    }

    /// Starts a turn in any thread, on screen or not.
    func send(_ text: String, images: [ImageAttachment], in chat: Chat) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return false }
        let conversation = conversation(for: chat)
        guard !conversation.running, !heldInBlock(chat) else { return false }
        let text = Self.asked(trimmed, images)
        // Only the pictures with a preview show, so only they are kept, and in the bubble's order.
        let shown = images.compactMap { image in image.preview.map { (image: image, preview: $0) } }
        let id = UUID()
        conversation.userSent(text, previews: shown.map { $0.preview }, id: id)
        conversation.pictures?.keep(shown.map { $0.image }, thread: chat.id, message: id)
        startTurn(in: chat, text: text, images: images)
        return true
    }

    /// What goes out: what was typed, or for images alone a question about them.
    private static func asked(_ typed: String, _ images: [ImageAttachment]) -> String {
        typed.isEmpty ? "What's in \(images.count == 1 ? "this image" : "these images")?" : typed
    }

    /// Hands a message the transcript already shows, or one it needn't, to the thread's session
    /// with the thread's model, level, mode and speed.
    func startTurn(in chat: Chat, text: String, images: [ImageAttachment] = [], allowing grant: PendingAsk? = nil) {
        let conversation = conversation(for: chat)
        holdWhileWorking()
        // The commands run from the shell prompt since Claude last read them go first.
        let (text, readShells) = withShells(text, in: chat)
        // No folder's own folder is the app's to keep there, whatever emptied the support folder.
        if chat.project?.isNoFolder == true { try? FileManager.default.createDirectory(atPath: chat.cwd, withIntermediateDirectories: true) }
        var params = sendParams(in: chat, text: text, images: images)
        if let handover = handover(for: chat) { params["handover"] = .string(handover) }
        if let grant { params["grant"] = ["tool": .string(grant.tool), "input": grant.input] }
        Task {
            do {
                _ = try await engine.request("send", .object(params))
                readShells()
            } catch {
                conversation.sendFailed(error.localizedDescription)
                holdWhileWorking()
                // A queued message the engine turned down ends the thread's work, and the turn
                // before it held back its Finished for it.
                if isAway(chat) { notifier.post(title: chat.title, body: error.localizedDescription, chatID: chat.id) }
            }
        }
    }

    /// The thread so far, for the session a change of agent starts: everything before the message
    /// just sent, until a turn on the new agent has begun.
    func handover(for chat: Chat) -> String? {
        guard chat.handover, chat.sessionId == nil else { return nil }
        let items = conversation(for: chat).items
        let text = Handover.text(from: Array(items[..<(items.lastIndex(where: \.startsTurn) ?? items.endIndex)]), cwd: chat.cwd)
        return text.isEmpty ? nil : text
    }

    /// A message for the running turn, which Claude takes up at its next step. The engine sends
    /// it with the thread's settings, which only the next turn takes.
    private func sendIntoTurn(_ message: WaitingMessage, in chat: Chat) {
        let conversation = conversation(for: chat)
        // A message into the turn is the next one too, so the shell's new blocks go with it. They
        // count as read once Claude takes it up; handed back, they go with the next message.
        let (text, readShells) = withShells(message.text, in: chat)
        shellReads[message.id] = readShells
        var params = sendParams(in: chat, text: text, images: message.images)
        params["id"] = .string(message.id.uuidString)
        Task {
            do {
                // Whether it waits or the turn had ended and it started one, the engine says when
                // it's taken up with message.taken. That event comes after the ended turn's
                // turn.done, where this reply could arrive before it.
                _ = try await engine.request("send", .object(params))
            } catch {
                shellReads[message.id] = nil
                withAnimation(Motion.fade) { conversation.handBack(message.id) }
                conversation.note(error.localizedDescription)
                holdWhileWorking()
            }
        }
    }

    func sendParams(in chat: Chat, text: String, images: [ImageAttachment]) -> [String: JSON] {
        var params: [String: JSON] = [
            "threadId": .string(chat.id.uuidString),
            "cwd": .string(chat.cwd),
            "text": .string(text),
            "permissionMode": .string(chat.permissionMode),
            // The thread's cost has its workers' in it, which its own session never spent.
            "costSoFar": .number(chat.costUSD - conversation(for: chat).workerCost),
        ]
        // Each as agent/model, Claude's too, where the stored form leaves Claude's agent out.
        let rays = rays(for: chat)
        if !rays.isEmpty { params["rays"] = .array(rays.map { .string("\($0.provider)/\($0.id)") }) }
        if let sessionId = chat.sessionId { params["sessionId"] = .string(sessionId) }
        if let model = modelSent(in: chat) { params["model"] = .string(model) }
        // Only a level the model has now, the way the picker shows it.
        if let effort = chat.effort, option(for: chat)?.efforts.contains(effort) ?? true { params["effort"] = .string(effort) }
        params["fast"] = .bool(fastMode(of: chat))
        if UserDefaults.standard.bool(forKey: TranscriptSettings.concise) { params["concise"] = true }
        // The engine tells the session its folder is nobody's project.
        if chat.project?.isNoFolder == true { params["noFolder"] = true }
        if workflows(of: chat) { params["workflows"] = true }
        // A thread another opened is left without open_thread.
        if chat.openedBy != nil { params["opened"] = true }
        if !images.isEmpty {
            params["attachments"] = .array(images.map {
                ["mediaType": .string($0.mediaType), "data": .string($0.data.base64EncodedString())]
            })
        }
        return params.naming(chat.providerID)
    }

    /// The model a send names: the thread's own, or on another agent the one its composer shows,
    /// since what pi picks for itself could be a model it reaches through a login its maker
    /// forbids. A Claude thread with none leaves it to Claude Code, as it always has.
    func modelSent(in chat: Chat) -> String? {
        chat.model ?? (chat.providerID == ProviderInfo.claudeID ? nil : option(for: chat)?.id)
    }

    /// `choice` is one of the agent's own answers, which it gets back by its id.
    func answer(_ ask: PendingAsk, allow: Bool, answers: [String: String]? = nil, message: String? = nil, choice: PendingAsk.Choice? = nil) {
        guard let chat else { return }
        if conversation(for: chat).askedBeforeQuit.contains(ask.requestId) {
            answerAfterQuit(ask, in: chat, allow: allow, answers: answers, message: message)
            return
        }
        let params = Self.answerParams(ask, allow: allow, answers: answers, message: message, choice: choice)
        // The card folds into its one line and what's under it closes up, rather than jumping.
        withAnimation(Motion.move) { conversation(for: chat).answered(ask.requestId, allow: allow) }
        Task {
            do {
                _ = try await engine.request("answer", params)
            } catch {
                say(error.localizedDescription)
            }
        }
    }

    static func answerParams(_ ask: PendingAsk, allow: Bool, answers: [String: String]?, message: String?, choice: PendingAsk.Choice?) -> JSON {
        var params: [String: JSON] = ["requestId": .string(ask.requestId), "allow": .bool(allow)]
        if let answers { params["answers"] = .object(answers.mapValues(JSON.string)) }
        if !allow {
            params["message"] = .string(message ?? deniedMessage)
        }
        if let choice { params["optionId"] = .string(choice.id) }
        return .object(params)
    }

    /// Stop ends the turn and takes back everything still to go: the engine cancels what was sent
    /// into the turn, and the queue goes back now, not when the turn ends, since a turn already
    /// ending by itself as the interrupt goes out would still send its next.
    func stop() {
        guard let chat else { return }
        let conversation = conversation(for: chat)
        conversation.handBackQueue()
        if conversation.waitingAfterQuit {
            withAnimation(Motion.move) { conversation.stopAfterQuit() }
            holdWhileWorking()
            notifier.badge(conversations.values.count { $0.waitingAsk != nil })
            return
        }
        Task { _ = try? await engine.request("interrupt", ["threadId": .string(chat.id.uuidString)]) }
    }

    func route(_ event: EngineEvent) {
        if event.name == "fast", let state = event.body["state"]?.string {
            // A check names its model; a thread's own CLI speaks for the model the thread is on.
            let chat = event.threadId.flatMap(UUID.init(uuidString:)).flatMap(chat(withID:))
            let modelID = event.body["model"]?.string ?? chat?.model ?? ModelOption.claudeDefault
            fastReadings[ModelRef(provider: providerID(for: chat), id: modelID).stored] = FastReading(state: state, reason: event.body["reason"]?.string)
        }
        guard let threadId = event.threadId, let id = UUID(uuidString: threadId) else {
            if event.name == "error", let message = event.body["message"]?.string {
                say(message)
            }
            // Hello answered from the login it remembered, and asking the CLI again found none.
            if event.name == "provider", let found = try? event.body.decode(ProviderInfo.self) {
                if engineState == .ready { checked(found) } else { earlyProviders.append(found) }
            }
            // The same models as hello's, now with each one's default effort and workflows; or
            // another agent's, which names it.
            if event.name == "models", let list = try? event.body["models"]?.decode([ModelOption].self), !list.isEmpty {
                if let agent = event.body["provider"]?.string, agent != ProviderInfo.claudeID {
                    modelsByAgent[agent] = list
                    return
                }
                // A list whose workflows nothing answered for says no workflows anywhere; that's
                // not a no, so workflows stay assumed.
                let known = event.body["ultraKnown"]?.bool ?? true
                models = known ? list : list.map(\.assumingWorkflows)
                settingsEffort = event.body["settingsEffort"]?.string
            }
            return
        }
        if event.name == "side" {
            if let delta = event.body["delta"]?.string { sideStreamed(delta, thread: id) }
            return
        }
        // The engine let an idle thread's CLI go; its transcript can go too unless it's open.
        if event.name == "released" {
            letGo(id)
            return
        }
        // A tool of OriCode's own asks the app for something, a thread opened say, and waits.
        if Self.asks.contains(event.name) {
            answerTool(event, from: id)
            return
        }
        guard let chat = chat(withID: id) else { return }
        if event.name.hasPrefix("message.") {
            // A message taken up brightens in place; one handed back fades out.
            withAnimation(Motion.fade) { conversation(for: chat).receive(event) }
            if let message = event.body["messageId"]?.string.flatMap(UUID.init(uuidString:)),
               let readShells = shellReads.removeValue(forKey: message), event.name == "message.taken" {
                readShells()
            }
        } else {
            conversation(for: chat).receive(event)
        }
        // On screen or not, a turn that ended by itself lets the thread's queue send its next, and
        // so does the last message it left waiting going back.
        if event.name == "turn.done" || event.name == "message.cancelled" {
            conversation(for: chat).sendNext { send($0.text, images: $0.images, in: chat) }
        }
        holdWhileWorking()
        tellIfAway(event, chat: chat)
        if event.name == "limited" { scheduleResumes() }
        if event.name == "limits" { takeLimits(event.body, for: chat.providerID) }
        if event.name == "turn.done" {
            tellOpener(of: chat)
            pushedMaybe(in: chat.cwd)
            refreshBranch(for: chat)
        }
        // The count at the top right follows every turn in the open folder, and an open review
        // follows every edit.
        if chat.cwd == self.chat?.cwd, event.name == "turn.done" || (reviewShown && event.name == "tool.result") {
            readReview(after: .milliseconds(event.name == "turn.done" ? 200 : 500))
        }
    }

    /// A thread by its id: the one its conversation holds, or from the store.
    func chat(withID id: UUID) -> Chat? {
        conversations[id]?.chat ?? (try? context.fetch(.init(predicate: #Predicate<Chat> { $0.id == id })).first)
    }

    /// A turn that ends or asks while OriCode isn't the window you're in gets one notification.
    private func tellIfAway(_ event: EngineEvent, chat: Chat) {
        notifier.badge(conversations.values.count { $0.waitingAsk != nil })
        guard event.name == "turn.done" || event.name == "ask", isAway(chat) else { return }
        if event.name == "ask" {
            let tool = event.body["tool"]?.string ?? ""
            let summary = event.body["kind"]?.string == "question"
                ? "A question for you."
                : "Waiting on you: " + ToolSummary.line(for: ToolCall(
                    toolUseId: "", name: tool, input: event.body["input"] ?? .null,
                    declared: ToolKind(event.body["toolKind"], tool: tool), view: event.body["view"] ?? .null), cwd: chat.cwd)
            notifier.post(title: chat.title, body: summary, chatID: chat.id)
        } else if let limit = conversation(for: chat).turnLimit {
            let when = chat.resumeAt.map { "It goes on at \(Limit.time($0))." } ?? "Resets at \(Limit.time(limit.resetsAt))."
            notifier.post(title: chat.title, body: "Stopped at \(agent(for: chat).agent)'s \(Limit.name(of: limit.window)). " + when, chatID: chat.id)
        } else if event.body["stopReason"]?.string != "interrupted",
                  // A thread still working, on the messages its turn left waiting or its queue's
                  // next, isn't finished: Finished comes when the last one ends.
                  conversations[chat.id]?.running != true {
            notifier.post(title: chat.title, body: "Finished.", chatID: chat.id)
        }
    }

    private func isAway(_ chat: Chat) -> Bool {
        !NSApp.isActive || chat.id != selectedChatID
    }

    /// Tells the engine whether any thread's turn is running, for App Nap.
    func holdWhileWorking() {
        let busy = conversations.values.contains { $0.running }
        guard busy != holdingForTurns else { return }
        holdingForTurns = busy
        Task { await engine.hold(busy) }
    }

    /// What went with the engine, whether it died or was restarted: every thread's turn, tasks and
    /// workflows.
    func engineStopped() {
        // A thread waiting on you from before a quit has no CLI to lose.
        for conversation in conversations.values where !conversation.waitingAfterQuit {
            let midTurn = conversation.running
            conversation.stopped()
            if midTurn { conversation.note("The engine stopped in the middle of this turn.") }
        }
        for conversation in conversations.values { conversation.endWorkflows() }
        // A new engine watches nothing until it's asked again.
        headsWatched = nil
        // Whatever was sent into a turn went with the engine; it goes back to the composer.
        shellReads = [:]
        for conversation in conversations.values { withAnimation(Motion.fade) { conversation.handBackAll() } }
        holdWhileWorking()
    }
}

extension AppModel {
    /// With no thread open, a pick is for the thread about to start, and a default fixed in
    /// Settings would win over it there; so that thread starts now, empty, with the pick. Another
    /// agent's model moves a thread to that agent while it's a draft, and never after.
    func setModel(_ ref: ModelRef, for chat: Chat?) {
        guard chat.map({ canMoveAgent($0) || $0.providerID == ref.provider }) ?? true else { return }
        lastProvider = ref.provider
        lastModel = ref
        guard let chat = chat ?? (ref.provider == startingProvider && ref.id == startingModel ? nil : newChat()) else { return }
        let moved = chat.providerID != ref.provider
        if moved {
            chat.provider = ref.provider
            let modes = agent(for: chat).permissionModes
            if let first = modes.first, !modes.contains(where: { $0.rawValue == chat.permissionMode }) {
                chat.permissionMode = first.rawValue
            }
        }
        chat.model = ref.id
        if let levels = option(ref)?.efforts, let effort = chat.effort, !levels.contains(effort) {
            chat.effort = nil
        }
        if moved, chat.started { changedAgent(chat, to: ref) }
        save()
        if fastMode(of: chat) { checkFast(chat) }
    }

    /// A thread that has begun took another agent's model: the old agent's session is let go, the
    /// next send starts one on the new agent that opens with the thread so far, and the transcript
    /// says where it changed.
    private func changedAgent(_ chat: Chat, to ref: ModelRef) {
        let conversation = conversation(for: chat)
        chat.sessionId = nil
        chat.handover = conversation.items.contains(where: \.startsTurn)
        conversation.note(Self.nowOn(agent: providerInfo(ref.provider).agent, model: option(ref)?.name ?? ref.id))
        let thread = chat.id.uuidString
        Task { _ = try? await engine.request("leave", ["threadId": .string(thread)]) }
    }

    /// The quiet line where a thread changed agent.
    static func nowOn(agent: String, model: String) -> String {
        "Now on \(agent) · \(model)"
    }

    func setEffort(_ effort: String?, for chat: Chat?) {
        let unchanged = chat == nil && effort == startingEffort
        lastEffort = effort
        guard let chat = chat ?? (unchanged ? nil : newChat()) else { return }
        chat.effort = effort
        keep()
    }

    /// On when the thread asks for them and its model can run them; a switch to a model that
    /// can't leaves the thread's choice alone for when it switches back.
    func workflows(of chat: Chat?) -> Bool {
        chat?.workflows == true && option(for: chat)?.ultra == true
    }

    /// Workflows stay with the thread they were turned on in: a new thread never starts with them,
    /// so with none open, turning them on starts the thread they're for. The next send carries
    /// them; the engine needs nothing before it.
    func setWorkflows(_ on: Bool, for chat: Chat?) {
        guard let chat = chat ?? (on ? newChat() : nil) else { return }
        chat.workflows = on
        keep()
    }

    /// Threads stored at Ultracode, from when it was a level, at Extra high with workflows on,
    /// which is what Ultracode is.
    func carryUltracode() {
        let ultracode = Effort.ultracode
        guard let stored = try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.effort == ultracode })), !stored.isEmpty else { return }
        for chat in stored {
            chat.effort = "xhigh"
            chat.workflows = true
        }
        save()
    }

    func toggleFavorite(_ id: String) {
        if let at = favoriteModels.firstIndex(of: id) {
            favoriteModels.remove(at: at)
        } else {
            favoriteModels.append(id)
        }
    }

    func fastMode(of chat: Chat) -> Bool {
        chat.fastMode && option(for: chat)?.fast == true
    }

    func setFast(_ on: Bool, for chat: Chat?) {
        let unchanged = chat == nil && on == startingFast
        lastFast = on
        guard let chat = chat ?? (unchanged ? nil : newChat()) else { return }
        chat.fastMode = on
        keep()
        let fast = fastMode(of: chat)
        Task { _ = try? await engine.request("setFast", ["threadId": .string(chat.id.uuidString), "fast": .bool(fast)]) }
        if fast { checkFast(chat) }
    }

    /// Asks the CLI, without sending it anything, whether it would serve the thread's model fast,
    /// so the switch can say why not before a turn is spent finding out.
    func checkFast(_ chat: Chat) {
        checkFast(model: chat.model ?? ModelOption.claudeDefault, on: chat.providerID, thread: chat.id.uuidString)
    }

    /// The same question for a model, before any thread has asked it: the picker asks as it opens,
    /// so the Fast button already knows when it's clicked.
    func checkFast(model: String, on agent: String, thread: String = "picker") {
        let params: [String: JSON] = ["threadId": .string(thread), "model": .string(model)]
        Task { _ = try? await engine.request("fast.check", .object(params.naming(agent))) }
    }

    /// What Claude Code last said about fast mode for a thread's model, or the next thread's.
    func fastReading(for chat: Chat?) -> FastReading? {
        option(for: chat).flatMap { fastReadings[ModelRef(provider: providerID(for: chat), id: $0.id).stored] }
    }

    func setPermissionMode(_ mode: String, for chat: Chat?) {
        let unchanged = chat == nil && mode == startingPermissionMode
        lastPermissionMode = mode
        guard let chat = chat ?? (unchanged ? nil : newChat()) else { return }
        chat.permissionMode = mode
        keep()
        let running = conversation(for: chat).running
        Task {
            let reply = try? await engine.request("setMode", ["threadId": .string(chat.id.uuidString), "permissionMode": .string(mode)])
            if running, !agent(for: chat).capabilities.modeLive || reply?["applied"]?.bool == false {
                modeNote = "from the next reply"
                try? await Task.sleep(for: .seconds(2))
                modeNote = nil
            }
        }
    }
}

extension AppModel {
    /// Where Back to Defaults takes a thread: what Settings › New threads fixes for each choice,
    /// and Claude Code's own default for each it leaves to the last pick.
    struct ThreadDefaults {
        let effort: String?
        let fast: Bool
        let permissionMode: String
    }

    var threadDefaults: ThreadDefaults {
        let fixed = UserDefaults.standard
        let effort = fixed.string(forKey: NewThreads.effort) ?? ""
        return ThreadDefaults(
            effort: effort.isEmpty || effort == NewThreads.claudeDefault ? nil : effort,
            fast: fixed.string(forKey: NewThreads.fast) == NewThreads.on,
            permissionMode: fixed.string(forKey: NewThreads.permissionMode)?.nonEmpty ?? PermissionModeOption.ask.rawValue)
    }

    /// Whether a thread, or with none open the next one, already sits on its defaults. Effort is
    /// compared by the level it runs at, so a level picked that equals Default's counts.
    func atDefaults(_ chat: Chat?) -> Bool {
        let target = threadDefaults
        let model = defaultModel(for: chat)
        let option = option(for: chat)
        let targetOption = self.option(model)
        let effort = chat == nil ? startingEffort : chat?.effort
        let fast = (chat?.fastMode ?? startingFast) && option?.fast == true
        let onIt = model.provider == providerID(for: chat) && model.id == option?.id
        let targetHome = onIt ? defaultLevel(for: chat) : targetOption?.defaultEffort
        return onIt
            && (effort ?? defaultLevel(for: chat)) == (target.effort ?? targetHome)
            && fast == (target.fast && targetOption?.fast == true)
            && chat?.workflows != true
            && (chat?.permissionMode ?? startingPermissionMode) == target.permissionMode
    }

    /// Everything back to its default through the same calls a pick makes, so the last picks
    /// follow and a new thread starts where this one went back to.
    func resetToDefaults(for chat: Chat?) {
        let target = threadDefaults
        let model = defaultModel(for: chat)
        guard let chat = chat ?? newChat() else { return }
        if chat.model != model.id || chat.providerID != model.provider { setModel(model, for: chat) }
        setEffort(target.effort, for: chat)
        if chat.fastMode != target.fast { setFast(target.fast, for: chat) }
        if chat.workflows { setWorkflows(false, for: chat) }
        if chat.permissionMode != target.permissionMode { setPermissionMode(target.permissionMode, for: chat) }
    }
}

extension AppModel {
    /// Where Default lands for a thread: what its own CLI reported while it picked no level, for
    /// the model it's on now, which counts a project's settings; or what the engine read.
    func defaultLevel(for chat: Chat?) -> String? {
        guard let option = option(for: chat), !option.efforts.isEmpty else { return nil }
        if let chat, let reading = conversations[chat.id]?.defaultReading, reading.model == chat.model,
           let level = reading.level, option.efforts.contains(level) {
            return level
        }
        return option.defaultEffort
    }
}
