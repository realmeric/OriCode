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

    /// A conversation not in view, not running, not waiting on you and holding no messages is
    /// dropped from memory; reopening it reads it back off the main thread.
    func letGo(_ id: UUID) {
        guard !inView(id), let conversation = conversations[id], !conversation.working, conversation.waitingAsk == nil,
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
        pace(created)
        conversations[chat.id] = created
        return created
    }

    /// With two threads drawn and both at work, the open one streams every frame and the other
    /// every second one: two replies growing in the same frame cost more than the frame has. A
    /// block starting in a reply weighs on the frame only in a thread that's drawn.
    func pace(_ conversation: Conversation) {
        let id = conversation.chat.id
        conversation.everyOtherFrame = { [weak self] in
            guard let self, id == besideChatID, roomForTwo else { return false }
            return currentConversation?.running == true
        }
        conversation.drawn = { [weak self] in
            guard let self else { return false }
            return id == selectedChatID || id == besideChatID && roomForTwo
        }
    }

    /// Starts a turn with what's typed, or sends it into the one running; false when it did
    /// neither, so the composer keeps the text. In the open thread when none is named, and with
    /// none open in a new one.
    @discardableResult
    func send(_ text: String, in thread: Chat? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = composer(for: thread ?? chat)
        let images = composer.attachments
        guard !trimmed.isEmpty || !images.isEmpty, !tooLong(trimmed, for: thread ?? chat), let chat = thread ?? chat ?? newChat() else { return false }
        let conversation = conversation(for: chat)
        // Waiting on you from before a quit, the thread has no CLI to send into.
        guard !conversation.waitingAfterQuit else { return false }
        if conversation.running || !conversation.waiting.isEmpty {
            // An agent that can't take a message mid-turn gets it after the turn, as ⌥Return would.
            guard agent(for: chat).capabilities.steer else {
                conversation.enqueue(trimmed, images: images)
                composer.attachments = []
                return true
            }
            sendIntoTurn(conversation.sentIntoTurn(Self.asked(trimmed, images), typed: trimmed, images: images), in: chat)
        } else {
            guard send(trimmed, images: images, in: chat) else { return false }
        }
        composer.attachments = []
        conversation.sentByHand()
        return true
    }

    /// A queued message sent into the running turn instead of after it, or as a turn of its own
    /// when none runs; an agent that can't take one mid-turn keeps it queued.
    func sendQueuedNow(_ id: UUID, in thread: Chat? = nil) {
        guard let chat = thread ?? chat, let conversation = conversations[chat.id], let message = conversation.queue.first(where: { $0.id == id }) else { return }
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
    func queue(_ text: String, in thread: Chat? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let composer = composer(for: thread ?? chat)
        let images = composer.attachments
        guard !trimmed.isEmpty || !images.isEmpty, let conversation = (thread ?? chat).flatMap({ conversations[$0.id] }),
              conversation.running || !conversation.waiting.isEmpty, !tooLong(trimmed, for: conversation.chat)
        else { return false }
        conversation.enqueue(trimmed, images: images)
        composer.attachments = []
        return true
    }

    /// Starts a turn in any thread, on screen or not. `from` is the thread that sent it through
    /// one of OriCode's tools, which the session is told.
    func send(_ text: String, images: [ImageAttachment], in chat: Chat, from sender: Chat? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty, chat.agentID == nil else { return false }
        let conversation = conversation(for: chat)
        guard !conversation.running, !heldInBlock(chat), !tooLong(trimmed, for: chat) else { return false }
        let text = Self.asked(trimmed, images)
        // Only the pictures with a preview show, so only they are kept, and in the bubble's order.
        let shown = images.compactMap { image in image.preview.map { (image: image, preview: $0) } }
        let id = UUID()
        conversation.userSent(text, previews: shown.map { $0.preview }, id: id)
        conversation.pictures?.keep(shown.map { $0.image }, thread: chat.id, message: id)
        chat.turnFrom = sender?.id
        startTurn(in: chat, text: text, images: images, from: sender)
        return true
    }

    /// What goes out: what was typed, or for images alone a question about them.
    private static func asked(_ typed: String, _ images: [ImageAttachment]) -> String {
        typed.isEmpty ? "What's in \(images.count == 1 ? "this image" : "these images")?" : typed
    }

    /// Whether the message is longer than the thread's agent takes, which it then says, leaving the
    /// message where it was. Codex refuses one past a million characters, and sent anyway it came
    /// back as Codex's own error, with the message left in the thread as if it had gone.
    func tooLong(_ text: String, for chat: Chat?) -> Bool {
        guard let why = whyTooLong(text, for: chat) else { return false }
        say(why)
        // Focus stays in the composer with the text, so VoiceOver says why it didn't go.
        AccessibilityNotification.Announcement(why).post()
        return true
    }

    /// Characters a message may have for each token of the model's window. Lines of code and
    /// dictionary words came to 2.4 a token on Haiku 5.5, so a message over twice the window fills
    /// it nearly whole or more, and a session that doesn't fit is one the model can't be sent again.
    static let charactersPerToken = 2

    /// What says the message is longer than the thread takes, by its agent's own limit or twice its
    /// model's window, whichever is less; nil when it fits.
    func whyTooLong(_ text: String, for chat: Chat?) -> String? {
        let agent = agent(for: chat)
        let option = option(for: chat)
        let window = option?.window ?? chat.flatMap { $0.contextWindow > 0 ? $0.contextWindow : nil }
        let read = window.map { $0 * Self.charactersPerToken }
        guard let longest = [agent.capabilities.longestMessage, read].compactMap(\.self).min(),
              // Never fewer bytes than scalars, so only a message with more bytes than the limit is counted.
              text.utf8.count > longest, text.unicodeScalars.count > longest
        else { return nil }
        let count = text.unicodeScalars.count.formatted()
        guard window != nil, longest == read else { return "\(agent.agent) takes messages of up to \(longest.formatted()) characters. This one has \(count)." }
        // Short enough for a column of two side by side. Default's name is the menu's, not a model's.
        let name = option.flatMap { $0.id == ModelOption.claudeDefault ? nil : $0.name } ?? agent.agent
        return "\(name) reads about \(longest.formatted()) characters. This has \(count)."
    }

    /// Hands a message the transcript already shows, or one it needn't, to the thread's session
    /// with the thread's model, level, mode and speed.
    func startTurn(in chat: Chat, text: String, images: [ImageAttachment] = [], allowing grant: PendingAsk? = nil, from sender: Chat? = nil) {
        let conversation = conversation(for: chat)
        holdWhileWorking()
        // The commands run from the shell prompt since Claude last read them go first.
        let (text, readShells) = withShells(text, in: chat)
        // No folder's own folder is the app's to keep there, whatever emptied the support folder.
        if chat.project?.isNoFolder == true { try? FileManager.default.createDirectory(atPath: chat.cwd, withIntermediateDirectories: true) }
        let params = turnParams(in: chat, text: text, images: images, allowing: grant, from: sender)
        Task {
            do {
                _ = try await engine.request("send", .object(params))
                readShells()
            } catch {
                conversation.sendFailed(error.localizedDescription)
                turnEnded(chat.id)
                holdWhileWorking()
                // A queued message the engine turned down ends the thread's work, and the turn
                // before it held back its Finished for it.
                if isAway(chat) { notifier.post(title: chat.title, body: error.localizedDescription, chatID: chat.id) }
            }
        }
    }

    /// What `send` carries to start a turn: the thread's settings, the thread so far when its
    /// session is new, and a call allowed before a quit.
    func turnParams(in chat: Chat, text: String, images: [ImageAttachment] = [], allowing grant: PendingAsk? = nil, from sender: Chat? = nil) -> [String: JSON] {
        var params = sendParams(in: chat, text: text, images: images, from: sender)
        if let handover = handover(for: chat) { params["handover"] = .string(handover) }
        if let grant { params["grant"] = ["tool": .string(grant.tool), "input": grant.input] }
        return params
    }

    /// The thread's session can't be sent to the model again: longer than it reads at once (`long`),
    /// or one it stopped answering in (`refused`), so every later turn there fails the same and is
    /// paid for. The engine has let it go; the thread goes on in a new session handed what it has
    /// said. `held` is the session having had a turn before this one, and when what started this
    /// turn could go better in a new session, it goes again at once and is returned.
    @discardableResult
    func startOver(_ chat: Chat, spent: String, held: Bool) -> String? {
        let conversation = conversation(for: chat)
        chat.sessionId = nil
        conversation.water.forget()
        chat.handover = true
        let again = held ? Self.sentAgain(after: spent, in: conversation.items) : nil
        let agent = agent(for: chat).agent
        let why = spent == "long" ? "This session is more than \(agent) reads at once" : "\(agent) won't go on in this session"
        conversation.note("\(why), so \(again == nil ? "the next message starts" : "the message goes again in") a new one, handed what the thread has said.")
        save()
        guard let again else { return nil }
        // Working until that turn starts, so Return meanwhile goes into it and not beside it.
        conversation.resending()
        startTurn(in: chat, text: again)
        return again
    }

    /// The message that started the spent turn, when it's worth sending again: a session too long
    /// for the model, which a new one handed the thread so far isn't, or one the model refused
    /// while the thread held an older message longer than this one and than a handover keeps of
    /// the latest, which may be what it stopped on. Nil for a turn its own message didn't start, a
    /// background agent reporting back after that message was answered, and for one with pictures,
    /// which the thread doesn't keep whole.
    static func sentAgain(after spent: String, in items: [Item]) -> String? {
        guard let index = items.lastIndex(where: \.startsTurn),
              // The spent turn's footer is the one just written; one before it ended this message's turn.
              items[index...].count(where: { if case .footer = $0 { true } else { false } }) == 1,
              case .user(_, let text, let images, _) = items[index], images.isEmpty
        else { return nil }
        guard spent == "refused" else { return text }
        let longest = max(text.utf8.count, Handover.cap / 2)
        let older = items[..<index].contains { item in
            if case .user(_, let older, _, _) = item { older.utf8.count > longest } else { false }
        }
        return older ? text : nil
    }

    /// The thread so far, for the session a change of agent or a spent session starts: everything
    /// before the message just sent, until a turn in the new session has begun.
    func handover(for chat: Chat) -> String? {
        guard chat.handover, chat.sessionId == nil else { return nil }
        let items = conversation(for: chat).items
        let text = Handover.text(from: Array(items[..<(items.lastIndex(where: \.startsTurn) ?? items.endIndex)]), cwd: chat.cwd)
        return text.isEmpty ? nil : text
    }

    /// A message for the running turn, which Claude takes up at its next step. The engine sends
    /// it with the thread's settings, which only the next turn takes.
    func sendIntoTurn(_ message: WaitingMessage, in chat: Chat, from sender: Chat? = nil) {
        let conversation = conversation(for: chat)
        // A message into the turn is the next one too, so the shell's new blocks go with it. They
        // count as read once Claude takes it up; handed back, they go with the next message.
        let (text, readShells) = withShells(message.text, in: chat)
        shellReads[message.id] = readShells
        var params = sendParams(in: chat, text: text, images: message.images, from: sender)
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

    func sendParams(in chat: Chat, text: String, images: [ImageAttachment], from sender: Chat? = nil) -> [String: JSON] {
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
        if let choice = choice(for: chat) { params["choose"] = choice }
        if let sessionId = chat.sessionId { params["sessionId"] = .string(sessionId) }
        if let model = modelSent(in: chat) { params["model"] = .string(model) }
        // Only a level the model has now, the way the picker shows it.
        if let effort = chat.effort, option(for: chat)?.efforts.contains(effort) ?? true { params["effort"] = .string(effort) }
        params["fast"] = .bool(fastMode(of: chat))
        if UserDefaults.standard.bool(forKey: TranscriptSettings.concise) { params["concise"] = true }
        // The engine tells the session its folder is nobody's project.
        if chat.project?.isNoFolder == true { params["noFolder"] = true }
        if workflows(of: chat) { params["workflows"] = true }
        // Off, the engine offers the agent no tools for the Mac at all.
        if MacAccess.isOn { params["mac"] = true }
        // A message from another thread says which, so the session can answer it.
        if let sender { params["from"] = ["id": .string(sender.id.uuidString), "title": .string(sender.title)] }
        // So does the task of the plan it works, while it isn't done.
        if let task = taskParams(for: chat) { params["task"] = task }
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

    /// `thread` is the ask's own, which with two in view isn't always the open one; without it
    /// the ask is the open thread's. `choice` is one of the agent's own answers, which it gets
    /// back by its id.
    func answer(_ ask: PendingAsk, in thread: UUID? = nil, allow: Bool, answers: [String: String]? = nil, message: String? = nil, choice: PendingAsk.Choice? = nil) {
        guard let chat = thread == nil ? chat : thread.flatMap(chat(withID:)) else { return }
        if conversation(for: chat).askedBeforeQuit.contains(ask.requestId) {
            answerAfterQuit(ask, in: chat, allow: allow, answers: answers, message: message)
            return
        }
        let params = Self.answerParams(ask, allow: allow, answers: answers, message: message, choice: choice)
        // The card folds into its one line and what's under it closes up, rather than jumping.
        withAnimation(Motion.move) { conversation(for: chat).answered(ask.requestId, allow: allow) }
        askers[ask.requestId] = nil
        // Answered from the queue, what the notification asked is settled too.
        if conversation(for: chat).waitingAsk == nil { notifier.clear(chatID: chat.id) }
        // A card's field that had the keyboard went with the card, and the composer under the
        // queue or beside doesn't see the open thread's ask change.
        if chat.id != selectedChatID { returnKeyboardSoon() }
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

    /// Whether Stop has something in the open thread: its turn, the agent it is, or with its turn
    /// over what it left working.
    var canStop: Bool {
        currentConversation?.running == true || chat?.agentWorking == true || chat.map(leftWorking) == true
    }

    /// Its turn is over and it left something working: a worker, a workflow, a subagent or a
    /// command its turn started, or a thread it set going.
    func leftWorking(_ chat: Chat) -> Bool {
        guard chat.agentID == nil, let conversation = conversations[chat.id], !conversation.running, !conversation.waitingAfterQuit else { return false }
        return conversation.heads.list.contains { !$0.ending } || !setGoing(by: chat, sparing: nil).isEmpty
    }

    /// Stop ends the turn and takes back everything still to go: the engine cancels what was sent
    /// into the turn, and the queue goes back now, not when the turn ends, since a turn already
    /// ending by itself as the interrupt goes out would still send its next. With the turn over it
    /// stops what the thread left working, since an interrupt with no turn running does nothing.
    /// `sparing` is a thread that asked for this stop with stop_thread, whose own turn goes on.
    func stop(in thread: Chat? = nil, sparing: UUID? = nil) {
        guard let chat = thread ?? chat else { return }
        // An agent has no turn of its own here: its opener stops it, or its workflow.
        guard chat.agentID == nil else {
            if chat.agentWorking { stopAgent(chat) }
            return
        }
        let conversation = conversation(for: chat)
        conversation.handBackQueue()
        stopOpened(by: chat, sparing: sparing)
        if !conversation.running, !conversation.waitingAfterQuit {
            for head in conversation.heads.list where !head.ending {
                stop(head, in: chat)
            }
            return
        }
        if conversation.waitingAfterQuit {
            withAnimation(Motion.move) { conversation.stopAfterQuit() }
            holdWhileWorking()
            notifier.badge(waitingCount)
            return
        }
        Task { _ = try? await engine.request("interrupt", ["threadId": .string(chat.id.uuidString)]) }
    }

    /// The threads it opened whose turn it set going, with open_thread or message_thread, that are
    /// working. A turn the user or another thread started there isn't its to stop.
    func setGoing(by chat: Chat, sparing: UUID?) -> [Conversation] {
        // A thread at work has its conversation in memory, so nothing is fetched for this.
        conversations.values.filter {
            $0.chat.openedBy == chat.id && $0.chat.turnFrom == chat.id && $0.chat.id != sparing && $0.chat.agentID == nil && ($0.running || $0.waitingAfterQuit)
        }
    }

    /// Stop on a thread reaches what it started: each thread it set going stops too, and so on
    /// down, with a line in both saying so. Its workers and subagents stop with its turn.
    func stopOpened(by chat: Chat, sparing: UUID? = nil) {
        for other in setGoing(by: chat, sparing: sparing) {
            let thread = other.chat
            stop(in: thread, sparing: sparing)
            // After the stop, so a thread waiting from before a quit, which stops at once, says it now.
            other.threadAct(ThreadAct(act: .stoppedWith, by: false, thread: chat.id, title: chat.title, reason: ""))
            conversation(for: chat).threadAct(ThreadAct(act: .stoppedWith, by: true, thread: thread.id, title: thread.title, reason: ""))
        }
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
        if Self.asks.contains(event.name) || MacHands.asks.contains(event.name) {
            answerTool(event, from: id)
            return
        }
        guard let chat = chat(withID: id) else { return }
        if event.name == "agent.lines" {
            transcribed(event.body, into: chat)
            return
        }
        if event.name == "agent.thread" {
            syncAgent(of: chat, event.body)
            return
        }
        if event.name == "worker.said" {
            workerSaid(event.body)
            return
        }
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
        if event.name == "ask", let requestId = event.body["requestId"]?.string,
           let asker = event.body["agentId"]?.string.flatMap({ agentThread($0, under: chat) }) {
            askers[requestId] = asker
        }
        if event.name == "ask.cancelled", let requestId = event.body["requestId"]?.string { askers[requestId] = nil }
        if event.name == "workflow" { syncAgents(of: chat, event.body) }
        if event.name == "turn.started" || event.name == "turn.done" { noteOutcome(event, of: chat) }
        if event.name == "turn.done", let spent = event.body["spent"]?.string {
            startOver(chat, spent: spent, held: event.body["held"]?.bool == true)
        }
        // On screen or not, a turn that ended by itself lets the thread's queue send its next, and
        // so does the last message it left waiting going back.
        if event.name == "turn.done" || event.name == "message.cancelled" {
            conversation(for: chat).sendNext { send($0.text, images: $0.images, in: chat) }
            turnEnded(chat.id)
        }
        holdWhileWorking()
        tellIfAway(event, chat: chat)
        if event.name == "limited" { scheduleResumes() }
        if event.name == "limits" { takeLimits(event.body, for: chat.providerID) }
        if event.name == "tool.result", event.body["parent"]?.string == nil, inView(chat.id) { followWater(chat) }
        if event.name == "turn.done" {
            // A thread out of view is counted when it comes into view.
            if inView(chat.id) { readWater(for: chat, turnEnded: true) }
            tellOpener(of: chat)
            pushedMaybe(in: chat.cwd)
            refreshBranch(for: chat)
        }
        // The count at the top right follows every turn in the open folder, and an open review
        // follows every edit.
        if chat.cwd == self.chat?.cwd, event.name == "turn.done" || (reviewShown && (event.name == "tool.result" || event.name == "tool.ended")) {
            readReview(after: .milliseconds(event.name == "turn.done" ? 200 : 500))
        }
    }

    /// A thread by its id: the one its conversation holds, or from the store.
    func chat(withID id: UUID) -> Chat? {
        conversations[id]?.chat ?? (try? context.fetch(.init(predicate: #Predicate<Chat> { $0.id == id })).first)
    }

    /// A turn that ends or asks while OriCode isn't the window you're in gets one notification.
    private func tellIfAway(_ event: EngineEvent, chat: Chat) {
        notifier.badge(waitingCount)
        guard event.name == "turn.done" || event.name == "ask", isAway(chat) else { return }
        if event.name == "ask" {
            let tool = event.body["tool"]?.string ?? ""
            let summary = event.body["kind"]?.string == "question"
                ? "A question for you."
                : "Waiting on you: " + ToolSummary.line(for: ToolCall(
                    toolUseId: "", name: tool, input: event.body["input"] ?? .null,
                    declared: ToolKind(event.body["toolKind"], tool: tool), view: event.body["view"] ?? .null), cwd: chat.cwd)
            // Named by the thread that asks, a worker or subagent under this one included; its
            // click opens the queue on the ask.
            let asker = event.body["requestId"]?.string.flatMap { askers[$0] } ?? chat
            notifier.post(title: asker.title, body: summary, chatID: chat.id, ask: event.body["requestId"]?.string)
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
        !NSApp.isActive || !onGlass(chat.id)
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
            guard midTurn else { continue }
            conversation.note("The engine stopped in the middle of this turn.")
            // No turn.done comes from an engine that died, so the screen of everything running
            // hears it here.
            outcomes[conversation.chat.id] = Outcome(state: .stopped, line: Self.turnLine(conversation))
        }
        for conversation in conversations.values { conversation.endWorkflows() }
        // A new engine watches nothing until it's asked again.
        headsWatched = nil
        followed = []
        heldPieces = [:]
        agentThreads = [:]
        askers = [:]
        settleAgents()
        // Whatever was sent into a turn went with the engine; it goes back to the composer.
        shellReads = [:]
        for conversation in conversations.values { withAnimation(Motion.fade) { conversation.handBackAll() } }
        // Every wait on a thread is over: its turn went with the engine.
        for id in turnWaits.keys { turnEnded(id) }
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
            fitPermissionMode(of: chat)
        }
        chat.model = ref.id
        if let levels = option(ref)?.efforts, let effort = chat.effort, !levels.contains(effort) {
            chat.effort = nil
        }
        if moved, chat.started { changedAgent(chat, to: ref) }
        save()
        if fastMode(of: chat) { checkFast(chat) }
    }

    /// A thread's mode as one its agent has: its own, or else the agent's first.
    func fitPermissionMode(of chat: Chat) {
        let modes = agent(for: chat).permissionModes
        if let first = modes.first, !modes.contains(where: { $0.rawValue == chat.permissionMode }) {
            chat.permissionMode = first.rawValue
        }
    }

    /// A thread that has begun took another agent's model: the old agent's session is let go, the
    /// next send starts one on the new agent that opens with the thread so far, and the transcript
    /// says where it changed.
    private func changedAgent(_ chat: Chat, to ref: ModelRef) {
        let conversation = conversation(for: chat)
        chat.sessionId = nil
        // The old session's water isn't this agent's: nothing stands until the thread has a figure of its own.
        conversation.water.forget()
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
