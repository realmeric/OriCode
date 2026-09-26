import AppKit
import SwiftUI

/// The composer's shell prompt: a command runs in its own terminal in the thread's folder and its
/// block goes into the thread, and Claude reads every block since your last message with the next
/// one, the way Claude Code's own `!` does.
extension AppModel {
    /// Runs a line from the shell prompt in the open thread, starting one if there's none.
    @discardableResult
    func runCommand(_ line: String) -> ShellBlock? {
        let command = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let chat = chat ?? newChat() else { return nil }
        guard FileManager.default.fileExists(atPath: chat.cwd) else {
            say("This thread's folder isn't there any more.")
            return nil
        }
        let conversation = conversation(for: chat)
        // Known before its block goes into the thread, whose view looks it up as it first draws.
        let block = ShellBlock(id: UUID(), chatID: chat.id, command: command, folder: chat.cwd)
        block.onEnd = { [weak self] block in self?.shellEnded(block) }
        // A program taking the whole screen opens its block over the thread, and letting it go
        // puts the block back.
        block.onFullScreen = { [weak self] block in
            guard let self else { return }
            if block.fullScreen { open(block) } else { close(block) }
        }
        shellBlocks[block.id] = block
        withAnimation(Motion.fade) { conversation.shellStarted(ShellRun(command: command, folder: chat.cwd), id: block.id) }
        holdForShells()
        if !block.start() { say("The shell couldn't start.") }
        return block
    }

    private func shellEnded(_ block: ShellBlock) {
        holdForShells()
        store(block)
        close(block)
    }

    /// Writes a command's block into its thread as it stands.
    private func store(_ block: ShellBlock) {
        let chatID = block.chatID
        guard let chat = try? context.fetch(.init(predicate: #Predicate<Chat> { $0.id == chatID })).first else { return }
        let conversation = conversation(for: chat)
        guard case .shell(_, var run) = conversation.items.last(where: { $0.id == block.id }) else { return }
        run.endedAt = block.endedAt
        run.exitCode = block.exitCode
        run.output = block.output.suffix(ShellBlock.kept)
        conversation.shellChanged(block.id, run)
    }

    /// The open thread's latest command still running whose block has gone out of view, and how
    /// many more are, for the line under the composer. The one open over the thread is in view.
    var runningOutOfView: (block: ShellBlock, more: Int)? {
        guard let chat else { return nil }
        let away = shellBlocks.values
            .filter { $0.chatID == chat.id && $0.running && shellsInView[$0.id] == false && openBlocks[chat.id] != $0.id }
            .sorted { $0.startedAt > $1.startedAt }
        return away.first.map { ($0, away.count - 1) }
    }

    /// What's running from the shell prompt, for the question at quit: "make test in alpha".
    var runningCommands: [String] {
        shellBlocks.values.filter(\.running).sorted { $0.startedAt < $1.startedAt }.map { block in
            "\(block.command.split(separator: " ").first.map(String.init) ?? block.command) in \(URL(filePath: block.folder).lastPathComponent)"
        }
    }

    /// Hangs every command up, at quit, keeping what each has printed: the app is gone before
    /// they are.
    func endShells() {
        for block in shellBlocks.values where block.running {
            store(block)
            block.end()
        }
    }

    /// A sentence for a dialog about something that ends these threads' commands: "This also stops
    /// npm and make."
    func shellsStopping(in chats: [Chat]) -> String? {
        let threads = Set(chats.map(\.id))
        let running = shellBlocks.values.filter { $0.running && threads.contains($0.chatID) }.sorted { $0.startedAt < $1.startedAt }
            .map { $0.command.split(separator: " ").first.map(String.init) ?? $0.command }
        guard !running.isEmpty else { return nil }
        let list = running.count == 1 ? running[0] : running.dropLast().joined(separator: ", ") + " and " + running[running.count - 1]
        return "This also stops \(list)."
    }

    /// Hangs up the commands a thread has running, when it's deleted.
    func endShells(of chat: Chat) {
        for block in shellBlocks.values where block.chatID == chat.id { block.end() }
    }

    /// A command left running keeps its speed, and its output keeps coming, behind other windows.
    private func holdForShells() {
        let running = shellBlocks.values.contains { $0.running }
        if running, shellActivity == nil {
            shellActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "A command is running")
        } else if !running, let activity = shellActivity {
            ProcessInfo.processInfo.endActivity(activity)
            shellActivity = nil
        }
    }

    /// Every block in the thread with something Claude hasn't read, as Claude Code gives its `!`
    /// commands: the command, then what it printed since Claude last read it. Marks them read.
    func shellContext(for chat: Chat) -> String? {
        let conversation = conversation(for: chat)
        var parts: [String] = []
        for item in conversation.items {
            guard case .shell(let id, var run) = item else { continue }
            let live = shellBlocks[id]
            let text = live?.text ?? ShellRender.plain(ShellRender.lines(ShellRender.replay(run.output)))
            let running = live?.running ?? false
            guard text.count > run.sentUpTo || run.sentUpTo < 0 else { continue }
            parts.append(ShellContext.block(command: run.command, text: text, from: max(run.sentUpTo, 0),
                                            exitCode: live?.exitCode ?? run.exitCode, running: running))
            run.sentUpTo = text.count
            conversation.shellChanged(id, run)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}

/// How a block reads to Claude.
enum ShellContext {
    /// What Claude reads of one command's output at most: the end of it.
    static let limit = 30_000

    static func block(command: String, text: String, from: Int, exitCode: Int32?, running: Bool) -> String {
        var output = String(text.dropFirst(from))
        if output.count > limit {
            let cut = output.dropFirst(output.count - limit)
            output = "[\(output.count - limit) earlier characters left out]\n" + cut
        }
        var lines = ["<bash-input>\(command)</bash-input>", "<bash-stdout>\(output)</bash-stdout>"]
        if running {
            lines.append("(It's still running.)")
        } else if let exitCode, exitCode != 0 {
            lines.append("(It exited with code \(exitCode).)")
        }
        return lines.joined(separator: "\n")
    }
}
