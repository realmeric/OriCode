import Foundation
import Observation
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
        container = try TestStore.memory()
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

    @Test func aReplyIsSearchedAsFarAsItHasComeWithNoSaveBetween() async throws {
        let index = MessageIndex()
        let conversation = Conversation(chat: chat, context: context, said: index)
        conversation.userSent("Go")
        delta("The capsule", in: conversation)
        delta(" sits under", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(index.search(["under"], in: [chat.id]).map(\.text) == ["The capsule sits under"])
        #expect(index.search(["notch"], in: [chat.id]).isEmpty)
        delta(" the nötch", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        // Narrowing a search that found nothing still reads what came since, folded.
        #expect(index.search(["notch"], in: [chat.id]).map(\.text) == ["The capsule sits under the nötch"])
        // The store read in mid-reply keeps the reply as far as it has come.
        index.read(from: container)
        delta(" and grows", in: conversation)
        for _ in 0..<100 where !index.ready { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(index.search(["grows"], in: [chat.id]).map(\.text) == ["The capsule sits under the nötch and grows"])
        conversation.receive(EngineEvent(name: "tool.use", threadId: chat.id.uuidString,
                                         body: ["event": "tool.use", "toolUseId": "t", "name": "Read", "input": ["file_path": "/tmp/alpha/a"]]))
        #expect(index.search(["notch", "grows"], in: [chat.id]).count == 1)
    }

    /// The text's event as another context reads it from the store.
    private func storedText(_ kind: String = "text") throws -> String? {
        let events = try ModelContext(container).fetch(FetchDescriptor<Event>(predicate: #Predicate { $0.kind == kind }))
        return events.last.flatMap { try? JSONDecoder().decode(JSON.self, from: $0.payload) }?["delta"]?.string
    }

    @Test func aDeltaLeavesTheStoreAloneUntilItsRead() async throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        delta("One", in: conversation)
        conversation.flush()
        #expect(try storedText() == "One")
        delta(" two", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        delta(" three", in: conversation)
        delta(" four", in: conversation)
        // Shown, and nothing of the store's touched for it.
        #expect(conversation.items.last?.text == "One two three")
        #expect(!context.hasChanges)
        // A thread reading this one takes what's held too, and the thread's date stays.
        let was = chat.updatedAt
        conversation.saveHeld()
        #expect(try storedText() == "One two three four")
        #expect(chat.updatedAt == was)
        delta(" five", in: conversation)
        conversation.saveHeld()
        conversation.saveHeld()
        #expect(try storedText() == "One two three four five")
    }

    /// The store saves what has changed on its own, so a reply's event is given its text every
    /// so often as it streams, and a crash takes that much of it and no more.
    @Test func aLongReplyIsPutOnItsEventAsItStreams() async throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.keeps = .milliseconds(150)
        conversation.userSent("Go")
        delta("One", in: conversation)
        conversation.flush()
        delta(" two", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        // Whatever the store saves now, the event still has what the flush gave it.
        try context.save()
        #expect(try storedText() == "One")
        try await Task.sleep(for: .milliseconds(150))
        delta(" three", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        try context.save()
        #expect(try storedText() == "One two three")
        // And not again at the next frame.
        delta(" four", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(conversation.items.last?.text == "One two three four")
        try context.save()
        #expect(try storedText() == "One two three")
    }

    @Test func aQuitMidReplyStoresAllOfIt() async throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        conversation.receive(EngineEvent(name: "thinking", threadId: chat.id.uuidString, body: ["event": "thinking", "delta": "Weighing"]))
        conversation.receive(EngineEvent(name: "thinking", threadId: chat.id.uuidString, body: ["event": "thinking", "delta": " it up"]))
        delta("Half", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        delta(" of it", in: conversation)
        delta(" and the rest", in: conversation)
        conversation.quitting()
        #expect(try storedText("thinking") == "Weighing it up")
        #expect(try storedText() == "Half of it and the rest")
        #expect(Conversation(chat: chat, context: ModelContext(container)).items.compactMap(\.text) == ["Go", "Weighing it up", "Half of it and the rest"])
    }

    @Test func aCommandStartedMidReplyLeavesTheReplyGrowing() async throws {
        let index = MessageIndex()
        let conversation = Conversation(chat: chat, context: context, said: index)
        conversation.userSent("Go")
        delta("Before", in: conversation)
        delta(" the command", in: conversation)
        let id = UUID()
        conversation.shellStarted(ShellRun(command: "ls", folder: "/tmp/alpha"), id: id)
        #expect(try storedText() == "Before the command")
        delta(" and after", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(index.search(["after"], in: [chat.id]).count == 1)
        conversation.flush()
        #expect(try storedText() == "Before the command and after")
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

    @Test func aDeltaReachesTheLiveTextAndNotTheItemsReaders() async throws {
        let conversation = Conversation(chat: chat, context: context)
        conversation.userSent("Go")
        delta("One", in: conversation)
        #expect(conversation.live.id == conversation.items.last?.id)
        nonisolated(unsafe) var itemsChanged = false
        withObservationTracking { _ = conversation.items } onChange: { itemsChanged = true }
        delta(" two", in: conversation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!itemsChanged)
        #expect(conversation.live.text == "One two")
        #expect(conversation.items.last?.text == "One two")
        conversation.receive(EngineEvent(name: "tool.use", threadId: chat.id.uuidString,
                                         body: ["event": "tool.use", "toolUseId": "t", "name": "Read", "input": ["file_path": "/tmp/alpha/a"]]))
        #expect(itemsChanged)
        #expect(conversation.live.id == nil)
    }

    @Test func aLinkInTheTranscriptOpensItsFileInTheThreadsFolder() {
        let model = AppModel(container: container)
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        model.links(in: chat.id)(URL(string: "App/Files.swift:42")!)
        #expect(model.openFile?.path == "App/Files.swift")
        #expect(model.openFile?.line == 42)
    }
}
