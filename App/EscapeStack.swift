import AppKit
import SwiftUI

extension AppModel {
    /// Esc closes the topmost thing and nothing under it hears the key. Returns whether
    /// anything took it. Menus run their own event loop and handle Esc before this.
    func escape() -> Bool {
        if modelPickerShown {
            modelPickerShown = false
            return true
        }
        if composerMenu {
            composerMenu = false
            return true
        }
        if openFile != nil {
            closeFile()
            returnKeyboard()
            return true
        }
        if fileFinderShown {
            toggleFileFinder()
            returnKeyboard()
            return true
        }
        if commandCenterShown {
            // Back one level, and at the top, away.
            if !palette.pop() {
                closeCommandCenter()
                returnKeyboard()
            }
            return true
        }
        if reviewShown {
            if review.noting != nil {
                review.noting = nil
            } else {
                closeReview()
            }
            return true
        }
        // The drawer's rename field sits over an open block.
        if renamingChatID != nil {
            renamingChatID = nil
            return true
        }
        if let block = openShell {
            // While it runs, Esc is its program's, vim's or claude's; Close, ⌘J or a click on the
            // transcript put it back.
            if block.running { return false }
            closeBlock()
            return true
        }
        if shellPrompt {
            withAnimation(Motion.fade) { shellPrompt = false }
            return true
        }
        if drawerShown {
            drawerPinned = false
            hideDrawer()
            return true
        }
        if let chat, let ask = conversation(for: chat).waitingAsk {
            answer(ask, allow: false, message: ask.kind == "question" ? AskCard.skipMessage : nil)
            return true
        }
        return false
    }

    func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Sheets, dialogs and panels handle their own Esc; this is for the main window only.
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let window = event.window, window == NSApp.mainWindow, window.attachedSheet == nil,
                  let self, self.escape()
            else { return event }
            return nil
        }
    }
}
