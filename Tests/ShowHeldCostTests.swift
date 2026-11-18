import Foundation
import SwiftData
import Testing
@testable import OriCode

/// What a frame of a streaming reply costs the main thread in `showHeld`, for a short reply and a
/// long one: the frame's cost shouldn't grow with the reply. Prints the numbers; the bound is loose,
/// for a Debug build on a busy Mac, but a frame cutting the whole reply again is over it.
@MainActor
struct ShowHeldCostTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let clock = StreamClock(manual: true)

    init() throws {
        container = try TestStore.memory()
        context = container.mainContext
    }

    private func conversation() throws -> Conversation {
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let chat = Chat(project: project)
        chat.started = true
        context.insert(chat)
        try context.save()
        let conversation = Conversation(chat: chat, context: context)
        conversation.clock = clock
        conversation.userSent("Go")
        return conversation
    }

    private func delta(_ text: String, in conversation: Conversation) {
        conversation.receive(EngineEvent(name: "text", threadId: conversation.chat.id.uuidString, body: ["event": "text", "delta": .string(text)]))
    }

    /// Milliseconds a frame, over `frames` frames of four words each on a reply begun with `start`.
    private func perFrame(start: String, frames: Int = 400) throws -> Double {
        let conversation = try conversation()
        delta(start, in: conversation)
        clock.tick()
        let words = "word after word, "
        var spent = Duration.zero
        for _ in 0..<frames {
            delta(words, in: conversation)
            let began = ContinuousClock.now
            clock.tick()
            spent += began.duration(to: .now)
        }
        return spent / .milliseconds(1) / Double(frames)
    }

    @Test func aFrameCostsAboutTheSameForAShortReplyAndALongOne() throws {
        let paragraph = String(repeating: "Some words of a paragraph that goes on a while. ", count: 8) + "\n\n"
        let short = try perFrame(start: paragraph)
        let long = try perFrame(start: String(repeating: paragraph, count: 200))
        print("showHeld per frame: short reply \(short) ms, long reply (\(paragraph.count * 200) characters) \(long) ms")
        // 0.019 and 0.39 ms in a Debug build before K-383, when each frame cut the whole reply.
        #expect(long < short * 8 + 0.05)
    }
}
