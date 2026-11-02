import CloudKit
import Link
import os
import UserNotifications

/// Opens a notification's sealed Nudge on the phone and writes its words, so the push Apple
/// carries holds none of them: only CloudKit's "Waiting on you", which shows if the Nudge can't be
/// read in time.
final class NotificationService: UNNotificationServiceExtension {
    private static let logger = Logger(subsystem: "com.realmeric.oricode.phone", category: "notify")
    private var delivery: Delivery?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let delivery = Delivery(handler: contentHandler, content: request.content)
        self.delivery = delivery
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return delivery.finish() }
        let keychain = PhoneKeychain(group: (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String).map { $0 + "com.realmeric.oricode.phone" })
        guard let paired = keychain.read(), let id = ZoneSync.nudge(in: request.content.userInfo, for: paired.zone) else {
            Self.logger.notice("not a Nudge of this phone's zone")
            return delivery.finish()
        }
        let carried = Carried(content: content)
        Task {
            do {
                let record = try await CKContainer(identifier: Container.identifier).privateCloudDatabase.record(for: id)
                let nudge = try record.open(NudgeInfo.self, key: paired.state)
                // The words first, so a phone out of time still shows them.
                await NudgeContent.write(nudge, into: carried.content)
                delivery.keep(carried.content)
                delivery.finish(await NudgeContent.speaking(nudge, carried.content))
            } catch {
                Self.logger.error("couldn't open a Nudge: \(error.localizedDescription, privacy: .public)")
                delivery.finish()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery?.finish()
    }
}

/// The content, carried into the task that writes it; nothing else holds it.
private struct Carried: @unchecked Sendable {
    let content: UNMutableNotificationContent
}

/// The system's handler, called once, with the best content so far when time runs out.
private final class Delivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNNotificationContent

    init(handler: @escaping (UNNotificationContent) -> Void, content: UNNotificationContent) {
        self.handler = handler
        best = content
    }

    func keep(_ content: UNNotificationContent) {
        lock.withLock { best = content }
    }

    func finish(_ content: UNNotificationContent? = nil) {
        let (handler, best) = lock.withLock {
            defer { handler = nil }
            return (handler, content ?? best)
        }
        handler?(best)
    }
}
