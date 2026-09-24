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
        withAnimation(Motion.fade) { shellPrompt.toggle() }
        composerFocus += 1
    }

    /// The block drawn full over the open thread, if one is.
    var openShell: ShellBlock? {
        openBlock.flatMap { shellBlocks[$0] }.flatMap { $0.chatID == chat?.id ? $0 : nil }
    }

    /// Draws a running block full over the conversation, to be typed into.
    func open(_ block: ShellBlock) {
        guard block.running, block.chatID == chat?.id else { return }
        if reviewShown { closeReview() }
        modelPickerShown = false
        withAnimation(Motion.move) { openBlock = block.id }
    }

    /// Puts the open block back in the thread, and the keyboard back in the composer.
    func closeBlock() {
        guard openBlock != nil else { return }
        withAnimation(Motion.move) { openBlock = nil }
        composerFocus += 1
    }

    /// Gives the open block's terminal the keyboard back when a panel that came over it goes.
    func focusOpenBlock() {
        guard let view = openShell?.view else { return }
        view.window?.makeFirstResponder(view)
    }

    /// A line from ⌘K or one of your actions, run as a block in the open thread.
    @discardableResult
    func runInThread(_ line: String, open: Bool = false) -> Bool {
        guard let block = runCommand(line) else { return false }
        if open { self.open(block) }
        return true
    }
}
