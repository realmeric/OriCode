import AppKit
import SwiftTerm

/// One command from the composer's shell prompt, run in a terminal of its own in the thread's
/// folder. The user's login shell runs it interactively, so their PATH and aliases hold, and it
/// starts fresh each time: a `cd` in one command doesn't carry to the next. What it prints lands
/// in the transcript as it comes, in the terminal's colours. The terminal itself is drawn only
/// while the block is open: a program that takes the whole screen opens it, and so can you.
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
    /// A program has the whole screen, as vim and less do.
    private(set) var fullScreen = false
    /// Everything it printed, raw, for the store.
    @ObservationIgnored private(set) var output = Data()
    /// Told when it ends, when what it printed last arrives after that, and when a program takes
    /// the whole screen or lets it go.
    @ObservationIgnored var onEnd: ((ShellBlock) -> Void)?
    @ObservationIgnored var onTail: ((ShellBlock) -> Void)?
    @ObservationIgnored var onFullScreen: ((ShellBlock) -> Void)?
    /// The terminal: fed all along, drawn only while the block is open.
    @ObservationIgnored let view: BlockTerminalView
    @ObservationIgnored private let link: Link
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var redraw: Task<Void, Never>?
    /// Slices the pty has handed over, to tell when they've stopped coming.
    @ObservationIgnored private var slices = 0
    @ObservationIgnored private var readTo: Mark?

    var running: Bool { endedAt == nil }

    init(id: UUID, chatID: UUID, command: String, folder: String) {
        self.id = id
        self.chatID = chatID
        self.command = command
        self.folder = folder
        link = Link()
        // A zero frame keeps the options' size until the block is opened.
        view = BlockTerminalView(frame: .zero, font: TerminalPalette.font(size: 12.5),
                                 options: TerminalOptions(cols: Self.columns, rows: Self.rows, scrollback: Self.scrollback))
        TerminalPalette.dress(view)
        view.terminalDelegate = link
        link.block = self
        view.onBufferChange = { [weak self] in self?.bufferChanged() }
    }

    var terminal: Terminal { view.getTerminal() }

    /// False when the shell couldn't start: no pty left, no fork.
    func start() -> Bool {
        let process = LocalProcess(delegate: link)
        var environment = TerminalEnvironment.make()
        // What a command prints goes into the thread, not through a pager nobody can page.
        environment += ["PAGER=cat", "GIT_PAGER=cat"]
        TerminalEnvironment.closeOnExec()
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

    /// Keys for the program, as if typed into its terminal.
    func type(_ text: String) {
        process?.send(data: Array(text.utf8)[...])
    }

    /// Hangs it up, as closing a terminal window does: at quit, or when its thread goes.
    func end() {
        guard running, let shell = process?.shellPid, shell > 0 else { return }
        kill(shell, SIGHUP)
    }

    /// Everything it printed as plain lines.
    var text: String {
        ShellRender.plain(ShellRender.lines(terminal))
    }

    /// How far Claude has read: the row after the one its last line starts on, and the line
    /// before that one as Claude read it, which a clear or a program redrawing the screen writes
    /// over.
    struct Mark {
        let row: Int
        let before: (row: Int, text: String)?
    }

    /// What Claude hasn't read, as plain lines, and the mark reading it leaves; nil when there's
    /// nothing new. It's all of it the first time, and again once what Claude read is gone: a
    /// watcher cleared the screen, a program took it whole, the scrollback let go of the lines
    /// after the mark.
    func unread() -> (text: String, mark: Mark)? {
        let lines = numberedText()
        let from = firstUnread(lines)
        guard from.map({ $0 < lines.count }) ?? (readTo == nil || !lines.isEmpty) else { return nil }
        let mark = Mark(row: (lines.last?.row ?? -1) + 1, before: lines.count > 1 ? lines[lines.count - 2] : nil)
        return (lines[(from ?? 0)...].map(\.text).joined(separator: "\n"), mark)
    }

    func read(to mark: Mark) {
        readTo = mark
    }

    /// How many of its last lines Claude hasn't read, for the store, which rebuilds the terminal
    /// from the end of the output after a relaunch; -1 for all of them.
    var unreadLines: Int {
        let lines = numberedText()
        return firstUnread(lines).map { lines.count - $0 } ?? -1
    }

    private func numberedText() -> [(row: Int, text: String)] {
        ShellRender.numbered(terminal).map { ($0.row, ShellRender.plain($0.line)) }
    }

    /// The first line Claude hasn't read, or nil for all of them: it has read none, or there are
    /// fewer lines than it read, or the line before its last one has been written over.
    private func firstUnread(_ lines: [(row: Int, text: String)]) -> Int? {
        guard let readTo, (lines.last?.row ?? -1) >= readTo.row - 1 else { return nil }
        if let before = readTo.before, let first = lines.first, before.row >= first.row,
           !lines.contains(where: { $0.row == before.row && $0.text == before.text }) {
            return nil
        }
        return lines.firstIndex { $0.row >= readTo.row } ?? lines.count
    }

    fileprivate func received(_ bytes: ArraySlice<UInt8>) {
        view.feed(byteArray: bytes)
        output.append(contentsOf: bytes)
        if output.count > Self.kept * 2 { output = output.suffix(Self.kept) }
        slices += 1
        guard redraw == nil else { return }
        redraw = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            redraw = nil
            draw()
            if !running { onTail?(self) }
        }
    }

    private func draw() {
        let lines = ShellRender.lines(terminal)
        lineCount = lines.count
        screen = ShellRender.attributed(lines.suffix(ShellRender.shown))
    }

    private func bufferChanged() {
        let now = terminal.isCurrentBufferAlternate
        guard now != fullScreen else { return }
        fullScreen = now
        onFullScreen?(self)
    }

    /// The pty takes the terminal's size, and the program in it redraws for it.
    fileprivate func resized(columns: Int, rows: Int) {
        guard let process, process.childfd >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }

    fileprivate func ended(_ code: Int32?) {
        guard running else { return }
        redraw?.cancel()
        redraw = nil
        draw()
        endedAt = .now
        exitCode = code
        onEnd?(self)
        Task { await letGo() }
    }

    /// The exit can come before the last of what it printed, still in the pty or among the slices
    /// SwiftTerm hands the main queue a few at a time, and SwiftTerm's reads hold their
    /// LocalProcess weakly, so letting go of it at the exit loses that tail. It's kept until the
    /// pty has closed, which SwiftTerm marks by dropping the descriptor, and a turn of the main
    /// queue brings no more slices.
    private func letGo() async {
        var wait = 50
        while let process, process.childfd >= 0 {
            try? await Task.sleep(for: .milliseconds(wait))
            wait = min(wait * 2, 1000)
        }
        var seen = -1
        while seen != slices {
            seen = slices
            await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
        }
        process = nil
    }

    /// The pty and the terminal call back on the main queue.
    @MainActor
    private final class Link: LocalProcessDelegate, TerminalViewDelegate {
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
            MainActor.assumeIsolated {
                let terminal = block?.terminal
                return winsize(ws_row: UInt16(terminal?.rows ?? ShellBlock.rows), ws_col: UInt16(terminal?.cols ?? ShellBlock.columns),
                               ws_xpixel: 0, ws_ypixel: 0)
            }
        }

        // Keys typed into the open terminal, and what it answers a program's questions with.
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { block?.process?.send(data: data) }
        }

        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { block?.resized(columns: newCols, rows: newRows) }
        }

        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}

/// A block's terminal. The window moves by its background, and a view drawn on clear counts as
/// background, so a drag to select text would move the window instead.
final class BlockTerminalView: TerminalView {
    var onBufferChange: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func bufferActivated(source: Terminal) {
        super.bufferActivated(source: source)
        onBufferChange?()
    }
}
