import Foundation
import SwiftTerm

/// Tab at the prompt for a user whose shell is zsh, answered by that zsh: one `zsh -l -i` behind a
/// pty, started with their own startup files and completion and Completion.zsh's hook after them,
/// kept for the app's life and asked for each Tab's matches in the thread's folder. A Tab it
/// doesn't answer in time, often the first while their .zshrc still loads, is left to the paths.
///
/// Everything it keeps is touched only on its queue, which is also where the pty calls back.
final class ZshCompletion: LocalProcessDelegate, @unchecked Sendable {
    static let patience: DispatchTimeInterval = .milliseconds(400)
    /// The key Completion.zsh binds to its widget.
    private static let key = Array("\u{1B}[5555~".utf8)

    private let queue = DispatchQueue(label: "com.realmeric.oricode.zsh-completion")
    /// Its ZDOTDIR, whose startup files hand over to the user's, and where each Tab is written.
    private let home: URL
    private var process: LocalProcess?
    private var received: [UInt8] = []
    private var asked = 0
    private var waiting: (id: Int, answer: CheckedContinuation<String?, Never>)?

    /// `userFolder` stands in for where the user's startup files are, for a test that mustn't
    /// read theirs.
    init?(userFolder: String? = nil) {
        guard let script = Bundle.main.path(forResource: "Completion", ofType: "zsh") else { return nil }
        home = FileManager.default.temporaryDirectory.appending(path: "OriCode-zsh-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for name in [".zshenv", ".zprofile", ".zshrc"] {
                let line = "source \(ShellCompletion.escape(script)) \(name)\n"
                try line.write(to: home.appending(path: name), atomically: true, encoding: .utf8)
            }
        } catch {
            return nil
        }
        var environment = TerminalEnvironment.make() + ["ZDOTDIR=" + home.path]
        if let userFolder { environment.append("ORICODE_USER_ZDOTDIR=" + userFolder) }
        queue.sync {
            let process = LocalProcess(delegate: self, dispatchQueue: queue)
            TerminalEnvironment.closeOnExec()
            process.startProcess(executable: TerminalEnvironment.shell, args: ["-l", "-i"], environment: environment,
                                 currentDirectory: NSHomeDirectory())
            let master = process.childfd
            if master >= 0 { _ = fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC) }
            if process.running { self.process = process }
        }
    }

    deinit {
        process?.terminate()
        try? FileManager.default.removeItem(at: home)
    }

    var running: Bool {
        queue.sync { process?.running == true }
    }

    /// What zsh printed for the line, in Completion.zsh's form, or nil when it didn't answer in
    /// time. A Tab still waiting when another comes is let go.
    func matches(of line: String, in folder: String) async -> String? {
        await withCheckedContinuation { answer in
            queue.async { [self] in
                waiting?.answer.resume(returning: nil)
                waiting = nil
                asked += 1
                let id = asked
                let request = home.appending(path: "request")
                guard let process, (try? "\(id)\n\(folder)\n\(line)\n".write(to: request, atomically: true, encoding: .utf8)) != nil else {
                    answer.resume(returning: nil)
                    return
                }
                received = []
                waiting = (id, answer)
                process.send(data: Self.key[...])
                queue.asyncAfter(deadline: .now() + Self.patience) { [weak self] in
                    guard let self, let waiting, waiting.id == id else { return }
                    self.waiting = nil
                    waiting.answer.resume(returning: nil)
                }
            }
        }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        guard let waiting else { return }
        // The terminal ends lines with \r\n.
        received += slice.filter { $0 != 0x0D }
        let mark = Array("\u{1E}\(waiting.id)\n".utf8)
        guard let start = received.firstRange(of: mark),
              let end = received[start.upperBound...].firstRange(of: mark) else { return }
        let answer = String(decoding: received[start.upperBound..<end.lowerBound], as: UTF8.self)
        self.waiting = nil
        received = []
        waiting.answer.resume(returning: answer)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        process = nil
        waiting?.answer.resume(returning: nil)
        waiting = nil
    }

    // Wide enough that zsh never wraps a line it draws.
    func getWindowSize() -> winsize {
        winsize(ws_row: 50, ws_col: 250, ws_xpixel: 0, ws_ypixel: 0)
    }
}
