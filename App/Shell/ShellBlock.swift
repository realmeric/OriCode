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
    /// Told when it ends, when what it printed last arrives after that, once its pty has closed
    /// and all of it is drawn, and when a program takes the whole screen or lets it go.
    @ObservationIgnored var onEnd: ((ShellBlock) -> Void)?
    @ObservationIgnored var onTail: ((ShellBlock) -> Void)?
    @ObservationIgnored var onClosed: ((ShellBlock) -> Void)?
    @ObservationIgnored var onFullScreen: ((ShellBlock) -> Void)?
    /// The terminal: fed all along, drawn only while the block is open, and let go of once the
    /// block has ended and been stored.
    @ObservationIgnored private(set) var view: BlockTerminalView?
    @ObservationIgnored private let link: Link
    @ObservationIgnored private var process: LocalProcess?
    @ObservationIgnored private var redraw: Task<Void, Never>?
    /// Slices the pty has handed over, to tell when they've stopped coming.
    @ObservationIgnored private var slices = 0
    /// The lines above the ones drawn, counted as they scroll off.
    @ObservationIgnored private var counted = ShellRender.LineCount()
    /// Wakes for the pty between the exit and its closing, and waits for a slice while it has
    /// output SwiftTerm hasn't read.
    @ObservationIgnored private var closing: (source: DispatchSourceRead, waiting: Bool)?
    @ObservationIgnored private var readTo: Mark?
    /// Once the terminal is gone, its last lines as numberedText read them, as many as Claude
    /// could be given.
    @ObservationIgnored private var lastLines: [(row: Int, text: String)] = []

    var running: Bool { endedAt == nil }

    init(id: UUID, chatID: UUID, command: String, folder: String) {
        self.id = id
        self.chatID = chatID
        self.command = command
        self.folder = folder
        link = Link()
        // A zero frame keeps the options' size until the block is opened.
        let view = BlockTerminalView(frame: .zero, font: TerminalPalette.font(size: 12.5),
                                     options: TerminalOptions(cols: Self.columns, rows: Self.rows, scrollback: Self.scrollback))
        TerminalPalette.dress(view)
        view.terminalDelegate = link
        link.block = self
        view.onBufferChange = { [weak self] in self?.bufferChanged() }
        self.view = view
    }

    var terminal: Terminal? { view?.getTerminal() }

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

    /// Everything it printed as plain lines, or once it has let go of its terminal, the end of it.
    var text: String {
        numberedText().map(\.text).joined(separator: "\n")
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
        guard let terminal else { return lastLines }
        return ShellRender.numbered(terminal).map { ($0.row, ShellRender.plain($0.line)) }
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
        view?.feed(byteArray: bytes)
        output.append(contentsOf: bytes)
        if output.count > Self.kept * 2 { output = output.suffix(Self.kept) }
        slices += 1
        if let closing, closing.waiting {
            self.closing?.waiting = false
            closing.source.resume()
        }
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
        guard let terminal else { return }
        let tail = ShellRender.tail(terminal)
        lineCount = tail.lines.count + counted.lines(above: tail.row, in: terminal)
        screen = ShellRender.attributed(tail.lines)
    }

    private func bufferChanged() {
        guard let now = terminal?.isCurrentBufferAlternate else { return }
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
    /// pty has closed, SwiftTerm has read the end, and a turn of the main queue brings no more
    /// slices. Then the block is drawn with all of it and can let go of its terminal. The pty
    /// closes with the shell, since macOS takes the terminal back from a job it left running,
    /// except when SwiftTerm stopped reading under a 4MB backlog, and never reads again once the
    /// shell has gone: then the block waits for good, and without waking.
    private func letGo() async {
        if let process, process.childfd >= 0 {
            await closed(process.childfd)
            // SwiftTerm reads the end after everything before it and marks it by dropping the
            // descriptor, a moment after the pty says so.
            for _ in 0..<200 where process.childfd >= 0 {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        var seen = -1
        while seen != slices {
            seen = slices
            await withCheckedContinuation { turn in DispatchQueue.main.async { turn.resume() } }
        }
        process = nil
        redraw?.cancel()
        redraw = nil
        draw()
        onClosed?(self)
    }

    /// Waits for the pty to close without waking while nothing happens on it. A read source wakes
    /// for output and for the end; output is SwiftTerm's to read, and until it does the source
    /// would wake again at once, so it waits for SwiftTerm's next slice.
    private func closed(_ descriptor: Int32) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .main)
            source.setEventHandler { [self] in
                MainActor.assumeIsolated {
                    // Nothing to read when it woke is the end.
                    if source.data == 0 {
                        source.cancel()
                        closing = nil
                        done.resume()
                        return
                    }
                    // Output SwiftTerm has already read is gone by now, and nothing to wait for.
                    // FIONREAD, whose macro Swift can't import, as SwiftTerm spells it.
                    var waiting: Int32 = 0
                    guard ioctl(descriptor, 0x4004667F, &waiting) == 0, waiting > 0 else { return }
                    source.suspend()
                    closing?.waiting = true
                }
            }
            closing = (source, false)
            source.activate()
        }
    }

    /// Lets go of the terminal and its view once the block has ended and been stored, keeping
    /// what the transcript draws, the output and, for Claude, as many of the last lines as it
    /// can be given: an ended block is never opened, and its lines don't change any more.
    func dropTerminal() {
        guard !running, process == nil, terminal != nil else { return }
        let lines = numberedText()
        var first = lines.endIndex
        var characters = 0
        while first > lines.startIndex, characters <= ShellContext.limit {
            first -= 1
            characters += lines[first].text.count + 1
        }
        lastLines = Array(lines[first...])
        view = nil
        counted = ShellRender.LineCount()
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
