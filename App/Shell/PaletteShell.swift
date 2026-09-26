import Foundation

/// ⌘K's way to the shell prompt: toggle it, run a line as a block, and carry the thread's session
/// over to a `claude` in a block of its own.
extension AppModel {
    private static let terminalRecentsKey = "terminalRecents"

    /// The last ten lines run from ⌘K, newest first.
    var terminalRecents: [String] {
        UserDefaults.standard.stringArray(forKey: Self.terminalRecentsKey) ?? []
    }

    var terminalCommands: [PaletteItem] {
        let noFolder: String? = workingFolder == nil ? "Add a project first" : nil
        return [
            command("terminal", shellPrompt ? "Leave the shell prompt" : "Shell prompt", icon: "terminal", shortcut: "⌘J",
                    keywords: ["shell", "zsh", "console", "command line", "terminal", "!"], unavailable: noFolder) { [weak self] in
                self?.toggleShellPrompt()
            },
            PaletteItem(id: "terminal.run", kind: .command, title: "Run a command…", keywords: ["shell", "command", "zsh", "execute", "terminal"],
                        icon: "apple.terminal", unavailable: noFolder,
                        action: .list(PaletteList(title: "Run", placeholder: "A command for the thread's folder", items: { [weak self] in
                            self?.terminalRecents.map { line in self?.runRow(line, id: "terminal.recent." + line) }.compactMap { $0 } ?? []
                        }, typed: { [weak self] line in
                            self?.runRow(line, title: "Run “\(line)”", id: "terminal.typed")
                        }, typedFirst: true))),
            continueInClaudeCode,
        ]
    }

    private func runRow(_ line: String, title: String? = nil, id: String) -> PaletteItem {
        PaletteItem(id: id, kind: .choice, title: title ?? line, icon: "chevron.right", action: .run { [weak self] in
            guard let self, runInThread(line) else { return }
            var recents = terminalRecents.filter { $0 != line }
            recents.insert(line, at: 0)
            UserDefaults.standard.set(Array(recents.prefix(10)), forKey: Self.terminalRecentsKey)
        })
    }

    /// The thread's session in Claude Code's own terminal interface, in a block opened full. The
    /// app's CLI for the thread lets go of it first, so two processes never write one session, and
    /// a thread already handed over opens the block it's in.
    private var continueInClaudeCode: PaletteItem {
        let unavailable: String? = {
            guard let chat else { return "No thread is open" }
            guard chat.sessionId != nil else { return "Send it a message first" }
            if conversation(for: chat).running { return "Wait for the turn to end" }
            // Closing the CLI would end its subagents and background commands with it.
            if !conversation(for: chat).heads.isEmpty { return "Wait for its tasks to finish" }
            return nil
        }()
        return command("terminal.claude", "Continue in Claude Code", icon: "arrow.up.forward.app",
                       subtitle: "Turns taken there won't show here", keywords: ["claude", "cli", "resume", "session", "terminal"],
                       unavailable: unavailable) { [weak self] in
            guard let self, let chat, let session = chat.sessionId else { return }
            if let block = handedOff[chat.id].flatMap({ shellBlocks[$0] }), block.running {
                open(block)
                return
            }
            Task {
                _ = try? await self.engine.request("close", ["threadId": .string(chat.id.uuidString)])
                if let block = self.runCommand("claude --resume \(session.shellQuoted)", forModel: false) {
                    self.handOff(chat, to: block)
                }
            }
        }
    }

    /// The session is the block's now: it's opened, the thread won't send while it runs, and a
    /// wait for a limit to reset is called off, since going on by itself would be a second writer.
    func handOff(_ chat: Chat, to block: ShellBlock) {
        open(block)
        handedOff[chat.id] = block.id
        conversation(for: chat).cancelResume()
        scheduleResumes()
    }
}

extension String {
    /// In single quotes, so the shell reads it as one literal word: a quote inside becomes '\''.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
