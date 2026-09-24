import AppKit

extension AppModel {
    /// Esc closes the topmost thing and nothing under it hears the key. Returns whether
    /// anything took it. Menus run their own event loop and handle Esc before this.
    func escape() -> Bool {
        if modelPickerShown {
            modelPickerShown = false
            return true
        }
        if openFile != nil {
            closeFile()
            focusTerminal()
            return true
        }
        if fileFinderShown {
            toggleFileFinder()
            focusTerminal()
            return true
        }
        if commandCenterShown {
            // Back one level, and at the top, away.
            if !palette.pop() {
                closeCommandCenter()
                focusTerminal()
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
        // The drawer's rename field sits over the terminal.
        if renamingChatID != nil {
            renamingChatID = nil
            return true
        }
        if terminalShown {
            // While a program holds the shell (vim, fzf, claude), Esc is that program's.
            if terminals.owner(of: NSApp.mainWindow?.firstResponder)?.busy == true { return false }
            closeTerminal()
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
