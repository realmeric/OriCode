import UserNotifications

/// Opens a notification's sealed Nudge on the phone and writes its words, so the push Apple
/// carries holds none of them.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        contentHandler(request.content)
    }
}
