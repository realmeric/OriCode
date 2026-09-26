import AppKit
import SwiftUI

/// ⌘J and the ways into a block from elsewhere: the composer as a shell prompt, a block drawn full
/// over the conversation, and lines from ⌘K or your own actions run as blocks in the thread.
extension AppModel {
    /// ⌘J: the composer as a shell prompt for the thread's folder, or back. With a block open, it
    /// puts the block back in the thread first.
    func toggleShellPrompt() {
        if openShell != nil {
            closeBlock()
            return
        }
        guard project != nil else { return }
        shellPrompt.toggle()
        composerFocus += 1
    }

    /// The block drawn full over the open thread, if one is.
    var openShell: ShellBlock? {
        chat.flatMap { openBlocks[$0.id] }.flatMap { shellBlocks[$0] }
    }

    /// Draws a running block full over its thread, to be typed into. One whose thread isn't on
    /// screen is open there when it comes back.
    func open(_ block: ShellBlock) {
        guard block.running else { return }
        guard block.chatID == chat?.id else {
            openBlocks[block.chatID] = block.id
            return
        }
        if reviewShown { closeReview() }
        modelPickerShown = false
        withAnimation(Motion.move) { openBlocks[block.chatID] = block.id }
    }

    /// Puts the open thread's block back in the thread.
    func closeBlock() {
        if let block = openShell { close(block) }
    }

    /// Puts a block back in its thread, handing the keyboard on if that thread is on screen.
    func close(_ block: ShellBlock) {
        guard openBlocks[block.chatID] == block.id else { return }
        withAnimation(Motion.move) { openBlocks[block.chatID] = nil }
        if block.chatID == chat?.id { returnKeyboard() }
    }

    /// Gives the open block's terminal the keyboard back when a panel that came over it goes.
    func focusOpenBlock() {
        guard let view = openShell?.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Whether something over the thread has the keyboard on purpose, which a block opening or
    /// closing by itself leaves alone: ⌘K, ⌘P, a rename, the picker, a file.
    var keyboardTaken: Bool {
        commandCenterShown || fileFinderShown || renamingChatID != nil || modelPickerShown || openFile != nil
    }

    /// Whether the composer takes the keyboard when nothing else asks for it: not under an open
    /// block, whose program has it, nor while a card waits, whose Return and Esc the field would eat.
    var composerTakesKeyboard: Bool {
        openShell == nil && currentConversation?.waitingAsk == nil
    }

    /// Hands the keyboard back when a surface that had it goes, to an open block or else the
    /// composer, unless it went somewhere on purpose. With a card waiting it stays with the
    /// window, so Return presses the card's button.
    func returnKeyboard() {
        guard !keyboardTaken else { return }
        if openShell != nil { focusOpenBlock() } else if composerTakesKeyboard { composerFocus += 1 }
    }

    private static let shellHistoryKey = "shellHistory"

    /// Lines run from the shell prompt, oldest first, for ↑ and ↓ there.
    var shellHistory: [String] {
        UserDefaults.standard.stringArray(forKey: Self.shellHistoryKey) ?? []
    }

    func rememberCommand(_ line: String) {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        var history = shellHistory
        if history.last != line { history.append(line) }
        UserDefaults.standard.set(Array(history.suffix(200)), forKey: Self.shellHistoryKey)
    }

    /// What the user's shell can run, for Tab at the prompt: commands on its PATH, aliases,
    /// builtins and functions, the way its own completion would offer them. Asked once, as the
    /// prompt opens, and a Tab that comes first waits for it.
    func shellCommands() async -> [String] {
        if let shellNames { return await shellNames.value }
        let asking = Task.detached(priority: .userInitiated) { ShellNames.read() }
        shellNames = asking
        return await asking.value
    }

    func loadShellCommands() {
        Task { _ = await shellCommands() }
    }

    /// A line from ⌘K or one of your actions, run as a block in the open thread.
    @discardableResult
    func runInThread(_ line: String, open: Bool = false) -> Bool {
        guard let block = runCommand(line) else { return false }
        if open { self.open(block) }
        return true
    }
}

/// Reads what an interactive login shell knows as commands. zsh lists its tables, bash has
/// compgen, and any other shell gets its PATH read from the folders.
enum ShellNames {
    static func read() -> [String] {
        let shell = TerminalEnvironment.shell
        let name = (shell as NSString).lastPathComponent
        let script = switch name {
        case "zsh": "print -rl -- ${(k)commands} ${(k)aliases} ${(k)builtins} ${(k)functions} ${(k)reswords}"
        case "bash": "compgen -abck"
        default: "echo $PATH | tr : '\\n' | while read d; do ls \"$d\" 2>/dev/null; done"
        }
        let process = Process()
        process.executableURL = URL(filePath: shell)
        process.arguments = ["-l", "-i", "-c", script]
        process.environment = Dictionary(TerminalEnvironment.make().compactMap { pair -> (String, String)? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { _, last in last })
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        // A shell whose profile hangs doesn't hold Tab up for long.
        let deadline = DispatchTime.now() + 5
        DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        // zsh's own completion functions start with an underscore; nobody types those.
        return Array(Set(names.filter { !$0.isEmpty && !$0.hasPrefix("_") && !$0.contains(" ") })).sorted()
    }
}
