import AppKit
import SwiftTerm

/// One command from the composer's shell prompt, run in a terminal of its own in the thread's
/// folder. The user's login shell runs it interactively, so their PATH and aliases hold, and it
/// starts fresh each time: a `cd` in one command doesn't carry to the next. What it prints lands
/// in the transcript as it comes, in the terminal's colours; nothing draws the terminal itself.
@MainActor
@Observable
final class ShellBlock {
    /// The width programs format for, about what the column holds in the terminal's font.
    nonisolated static let columns = 96
    nonisolated static let rows = 24
    nonisolated static let scrollback = 10_000
    /// What the thread's store keeps of a block's output: the end of it.
    nonisolated static let kept = 256 * 1024

    let id: UUID
    let chatID: UUID
    let command: String
    let folder: String
    let startedAt = Date.now
    private(set) var endedAt: Date?
    private(set) var exitCode: Int32?
    /// The last lines it printed, as the transcript draws them, and how many lines there are.
    private(set) var screen = AttributedString()
    private(set) var lineCount = 0
    /// Everything it printed, raw, for the store.
    @ObservationIgnored private(set) var output = Data()
    /// Told when it ends.
    @ObservationIgnored var onEnd: ((ShellBlock) -> Void)?
    @ObservationIgnored let terminal: Terminal
    @ObservationIgnored private let link: Link
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var redraw: Task<Void, Never>?

    var running: Bool { endedAt == nil }

    init(id: UUID, chatID: UUID, command: String, folder: String) {
        self.id = id
        self.chatID = chatID
        self.command = command
        self.folder = folder
        link = Link()
        terminal = Terminal(delegate: link, options: TerminalOptions(cols: Self.columns, rows: Self.rows, scrollback: Self.scrollback))
        link.block = self
    }

    /// False when the shell couldn't start: no pty left, no fork.
    func start() -> Bool {
        let process = LocalProcess(delegate: link)
        var environment = TerminalEnvironment.make()
        // What a command prints goes into the thread, not through a pager nobody can page.
        environment += ["PAGER=cat", "GIT_PAGER=cat"]
        TerminalSession.closeOnExec()
        process.startProcess(executable: TerminalEnvironment.shell, args: ["-l", "-i", "-c", command],
                             environment: environment, currentDirectory: folder)
        let master = process.childfd
        if master >= 0 { _ = fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC) }
        guard process.shellPid > 0 else {
            ended(nil)
            return false
        }
        self.process = process
        return true
    }

    /// ⌃C, the way a terminal stops what's in front of it, and a hangup two seconds on for what
    /// ignores it.
    func stop() {
        guard running, let process else { return }
        process.send(data: [0x03])
        let shell = process.shellPid
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, running else { return }
            kill(shell, SIGHUP)
        }
    }

    /// Hangs it up, as closing a terminal window does: at quit, or when its thread goes.
    func end() {
        guard running, let shell = process?.shellPid, shell > 0 else { return }
        kill(shell, SIGHUP)
    }

    /// Everything it printed as plain lines, for Claude.
    var text: String {
        ShellRender.plain(ShellRender.lines(terminal))
    }

    fileprivate func received(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(buffer: bytes)
        output.append(contentsOf: bytes)
        if output.count > Self.kept * 2 { output = output.suffix(Self.kept) }
        guard redraw == nil else { return }
        redraw = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            redraw = nil
            draw()
        }
    }

    private func draw() {
        let lines = ShellRender.lines(terminal)
        lineCount = lines.count
        screen = ShellRender.attributed(lines.suffix(ShellRender.shown))
    }

    fileprivate func ended(_ code: Int32?) {
        guard running else { return }
        redraw?.cancel()
        redraw = nil
        draw()
        endedAt = .now
        exitCode = code
        process = nil
        onEnd?(self)
    }

    /// The pty and the terminal call back on the main queue.
    @MainActor
    private final class Link: LocalProcessDelegate, TerminalDelegate {
        weak var block: ShellBlock?

        // SwiftTerm hands over waitpid's status as it is: the code a shell would say is in its
        // second byte, and a signal that ended it in its first, which a shell says as 128 and it.
        nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            let code = exitCode.map { $0 & 0x7F == 0 ? ($0 >> 8) & 0xFF : 128 + ($0 & 0x7F) }
            MainActor.assumeIsolated { block?.ended(code) }
        }

        nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { block?.received(slice) }
        }

        nonisolated func getWindowSize() -> winsize {
            winsize(ws_row: UInt16(ShellBlock.rows), ws_col: UInt16(ShellBlock.columns), ws_xpixel: 0, ws_ypixel: 0)
        }

        // What the terminal answers a program's questions with goes back to it.
        nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { block?.process?.send(data: data) }
        }
    }
}
