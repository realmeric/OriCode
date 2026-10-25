import CloudKit
import Foundation
import Link

/// What the phone asks of the Mac: each command goes through the function the Mac's own button
/// calls, with the same checks, and its outcome goes back into the same record, sealed for the
/// phone that sent it. A command seen before, or older than ten minutes by CloudKit's clock, is
/// refused.
extension PhoneLink {
    static let commandLife: TimeInterval = 600
    private static let noncesKey = "phoneNonces"

    func commanded(_ record: CKRecord) {
        guard let keys, record.data(Field.outcome) == nil, let sender = record.string(Field.phone),
              let phone = keys.phones.first(where: { $0.id == sender })
        else { return }
        // Sealed by no phone this Mac knows: not taken, and not answered.
        guard let command = try? record.open(Command.self, key: phone.pairingKey) else {
            Self.logger.notice("a command that didn't open was ignored")
            return
        }
        let outcome = Self.refusal(seen: Self.seen(command.nonce), made: record.creationDate).map(Link.Outcome.refused) ?? apply(command.action)
        Self.remember(command.nonce)
        guard (try? record.seal(outcome, key: phone.pairingKey, field: Field.outcome)) != nil else { return }
        put(record)
        sendNow()
        Self.logger.notice("a command from the phone: \(outcome.ok ? "done" : "refused", privacy: .public)")
    }

    private func apply(_ action: Command.Action) -> Link.Outcome {
        guard let model else { return .refused("OriCode isn't ready") }
        switch action {
        case .answer(let id, let thread, let allow, let choice, let answers, let message):
            guard let conversation = model.conversations[thread], let ask = conversation.waitingAsks.first(where: { $0.requestId == id }) else {
                return .refused("No longer waiting")
            }
            model.answer(ask, in: thread, allow: allow, answers: answers, message: message, choice: choice.flatMap { id in ask.choices.first { $0.id == id } })
            return Link.Outcome(ok: true)
        case .stop(let thread):
            guard let chat = model.chat(withID: thread) else { return .refused("No such thread") }
            guard model.conversations[thread]?.working == true else { return .refused("Not working") }
            model.stop(in: chat)
            return Link.Outcome(ok: true)
        case .send(let thread, let text):
            guard let chat = model.chat(withID: thread), chat.agentID == nil else { return .refused("No such thread") }
            // Into the running turn as the Mac's composer sends it, or a turn of its own.
            guard model.send(text, in: chat, takingAttachments: false) else { return .refused("The Mac didn't take it") }
            messaged.insert(thread)
            statuses[thread] = .working
            return Link.Outcome(ok: true, thread: thread)
        case .open(let id, let text):
            // In the project named, or the one ⌘N would start in, on what new threads start with.
            guard let project = id.flatMap({ id in model.projects.first { $0.id == id } }) ?? model.project ?? model.projects.first else {
                return .refused("No such project")
            }
            let chat = model.makeChat(in: project)
            guard model.send(text, in: chat, takingAttachments: false) else {
                model.context.delete(chat)
                model.save()
                return .refused("The Mac didn't take it")
            }
            messaged.insert(chat.id)
            statuses[chat.id] = .working
            return Link.Outcome(ok: true, thread: chat.id)
        }
    }

    /// Why a command isn't taken, before what it asks is looked at: its nonce seen already, a saved
    /// copy sent again, or made more than ten minutes ago, while the Mac slept say.
    static func refusal(seen: Bool, made: Date?, now: Date = .now) -> String? {
        if seen { return "Sent before" }
        if let made, now.timeIntervalSince(made) > commandLife { return "Too late" }
        return nil
    }

    // MARK: Nonces

    /// Nonces seen in the last hour, by when: a command is refused after ten minutes anyway.
    private static var nonces: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: noncesKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: noncesKey) }
    }

    static func seen(_ nonce: UUID) -> Bool {
        nonces[nonce.uuidString] != nil
    }

    static func remember(_ nonce: UUID) {
        let now = Date.now.timeIntervalSince1970
        var kept = nonces.filter { now - $0.value < 3_600 }
        kept[nonce.uuidString] = now
        nonces = kept
    }
}
