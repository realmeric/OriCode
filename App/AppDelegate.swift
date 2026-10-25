import AppKit

/// Folders dropped on the Dock icon, or `open -a OriCode <folder>`, become projects; images
/// opened the same way go into the composer. Quitting asks first while a command runs in a
/// thread's block, and marks the threads still working so the next launch picks them up. A
/// SIGTERM, which is how `make app` quits OriCode, is a quit like any other, without the question.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openFolder: ((URL) -> Void)?
    /// The commands running in blocks ("sleep in alpha"), and what ends them.
    var runningCommands: (() -> [String])?
    var endCommands: (() -> Void)?
    var markCutOffTurns: (() -> Void)?
    /// Takes down the sheets SwiftUI puts up, which it would put back if AppKit ended them alone.
    var dismissSheets: (() -> Void)?
    /// Tells a paired phone OriCode closed.
    var closePhone: (() -> Void)?
    /// A silent push from CloudKit: the phone wrote.
    var phonePushed: (([String: Any]) -> Void)?
    private var early: [URL] = []
    private var terminationSignal: DispatchSourceSignal?
    private var quittingOnSignal = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.quittingOnSignal = true
            self?.quit()
        }
        source.resume()
        terminationSignal = source
        // The Dock's Quit, a logout, a restart and `osascript … to quit` all send this; ⌘Q is
        // OriCodeCommands'.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:reply:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
#if PERF
        PerfBench.startIfAsked()
#endif
    }

    @objc private func quitEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        quit()
    }

    /// AppKit cancels a quit while a window has a sheet, before asking this delegate, so a sheet
    /// such as the ask at a first launch is taken down first, and the quit waits up to a second
    /// for it to go; that ask stays unanswered and asks again next time.
    func quit(waited: Int = 0) {
        guard waited < 20, NSApp.windows.contains(where: { $0.attachedSheet != nil }) else { return NSApp.terminate(nil) }
        if waited == 0 { dismissSheets?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { self.quit(waited: waited + 1) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nobody is there to answer for a signal.
        guard !quittingOnSignal else { return .terminateNow }
        let running = runningCommands?() ?? []
        guard !running.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = running.count == 1 ? "A command is still running in a thread" : "Commands are still running in threads"
        let list = running.count == 1 ? running[0] : running.dropLast().joined(separator: ", ") + " and " + running[running.count - 1]
        alert.informativeText = "Quitting OriCode stops \(list)."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // Every block's command is hung up, the way closing a terminal window would, and the jobs it
    // started with it.
    func applicationWillTerminate(_ notification: Notification) {
        markCutOffTurns?()
        closePhone?()
        endCommands?()
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        phonePushed?(userInfo)
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
