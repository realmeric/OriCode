import AppKit

extension AppModel {
    /// Esc closes the topmost thing and nothing under it hears the key. Returns whether
    /// anything took it. Menus run their own event loop and handle Esc before this.
    func escape() -> Bool {
        if let chat, let ask = conversation(for: chat).waitingAsk {
            answer(ask, allow: false, message: ask.kind == "question" ? AskCard.skipMessage : nil)
            return true
        }
        return false
    }

    func installEscapeMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  let self, self.escape()
            else { return event }
            return nil
        }
    }
}
