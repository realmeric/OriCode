import AppKit
import UserNotifications

/// One notification when a thread finishes or waits on you while you're elsewhere, and
/// the Dock badge counting the asks that wait. Clicking a notification opens its thread, or for
/// an ask the queue of everything waiting, on that ask.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var open: ((UUID) -> Void)?
    /// An ask's notification: the thread it waits in and the ask, which its click opens the queue on.
    var openAsk: ((UUID, String) -> Void)?
    private var asked = false
    /// The count the Dock shows, which is set again only when it changes.
    private var badged = 0

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, chatID: UUID, ask: String? = nil) {
        guard UserDefaults.standard.object(forKey: "notify") as? Bool ?? true else { return }
        let center = UNUserNotificationCenter.current()
        let first = !asked
        asked = true
        Task {
            if first { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["chat": chatID.uuidString, "ask": ask ?? ""]
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
        let info = response.notification.request.content.userInfo
        let chat = info["chat"] as? String
        let ask = info["ask"] as? String
        await MainActor.run { clicked(chat: chat, ask: ask) }
    }

    func clicked(chat: String?, ask: String?) {
        guard let id = chat.flatMap(UUID.init) else { return }
        NSApp.activate()
        if let ask, !ask.isEmpty, let openAsk {
            openAsk(id, ask)
        } else {
            open?(id)
        }
    }
}
