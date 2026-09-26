import AppKit
import UserNotifications

/// One notification when a thread finishes or waits on you while you're elsewhere, and
/// the Dock badge counting threads that wait. Clicking a notification opens its thread.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var open: ((UUID) -> Void)?
    private var asked = false
    /// The count the Dock shows, which is set again only when it changes.
    private var badged = 0

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, chatID: UUID) {
        guard UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        let first = !asked
        asked = true
        Task {
            if first { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["chat": chatID.uuidString]
            content.threadIdentifier = chatID.uuidString
            // One per thread: a newer one replaces what that thread said before.
            try? await center.add(UNNotificationRequest(identifier: chatID.uuidString, content: content, trigger: nil))
        }
    }

    func clear(chatID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [chatID.uuidString])
    }

    func badge(_ waiting: Int) {
        guard waiting != badged else { return }
        badged = waiting
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = (response.notification.request.content.userInfo["chat"] as? String).flatMap(UUID.init) else { return }
        await MainActor.run {
            NSApp.activate()
            open?(id)
        }
    }
}
