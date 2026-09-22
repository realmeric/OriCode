import AppKit

/// Folders dropped on the Dock icon, or `open -a OriCode <folder>`, become projects; images
/// opened the same way go into the composer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openFolder: ((URL) -> Void)?
    private var early: [URL] = []

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
