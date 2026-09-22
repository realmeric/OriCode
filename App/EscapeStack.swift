import AppKit

extension AppModel {
    /// Esc closes the topmost thing and nothing under it hears the key. Returns whether
    /// anything took it. Menus run their own event loop and handle Esc before this.
    func escape() -> Bool {
        if changesShown {
            closeChanges()
            return true
        }
        if renamingChatID != nil {
            renamingChatID = nil
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
