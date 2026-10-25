import CloudKit
import Link
import UserNotifications

/// Opens a notification's sealed Nudge on the phone and writes its words, so the push Apple
/// carries holds none of them: only CloudKit's "Waiting on you", which shows if the Nudge can't be
/// read in time.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        fallback = request.content
        let keychain = PhoneKeychain(group: (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String).map { $0 + "com.realmeric.oricode.phone" })
        guard let paired = keychain.read(),
              let query = CKNotification(fromRemoteNotificationDictionary: request.content.userInfo) as? CKQueryNotification,
              let id = query.recordID, id.zoneID == paired.zone,
              let content = request.content.mutableCopy() as? UNMutableNotificationContent
        else { return contentHandler(request.content) }
        let delivery = Delivery(handler: contentHandler, content: content, fallback: request.content)
        Task {
            guard let record = try? await CKContainer(identifier: Container.identifier).privateCloudDatabase.record(for: id),
                  let nudge = try? record.open(NudgeInfo.self, key: paired.state)
            else { return delivery.handler(delivery.fallback) }
            let content = delivery.content
            content.title = nudge.title
            content.body = nudge.body
            content.threadIdentifier = nudge.thread.uuidString
            content.userInfo["thread"] = nudge.thread.uuidString
            content.userInfo["ask"] = nudge.ask
            content.categoryIdentifier = await Self.category(for: nudge)
            delivery.handler(content)
        }
    }

    /// What the system handed over, carried into the task that reads the Nudge; the system calls
    /// the extension on one request at a time.
    private struct Delivery: @unchecked Sendable {
        let handler: (UNNotificationContent) -> Void
        let content: UNMutableNotificationContent
        let fallback: UNNotificationContent
    }

    /// Allow and Deny for a permission, Reply for a turn's end, and for a question with one
    /// question of three options at most, those options, registered for this ask alone.
    private static func category(for nudge: NudgeInfo) async -> String {
        switch nudge.kind {
        case .permission: return NotifyCategory.permission
        case .reply: return NotifyCategory.reply
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
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let fallback { handler?(fallback) }
    }
}
