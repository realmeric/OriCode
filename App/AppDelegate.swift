import AppKit

/// Folders dropped on the Dock icon, or `open -a OriCode <folder>`, become projects; images
/// opened the same way go into the composer. Quitting asks first while a command runs in the
/// terminal.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openFolder: ((URL) -> Void)?
    /// What's running in the terminal ("sleep in alpha"), and what ends every shell.
    var runningInTerminal: (() -> [String])?
    var endTerminals: (() -> Void)?
    private var early: [URL] = []

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = runningInTerminal?() ?? []
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A command is still running in the terminal"
        let list = running.count == 1 ? running[0] : running.dropLast().joined(separator: ", ") + " and " + running[running.count - 1]
        alert.informativeText = "Quitting OriCode stops \(list)."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // Every shell is hung up, the way closing its window would, and the jobs in it with it.
    func applicationWillTerminate(_ notification: Notification) {
        endTerminals?()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let openFolder { openFolder(url) } else { early.append(url) }
        }
    }

    func deliverEarlyFolders() {
        let waiting = early
        early = []
        waiting.forEach { openFolder?($0) }
    }
}
