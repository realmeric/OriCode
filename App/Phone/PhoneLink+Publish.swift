import CloudKit
import Link

extension PhoneLink {
    /// What the phone shows: for now the Mac's name and state alone. `again` writes all of it,
    /// sealed with a new state key.
    func published(again: Bool = false) {
        guard running else { return }
        if again { sentBoxes = [:] }
        publishMac(.awake)
        sendNow()
    }
}
