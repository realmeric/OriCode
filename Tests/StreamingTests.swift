import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A reply streaming at most once a frame, ⌘K's index of what was said, and a thread read in
/// off the main thread.
@MainActor
struct StreamingTests {
    private let container: ModelContainer
    private let context: ModelContext
    private let chat: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = container.mainContext
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        chat = Chat(project: project)
        chat.started = true
        context.insert(chat)
        try context.save()
    }

    private func delta(_ text: String, in conversation: Conversation) {
        conversation.receive(EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["event": "text", "delta": .string(text)]))
    }

    @Test func deltasInOneFrameReachTheItemTogether() async throws {
        let conversation = Conversation(chat: chat, context: context)
        #expect(!conversation.started)
        conversation.userSent("Go")
        #expect(conversation.started)
        delta("One", in: conversation)
        delta(" two", in: conversation)
        delta(" three", in: conversation)
        // The first shows at once; the rest wait for the next frame.
        #expect(conversation.items.last?.text == "One")
        try await Task.sleep(for: .milliseconds(50))
        #expect(conversation.items.last?.text == "One two three")
    }

    @Test func whatComesNextLandsAfterTheHeldText() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        delta("Reading", in: conversation)
        delta(" the file.", in: conversation)
        conversation.receive(EngineEvent(name: "tool.use", threadId: chat.id.uuidString,
                                         body: ["event": "tool.use", "toolUseId": "t", "name": "Read", "input": ["file_path": "/tmp/alpha/a"]]))
        #expect(conversation.items.map(\.text) == ["Go", "Reading the file.", nil])
        #expect(Conversation(chat: chat, context: context).items.map(\.text) == ["Go", "Reading the file.", nil])
    }

    @Test func aFlushWritesTheHeldText() {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        delta("Half", in: conversation)
        delta(" and the rest", in: conversation)
        conversation.flush()
        #expect(Conversation(chat: chat, context: context).items.last?.text == "Half and the rest")
    }

    @Test func aBlockIsOpenUntilItsFenceCloses() {
        let growing = "```swift\nlet b = 2\nlet c"
        #expect(StreamingCodeHighlighter.isOpen("let b = 2\nlet c", in: growing))
        #expect(StreamingCodeHighlighter.isOpen("", in: "```swift\n"))
        #expect(!StreamingCodeHighlighter.isOpen("let b = 2\nlet c", in: growing + "\n```\n\n"))
        #expect(!StreamingCodeHighlighter.isOpen("", in: "```\n```"))
        // The frame before's copy, which the block has grown past.
        #expect(StreamingCodeHighlighter.isOpen("let b = 2\nle", in: growing + "\n```\n"))
    }

    @Test func theIndexFindsTheNewestThreeAThread() {
        let index = MessageIndex()
        let one = UUID(), two = UUID()
        for n in 0..<5 { index.add(UUID(), in: one, user: n == 0, text: "island number \(n)") }
        index.add(UUID(), in: two, user: false, text: "no match here")
        index.add(UUID(), in: two, user: false, text: "The Dynamic ISLAND grows")
        let found = index.search(["island"], in: [one, two])
        #expect(found.map(\.text) == ["The Dynamic ISLAND grows", "island number 4", "island number 3", "island number 2"])
        // A thread that's gone, or never started, isn't searched.
        #expect(index.search(["island"], in: [two]).count == 1)
    }

    @Test func narrowingAsYouTypeFindsWhatAFreshSearchWould() {
        let index = MessageIndex()
        let thread = UUID()
        let texts = ["dynamic island", "dynamo", "a dyn", "the island is dynamic", "kırıldı dynamic"]
        for text in texts { index.add(UUID(), in: thread, user: false, text: text) }
        var typed = ""
        for character in "dynamic island" {
            typed.append(character)
            let words = MessageSearch.words(typed)
            guard !words.isEmpty else { continue }
            let narrowed = index.search(words, in: [thread], each: 10).map { $0.text as String }
            let fresh = texts.reversed().filter { MessageSearch.match(words, in: $0) != nil }
            #expect(narrowed == fresh, "\(typed)")
        }
        #expect(index.search(["kirildi"], in: [thread]).map(\.text) == ["kırıldı dynamic"])
    }

    @Test func aStreamingReplyIsFoundAsItGrows() {
        let index = MessageIndex()
        let conversation = Conversation(chat: chat, context: context, said: index)
        conversation.userSent("Tell me about the notch")
        delta("The capsule", in: conversation)
        #expect(index.search(["notch"], in: [chat.id]).map(\.user) == [true])
        delta(" sits under the notch", in: conversation)
        conversation.flush()
        #expect(index.search(["notch"], in: [chat.id]).map(\.text) == ["The capsule sits under the notch", "Tell me about the notch"])
    }

    @Test func theStoreIsReadInBehindWhatThisLaunchWrote() async throws {
        let stored = Conversation(chat: chat, context: context)
        stored.userSent("An island from before")
        let index = MessageIndex()
        let conversation = Conversation(chat: chat, context: context, said: index)
        conversation.userSent("An island from now")
        #expect(index.search(["island"], in: [chat.id]).map(\.text) == ["An island from now"])
        index.read(from: container)
        for _ in 0..<100 where !index.ready { try await Task.sleep(for: .milliseconds(10)) }
        #expect(index.search(["island"], in: [chat.id]).map(\.text) == ["An island from now", "An island from before"])
    }

    @Test func aThreadIsReadInOffTheMainThread() async throws {
        let model = AppModel(container: container)
        let first = Conversation(chat: chat, context: context)
        first.userSent("Go")
        delta("Done.", in: first)
        first.flush()
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        #expect(model.currentConversation == nil)
        for _ in 0..<100 where model.currentConversation == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.currentConversation?.items.map(\.text) == ["Go", "Done."])
    }

    @Test func aThreadNeededWhileItsReadInIsMadeAtOnce() async throws {
        let model = AppModel(container: container)
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        let now = model.conversation(for: chat)
        try await Task.sleep(for: .milliseconds(200))
        #expect(model.currentConversation === now)
    }
}
