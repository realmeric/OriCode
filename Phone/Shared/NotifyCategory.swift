import UserNotifications

/// The notifications' buttons, which the app registers at launch and the extension picks from.
enum NotifyCategory {
    static let permission = "permission"
    static let question = "question"
    static let reply = "reply"
    static let optionsPrefix = "options-"

    static let allow = "allow"
    static let deny = "deny"
    static let answer = "reply"
    static let optionPrefix = "option-"

    static func options(_ ask: String) -> String { optionsPrefix + ask }

    /// Allow asks for Face ID first; Deny doesn't need to.
    static var all: Set<UNNotificationCategory> {
        [
            UNNotificationCategory(identifier: permission, actions: [
                UNNotificationAction(identifier: allow, title: "Allow", options: [.authenticationRequired]),
                UNNotificationAction(identifier: deny, title: "Deny", options: [.destructive]),
            ], intentIdentifiers: []),
            UNNotificationCategory(identifier: question, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: reply, actions: [
                UNTextInputNotificationAction(identifier: answer, title: "Reply", options: [], textInputButtonTitle: "Reply", textInputPlaceholder: ""),
            ], intentIdentifiers: []),
        ]
    }

    static func make(options: [String], identifier: String) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: options.enumerated().map {
            UNNotificationAction(identifier: optionPrefix + String($0.offset), title: $0.element, options: [.authenticationRequired])
        }, intentIdentifiers: [])
    }
}
