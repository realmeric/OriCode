import Intents
import Link
import UserNotifications

/// A Nudge's notification: who, which project and what it wants, grouped by thread, an ask breaking
/// through as time-sensitive, and the thread speaking with its avatar as a person does in Messages.
enum NudgeContent {
    static func write(_ nudge: NudgeInfo, into content: UNMutableNotificationContent) async {
        content.title = nudge.title
        content.subtitle = nudge.subtitle
        content.body = nudge.body
        content.threadIdentifier = nudge.thread.uuidString
        content.interruptionLevel = nudge.kind.asks ? .timeSensitive : .active
        content.userInfo["thread"] = nudge.thread.uuidString
        content.userInfo["ask"] = nudge.ask
        // What a tap needs to show the thread before its record has come.
        content.userInfo["nudge"] = (try? JSONEncoder().encode(nudge)).flatMap { String(data: $0, encoding: .utf8) }
        // What a question's buttons answer, so the app needn't read it again.
        content.userInfo["question"] = nudge.body
        for (index, option) in nudge.options.enumerated() { content.userInfo["option\(index)"] = option }
        content.categoryIdentifier = await category(for: nudge)
    }

    /// Allow and Deny for a permission, Reply for a turn's end, and for a question with one
    /// question of three options at most, those options, registered for this ask alone.
    private static func category(for nudge: NudgeInfo) async -> String {
        switch nudge.kind {
        case .reply, .failed, .stopped: return NotifyCategory.reply
        case .question:
            guard !nudge.options.isEmpty, let ask = nudge.ask else { return NotifyCategory.question }
            let identifier = NotifyCategory.options(ask)
            let center = UNUserNotificationCenter.current()
            var categories = await center.notificationCategories()
            // Only the latest few questions keep theirs.
            let old = categories.filter { $0.identifier.hasPrefix(NotifyCategory.optionsPrefix) }
            if old.count > 8 { categories.subtract(old) }
            categories.insert(NotifyCategory.make(options: nudge.options, identifier: identifier))
            center.setNotificationCategories(categories)
            return identifier
        default: return NotifyCategory.permission
        }
    }

    /// The thread as a sender, its avatar round beside its words. That layout draws no subtitle,
    /// set before `updating(from:)` or after it, so what it wants heads the body. A phone that
    /// won't have that keeps its subtitle and gets the avatar as the notification's thumbnail.
    static func speaking(_ nudge: NudgeInfo, _ content: UNMutableNotificationContent) async -> UNNotificationContent {
        let avatar = Avatar.png(for: nudge)
        let id = nudge.thread.uuidString
        let sender = INPerson(personHandle: INPersonHandle(value: id, type: .unknown), nameComponents: nil, displayName: nudge.title,
                              image: INImage(imageData: avatar), contactIdentifier: nil, customIdentifier: id)
        let words = nudge.body.isEmpty ? nudge.subtitle : "\(nudge.subtitle)\n\(nudge.body)"
        let intent = INSendMessageIntent(recipients: nil, outgoingMessageType: .outgoingMessageText, content: words, speakableGroupName: nil,
                                         conversationIdentifier: id, serviceName: nil, sender: sender, attachments: nil)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            let speaking = try content.updating(from: intent)
            guard let written = speaking.mutableCopy() as? UNMutableNotificationContent else { return speaking }
            written.body = words
            return written
        } catch {
            let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
            if (try? avatar.write(to: file)) != nil, let thumbnail = try? UNNotificationAttachment(identifier: "avatar", url: file) {
                content.attachments = [thumbnail]
            }
            return content
        }
    }
}
