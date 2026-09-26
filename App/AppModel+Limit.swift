import SwiftData
import SwiftUI

/// Threads Claude's session limit stopped go on by themselves once it resets: one wait, for the
/// soonest reset, and when it's over every thread that's due is sent the line as a message of its
/// own. The wait counts time the Mac spends asleep, and a reset that came while OriCode was closed
/// is picked up as soon as the engine is ready.
extension AppModel {
    static let limitLine = "The session limit has reset. Please continue from where you left off."

    func scheduleResumes() {
        resumeTask?.cancel()
        let waiting = (try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.resumeAt != nil }))) ?? []
        guard let soonest = waiting.compactMap(\.resumeAt).min() else { return }
        // A little past the reset, for a Mac whose clock runs ahead of Claude's.
        let wait = max(soonest.timeIntervalSinceNow + 20, 1)
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.resumeDue()
        }
    }

    private func resumeDue() {
        // Starting the engine schedules again.
        guard engineState == .ready else { return }
        let now = Date.now
        let due = (try? context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.resumeAt != nil }))) ?? []
        for chat in due where chat.resumeAt.map({ $0.addingTimeInterval(20) <= now }) == true {
            let conversation = conversation(for: chat)
            // A thread handed to Claude Code in a block goes on there.
            let handedOver = handedOff[chat.id].flatMap { shellBlocks[$0] }?.running == true
            guard !conversation.running, chat.sessionId != nil, !handedOver else {
                conversation.cancelResume()
                continue
            }
            Engine.logger.notice("thread \(chat.id.uuidString, privacy: .public) goes on after the session limit")
            conversation.userSent(Self.limitLine)
            startTurn(in: chat, text: Self.limitLine)
        }
        scheduleResumes()
    }

    func cancelResume() {
        guard let chat else { return }
        withAnimation(Motion.fade) { conversation(for: chat).cancelResume() }
        scheduleResumes()
    }
}
