import SwiftUI

/// The drawer's timing, straight from the brief: a 20pt hot zone that waits 120ms,
/// 220ms in, 180ms out, a 400ms grace after the mouse leaves, and a 700ms ⌘digit peek.
extension AppModel {
    enum DrawerTiming {
        static let hotZoneDelay = Duration.milliseconds(120)
        static let grace = Duration.milliseconds(400)
        static let peek = Duration.milliseconds(700)
        static let slideIn = Animation.easeOut(duration: 0.22)
        static let slideOut = Animation.easeIn(duration: 0.18)
    }

    func hotZone(_ inside: Bool) {
        drawerTask?.cancel()
        guard inside else {
            if drawerShown { scheduleHide(after: DrawerTiming.grace) }
            return
        }
        guard !drawerShown else { return }
        drawerTask = Task {
            try? await Task.sleep(for: DrawerTiming.hotZoneDelay)
            guard !Task.isCancelled else { return }
            showDrawer()
        }
    }

    func drawerHover(_ inside: Bool) {
        mouseInDrawer = inside
        if inside {
            drawerTask?.cancel()
        } else {
            scheduleHide(after: DrawerTiming.grace)
        }
    }

    func toggleDrawerPin() {
        withAnimation(drawerPinned ? DrawerTiming.slideOut : DrawerTiming.slideIn) { drawerPinned.toggle() }
        if drawerPinned { showDrawer() } else if !mouseInDrawer { hideDrawer() }
    }

    /// ⌘1–9: select the thread and slide the drawer in just long enough to show which.
    func pick(threadAt index: Int) {
        let visible = chats
        guard visible.indices.contains(index) else { return }
        select(visible[index])
        nudge(visible[index])
        showDrawer()
        scheduleHide(after: DrawerTiming.peek)
    }

    /// A click on a drawer row: the thread opens and its row stands out the way ⌘1–9's does.
    func pickByClick(_ chat: Chat) {
        select(chat)
        nudge(chat)
    }

    /// The picked row, lit and 6pt out, settles back once the peek's 700ms are up.
    private func nudge(_ chat: Chat) {
        let id = chat.id
        peekedChatID = id
        peekTask?.cancel()
        peekTask = Task {
            try? await Task.sleep(for: DrawerTiming.peek)
            guard !Task.isCancelled, peekedChatID == id else { return }
            withAnimation(Motion.move) { peekedChatID = nil }
        }
    }

    /// ⌃Tab and ⌃⇧Tab: the thread after or before the open one in the drawer's order, round the
    /// end, peeking the drawer like ⌘1–9.
    func stepThread(_ by: Int) {
        let visible = chats
        guard !visible.isEmpty else { return }
        let at = visible.firstIndex { $0.id == chat?.id } ?? (by > 0 ? -1 : 0)
        pick(threadAt: ((at + by) % visible.count + visible.count) % visible.count)
    }

    func showDrawer() {
        drawerTask?.cancel()
        guard !drawerShown else { return }
        withAnimation(DrawerTiming.slideIn) { drawerShown = true }
    }

    func hideDrawer() {
        drawerTask?.cancel()
        guard drawerShown else { return }
        withAnimation(DrawerTiming.slideOut) {
            drawerShown = false
            peekedChatID = nil
        }
    }

    func scheduleHide(after delay: Duration) {
        drawerTask?.cancel()
        guard !drawerPinned else { return }
        drawerTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, !mouseInDrawer, !drawerPinned, renamingChatID == nil else { return }
            hideDrawer()
        }
    }

    func startRename(_ chat: Chat) {
        renamingChatID = chat.id
        showDrawer()
    }

    func finishRename(_ chat: Chat, to title: String?) {
        guard renamingChatID == chat.id else { return }
        renamingChatID = nil
        if let title, title != chat.title { rename(chat, to: title) }
        if !mouseInDrawer { scheduleHide(after: DrawerTiming.grace) }
    }

    enum ThreadState {
        case idle, running, waiting
    }

    func heads(of chat: Chat) -> Int {
        conversations[chat.id]?.heads ?? 0
    }

    func state(of chat: Chat) -> ThreadState {
        guard let conversation = conversations[chat.id] else { return .idle }
        if conversation.waitingAsk != nil { return .waiting }
        return conversation.running ? .running : .idle
    }
}
