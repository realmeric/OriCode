import AppKit
import CoreText
import SwiftTerm

/// One login shell in one folder, drawn by SwiftTerm. It lives while the terminal is hidden, so
/// ⌘J brings back the same shell with its scrollback.
@MainActor
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let folder: String
    let view: ShellView
    var onExit: (() -> Void)?
    /// The shell has exited; its last screen stays up while the terminal goes away.
    private(set) var ended = false
    private var watcher: DispatchSourceProcess?

    init(folder: String) {
        self.folder = folder
        view = ShellView(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        super.init()
        view.processDelegate = self
        view.font = TerminalPalette.font(size: 12.5)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        // Clear, so the glass shows through; this version doesn't carry it to the layer itself.
        view.nativeBackgroundColor = .clear
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.caretColor = NSColor(white: 0.92, alpha: 1)
        // White, not the system's accent colour, which the brief keeps out.
        view.selectedTextBackgroundColor = NSColor(white: 1, alpha: 0.18)
        // Option types @ { } [ ] | \ on Meriç's Turkish layout, so it can't be Meta.
        view.optionAsMetaKey = false
        view.caretViewTracksFocus = true
        view.installColors(TerminalPalette.ansi)
        // This version's scroller is always drawn, a track down the right; the wheel still scrolls.
        for scroller in view.subviews where scroller is NSScroller {
            scroller.isHidden = true
        }
        let shell = TerminalEnvironment.shell
        Self.closeOnExec()
        view.startProcess(executable: shell, args: [], environment: TerminalEnvironment.make(),
                          execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: folder)
        let master = view.process.childfd
        if master >= 0 { _ = fcntl(master, F_SETFD, fcntl(master, F_GETFD) | FD_CLOEXEC) }
        // A shell that couldn't start (no pty left, no fork) is over, so the next ⌘J tries again.
        guard view.process.shellPid > 0 else {
            ended = true
            return
        }
        watch(view.process.shellPid)
    }

    /// SwiftTerm forks and execs without closing anything, so a shell would inherit every
    /// descriptor the app holds: the engine's pipes, whose end then never comes, its log, and
    /// other shells' terminals, which then never hang up. Each is marked to close at exec first.
    private static func closeOnExec() {
        guard let open = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return }
        for name in open {
            guard let fd = Int32(name), fd > 2 else { continue }
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

    /// SwiftTerm stops watching the shell once the terminal reads its end, which usually comes
    /// first, so it never says the shell exited and never reaps it. This watches for itself.
    private func watch(_ pid: pid_t) {
        guard pid > 0 else { return }
        let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        watcher.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watcher?.cancel()
                self.ended = true
                self.onExit?()
            }
        }
        watcher.activate()
        self.watcher = watcher
    }

    /// What holds the terminal when it isn't the shell at its prompt: vim, a build, claude, or
    /// fzf, which zsh's key bindings run as $(…) inside the shell's own process group.
    var foreground: String? {
        let fd = view.process.childfd
        let shell = view.process.shellPid
        guard !ended, fd >= 0, shell > 0 else { return nil }
        let group = tcgetpgrp(fd)
        if group > 0, group != shell { return Self.name(of: group) }
        var members = [pid_t](repeating: 0, count: 64)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(shell), &members, Int32(members.count * MemoryLayout<pid_t>.size))
        return members.prefix(max(0, Int(bytes) / MemoryLayout<pid_t>.size)).first { $0 > 0 && $0 != shell }.map(Self.name(of:))
    }

    var busy: Bool { foreground != nil }

    private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 64)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return "A command" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Types a line into the shell and runs it: ^U first clears anything half typed, and a shell
    /// that takes bracketed paste gets the line as a paste, so nothing in it acts as a key.
    func type(_ command: String) {
        Task { @MainActor in
            // A shell that has only just started gets the line once it has drawn its prompt:
            // typed sooner, the terminal echoes it once above the prompt.
            if !view.spoken {
                for _ in 0..<40 where !view.spoken { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let line = view.getTerminal().bracketedPasteMode ? "\u{1b}[200~" + command + "\u{1b}[201~" : command
            view.send(txt: "\u{15}" + line + "\r")
        }
    }

    /// Hangs the shell up, as closing a terminal window does, and zsh passes the hangup on to its
    /// jobs. SwiftTerm's terminate() doesn't do it: the shell ignores its SIGTERM, and the pty
    /// stays open while a read is pending. The watcher reaps the shell and marks it ended.
    func end() {
        // Once reaped, the pid may be someone else's by now.
        guard !ended else { return }
        kill(view.process.shellPid, SIGHUP)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    // Rarely called; the watcher above is what hears the shell end.
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {}
}

/// The window moves by its background, and a view drawn on clear counts as background, so a drag
/// to select text would move the window instead.
final class ShellView: LocalProcessTerminalView {
    /// Whether the shell has written anything yet.
    private(set) var spoken = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        spoken = true
        super.dataReceived(slice: slice)
    }
}

/// The shells, one per folder, made the first time a folder's terminal opens.
@MainActor
@Observable
final class TerminalStore {
    private(set) var sessions: [String: TerminalSession] = [:]
    /// A shell ended by itself (`exit`), with its folder.
    @ObservationIgnored var onExit: ((String) -> Void)?
    @ObservationIgnored private var activity: NSObjectProtocol?

    static func key(_ folder: String) -> String {
        URL(filePath: folder).standardizedFileURL.path
    }

    /// The folder's shell if it's still running.
    func existing(for folder: String) -> TerminalSession? {
        sessions[Self.key(folder)].flatMap { $0.ended ? nil : $0 }
    }

    /// The folder's shell, started if there's none or it has exited. Nil for a folder that isn't
    /// there any more, since a failed chdir would leave the shell somewhere else, and when the
    /// shell couldn't start.
    func session(for folder: String) -> TerminalSession? {
        let key = Self.key(folder)
        if let found = sessions[key], !found.ended { return found }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: key, isDirectory: &directory), directory.boolValue else { return nil }
        let session = TerminalSession(folder: key)
        guard !session.ended else { return nil }
        session.onExit = { [weak self, weak session] in
            guard let self else { return }
            hold()
            onExit?(key)
            // Let go of it once the terminal has slid away showing its last screen, so a folder
            // that's gone doesn't keep a dead shell's terminal open until quit.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session, sessions[key] === session else { return }
                sessions[key] = nil
            }
        }
        sessions[key] = session
        hold()
        return session
    }

    /// Hangs the folder's shell up. The session stays until its shell has gone, so its watcher
    /// can reap it; the next shell for the folder replaces it.
    func end(folder: String) {
        sessions[Self.key(folder)]?.end()
    }

    func endAll() {
        for session in sessions.values { session.end() }
    }

    /// What's running in the terminals, for the question at quit: "sleep in alpha".
    var running: [String] {
        sessions.values.compactMap { session in
            session.foreground.map { "\($0) in \(URL(filePath: session.folder).lastPathComponent)" }
        }.sorted()
    }

    /// While a shell is alive the app doesn't nap, so a build left running in the terminal keeps
    /// its speed and its output keeps arriving.
    private func hold() {
        let alive = sessions.values.contains { !$0.ended }
        if alive, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "A shell is open in the terminal")
        } else if !alive, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// The shell whose view has the keyboard, if one does.
    func owner(of responder: NSResponder?) -> TerminalSession? {
        guard let view = responder as? NSView else { return nil }
        return sessions.values.first { view === $0.view || view.isDescendant(of: $0.view) }
    }
}

/// Sixteen colours muted for dark glass. Black is a mid grey, so text drawn in it still reads.
enum TerminalPalette {
    /// A Nerd Font when one is installed, since a prompt drawn with its icons (Powerlevel10k,
    /// Starship) shows boxes in any other, and SF Mono otherwise. SF Mono can't borrow the icons:
    /// the system font ignores a cascade list.
    static func font(size: CGFloat) -> NSFont {
        let fonts = NSFontManager.shared
        let nerd = fonts.availableFontFamilies
            .filter { $0.hasSuffix(" NF") || $0.contains("Nerd Font") }
            .sorted()
            .lazy
            .compactMap { fonts.font(withFamily: $0, traits: [], weight: 5, size: size) }
            // The symbols-only Nerd Fonts, a fallback for other terminals, have no letters.
            .first { $0.isFixedPitch && hasLetters($0) }
        return nerd ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func hasLetters(_ font: NSFont) -> Bool {
        let letters = Array("Wa".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: letters.count)
        return CTFontGetGlyphsForCharacters(font, letters, &glyphs, letters.count)
    }

    static var ansi: [SwiftTerm.Color] {
        [
            0x5C5C63, 0xF28C8C, 0x8CD999, 0xE6C98A, 0x8FB3F0, 0xD6A2E8, 0x86D1D1, 0xC8C8CC,
            0x7A7A82, 0xFFA8A8, 0xA8EBB3, 0xF2DBA6, 0xADC8FA, 0xE6BDF2, 0xA6E3E3, 0xEBEBEB,
        ].map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257, blue: UInt16(rgb & 0xFF) * 257)
        }
    }
}

/// The shell's environment: what the app was given by the system, never by whatever opened it,
/// so `claude` in the terminal doesn't think it's nested, saying it's OriCode's terminal.
enum TerminalEnvironment {
    /// The user's login shell. SwiftTerm's child carries on as a copy of the app when exec fails,
    /// so only a shell that's there will do.
    static var shell: String {
        let named = [ProcessInfo.processInfo.environment["SHELL"], getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }]
        return named.compactMap { $0 }.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? "/bin/zsh"
    }

    static func make() -> [String] {
        // What an app opened from the Dock is given, and nothing a terminal or a Claude Code
        // session that opened this one left behind (GIT_EDITOR=true, TMUX, CLAUDECODE): the login
        // shell builds the rest from the user's own profile.
        let kept = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH", "SSH_AUTH_SOCK", "LANG", "COMMAND_MODE", "__CF_USER_TEXT_ENCODING", "CLAUDE_CONFIG_DIR"]
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            kept.contains(key) || key.hasPrefix("LC_")
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "OriCode"
        environment["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if environment["LANG", default: ""].isEmpty {
            // As Terminal sets it: the Mac's language and region, where there's such a locale.
            let mine = [Locale.current.language.languageCode?.identifier, Locale.current.region?.identifier]
                .compactMap { $0 }.joined(separator: "_") + ".UTF-8"
            environment["LANG"] = FileManager.default.fileExists(atPath: "/usr/share/locale/" + mine) ? mine : "en_US.UTF-8"
        }
        if let entry = getpwuid(getuid()) {
            environment["HOME"] = environment["HOME"] ?? String(cString: entry.pointee.pw_dir)
            environment["USER"] = environment["USER"] ?? String(cString: entry.pointee.pw_name)
            environment["LOGNAME"] = environment["LOGNAME"] ?? String(cString: entry.pointee.pw_name)
        }
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment.map { "\($0.key)=\($0.value)" }
    }
}
