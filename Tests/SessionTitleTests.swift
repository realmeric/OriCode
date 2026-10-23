import Foundation
import SwiftData
import Testing
@testable import OriCode

/// A thread takes the few words its agent titled the session with, once.
@MainActor
struct SessionTitleTests {
    @Test func aThreadTakesItsSessionsTitleOnceAndKeepsANamedOne() throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.conversation(for: chat).userSent("Write about 600 words on how tide pools form, in plain paragraphs")
        #expect(!chat.titleIsCustom)
        #expect(model.sendParams(in: chat, text: "hi", images: [])["titled"] == nil)
        let title = { (text: String) in
            model.route(EngineEvent(name: "title", threadId: chat.id.uuidString, body: ["event": "title", "title": .string(text)]))
        }
        title("Tide pool formation")
        #expect(chat.title == "Tide pool formation")
        #expect(model.sendParams(in: chat, text: "hi", images: [])["titled"] == true)
        title("Something else")
        #expect(chat.title == "Tide pool formation")
    }
}
