import Foundation

/// ⌘K's way to the terminal, all of it through runInTerminal: show or hide it, run a command in
/// it, and carry the thread's session over to the `claude` in it.
extension AppModel {
    private static let terminalRecentsKey = "terminalRecents"

    /// The last ten commands run from ⌘K, newest first.
    var terminalRecents: [String] {
        UserDefaults.standard.stringArray(forKey: Self.terminalRecentsKey) ?? []
    }

    var terminalCommands: [PaletteItem] {
        let noFolder: String? = workingFolder == nil ? "Add a project first" : nil
        return [
            command("terminal", terminalShown ? "Hide terminal" : "Terminal", icon: "terminal", shortcut: "⌘J",
                    keywords: ["shell", "zsh", "console", "command line"], unavailable: noFolder) { [weak self] in
                self?.toggleTerminal()
            },
            PaletteItem(id: "terminal.run", kind: .command, title: "Run in terminal…", keywords: ["shell", "command", "zsh", "execute"],
                        icon: "apple.terminal", unavailable: noFolder,
                        action: .list(PaletteList(title: "Run", placeholder: "A command for the terminal", items: { [weak self] in
                            self?.terminalRecents.map { line in self?.runRow(line, id: "terminal.recent." + line) }.compactMap { $0 } ?? []
                        }, typed: { [weak self] line in
                            self?.runRow(line, title: "Run “\(line)”", id: "terminal.typed")
                        }))),
            continueInClaudeCode,
        ]
    }

    private func runRow(_ line: String, title: String? = nil, id: String) -> PaletteItem {
        PaletteItem(id: id, kind: .choice, title: title ?? line, icon: "chevron.right", action: .run { [weak self] in
            guard let self, runInTerminal(line) else { return }
            var recents = terminalRecents.filter { $0 != line }
            recents.insert(line, at: 0)
            UserDefaults.standard.set(Array(recents.prefix(10)), forKey: Self.terminalRecentsKey)
        })
    }

    /// The thread's session in the terminal's own `claude`. The app's CLI for the thread lets go
    /// of it first, so two processes never write one session.
    private var continueInClaudeCode: PaletteItem {
        let unavailable: String? = {
            guard let chat else { return "No thread is open" }
            guard chat.sessionId != nil else { return "Send it a message first" }
            if conversation(for: chat).running { return "Wait for the turn to end" }
            if terminals.existing(for: chat.cwd)?.busy == true { return "The terminal is busy" }
            return nil
        }()
        return command("terminal.claude", "Continue in Claude Code", icon: "arrow.up.forward.app",
                       subtitle: "Turns taken there won't show here", keywords: ["claude", "cli", "resume", "session", "terminal"],
                       unavailable: unavailable) { [weak self] in
            guard let self, let chat, let session = chat.sessionId else { return }
            let thread = chat.id
            let folder = chat.cwd
            Task {
                _ = try? await self.engine.request("close", ["threadId": .string(thread.uuidString)])
                self.runInTerminal("cd \(folder.shellQuoted) && claude --resume \(session.shellQuoted)", in: folder)
            }
        }
    }
}

extension String {
    /// In single quotes, so the shell reads it as one literal word: a quote inside becomes '\''.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
