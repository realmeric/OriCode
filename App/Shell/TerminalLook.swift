import AppKit
import CoreText
import SwiftTerm

/// Sixteen colours muted for dark glass. Black is a mid grey, so text drawn in it still reads.
enum TerminalPalette {
    /// A SwiftTerm view in the app's look: the terminal font, clear so the glass shows through,
    /// white selection rather than the system's accent colour, which the brief keeps out, and
    /// Option left alone, since it types @ { } [ ] | \ on Meriç's Turkish layout.
    static func dress(_ view: TerminalView) {
        view.font = font(size: 12.5)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.nativeBackgroundColor = .clear
        view.caretColor = NSColor(white: 0.92, alpha: 1)
        view.selectedTextBackgroundColor = NSColor(white: 1, alpha: 0.18)
        view.optionAsMetaKey = false
        view.caretViewTracksFocus = true
        view.installColors(ansi)
        // SwiftTerm's scroller is an overlay-style NSScroller with no scroll view around it to fade
        // it, so it stands as a dark strip down the right; hidden, its width goes to the text, and
        // the wheel still scrolls.
        for scroller in view.subviews where scroller is NSScroller {
            scroller.isHidden = true
        }
    }

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

    /// The sixteen, as 0xRRGGBB.
    static let rgb = [
        0x5C5C63, 0xF28C8C, 0x8CD999, 0xE6C98A, 0x8FB3F0, 0xD6A2E8, 0x86D1D1, 0xC8C8CC,
        0x7A7A82, 0xFFA8A8, 0xA8EBB3, 0xF2DBA6, 0xADC8FA, 0xE6BDF2, 0xA6E3E3, 0xEBEBEB,
    ]

    static var ansi: [SwiftTerm.Color] {
        rgb.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257, blue: UInt16(rgb & 0xFF) * 257)
        }
    }
}

/// The shell's environment: what the app was given by the system, never by whatever opened it,
/// so `claude` in the terminal doesn't think it's nested, saying it's OriCode's terminal.
enum TerminalEnvironment {
    /// SwiftTerm forks and execs without closing anything, so a shell would inherit every
    /// descriptor the app holds: the engine's pipes, whose end then never comes, its log, and
    /// other shells' terminals, which then never hang up. Each is marked to close at exec first.
    static func closeOnExec() {
        guard let open = try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd") else { return }
        for name in open {
            guard let fd = Int32(name), fd > 2 else { continue }
            let flags = fcntl(fd, F_GETFD)
            if flags >= 0 { _ = fcntl(fd, F_SETFD, flags | FD_CLOEXEC) }
        }
    }

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
