import AppKit
import SwiftUI

/// ⌘J: a shell for the open thread's folder over the glass, and a way for the command center to
/// type into it.
extension AppModel {
    func toggleTerminal() {
        if terminalShown { closeTerminal() } else { openTerminal() }
    }

    func openTerminal() {
        guard let folder = workingFolder else { return }
        startTerminal(in: folder)
        modelPickerShown = false
        if reviewShown { closeReview() }
        withAnimation(Motion.move) { terminalShown = true }
    }

    func closeTerminal() {
        guard terminalShown else { return }
        // The composer gets the keyboard only if the terminal had it: a rename in the drawer
        // keeps it.
        let hadKeys = terminals.owner(of: NSApp.mainWindow?.firstResponder) != nil
        withAnimation(Motion.move) { terminalShown = false }
        if hadKeys { composerFocus += 1 }
    }

    /// Gives the terminal back the keyboard when a panel that came over it goes.
    func focusTerminal() {
        guard terminalShown, let folder = workingFolder, let view = terminals.existing(for: folder)?.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// Makes the folder's shell if there's none, and when the terminal shows, gives it the keys.
    func startTerminal(in folder: String) {
        if terminals.onExit == nil {
            terminals.onExit = { [weak self] folder in
                // `exit` closes the terminal it was typed in.
                guard let self, let open = self.workingFolder, TerminalStore.key(open) == folder else { return }
                self.closeTerminal()
            }
        }
        guard let session = terminals.session(for: folder) else { return }
        if terminalShown { session.view.window?.makeFirstResponder(session.view) }
    }

    /// Types a command into the open thread's shell and runs it, showing the terminal. A folder
    /// that's gone, or a shell busy with something else, gets nothing typed, and says so.
    @discardableResult
    func runInTerminal(_ command: String, in folder: String? = nil) -> Bool {
        guard let folder = folder ?? workingFolder else { return false }
        // A live shell can outlast its folder, and a command meant for the folder mustn't run there.
        guard FileManager.default.fileExists(atPath: folder) else {
            say("The folder isn't there any more.")
            return false
        }
        guard let session = terminals.session(for: folder) else {
            say("The terminal couldn't start a shell.")
            return false
        }
        openTerminal()
        guard !session.busy else {
            say("The terminal is busy; the command wasn't typed.")
            return false
        }
        // Typed, a control character is a key: ESC ends the paste early, DEL erases the quote
        // before it, ^U the line, and a tab typed before the shell takes pastes starts completion,
        // which can rewrite a quote. A command never needs one, so a value that brings one is
        // refused; a newline inside quotes is only a line break.
        guard !command.unicodeScalars.contains(where: { ($0.value < 0x20 && $0 != "\n") || $0.value == 0x7F }) else {
            say("The command has a control character in it, so it wasn't typed.")
            return false
        }
        session.type(command)
        return true
    }
}
