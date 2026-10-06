import AppKit
import Foundation
import SwiftData
import Testing
@testable import OriCode

/// The pictures you send, kept in full for Quick Look and gone with their thread.
@MainActor
struct SentPicturesTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "oricode-pictures-\(UUID().uuidString)")
    private let thread = UUID()
    private let message = UUID()

    private var pictures: SentPictures {
        SentPictures(root: folder.appending(path: "Images"), temporary: folder.appending(path: "Temporary"))
    }

    private func exists(_ url: URL?) -> Bool {
        url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    private func attachment() throws -> ImageAttachment {
        try #require(ImageAttachment(image: NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }))
    }

    @Test func aPictureIsFiledUnderItsThreadAndItsMessage() {
        let png = pictures.file(thread: thread, message: message, index: 0, mediaType: "image/png")
        #expect(png.path == pictures.root.path + "/\(thread.uuidString)/\(message.uuidString)/Image 1.png")
        let jpeg = pictures.file(thread: thread, message: message, index: 2, mediaType: "image/jpeg")
        #expect(jpeg.lastPathComponent == "Image 3.jpg")
        #expect(jpeg.deletingLastPathComponent().path == png.deletingLastPathComponent().path)
    }

    @Test func aSavedPictureIsFoundWhicheverKindItWentOutAs() throws {
        let sent = [
            SentPictures.Picture(data: Data([1, 2, 3]), mediaType: "image/png"),
            SentPictures.Picture(data: Data([4, 5]), mediaType: "image/jpeg"),
        ]
        pictures.save(sent, thread: thread, message: message)
        let first = try #require(pictures.find(thread: thread, message: message, index: 0))
        let second = try #require(pictures.find(thread: thread, message: message, index: 1))
        #expect(first.pathExtension == "png")
        #expect(second.pathExtension == "jpg")
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: second) == Data([4, 5]))
        #expect(pictures.find(thread: thread, message: message, index: 2) == nil)
        #expect(pictures.find(thread: thread, message: UUID(), index: 0) == nil)
        #expect(pictures.open(thread: thread, message: message, index: 0, preview: Data([9])) == first)
        try FileManager.default.removeItem(at: folder)
    }

    @Test func aPictureWithNoFileShowsItsPreview() throws {
        let preview = Data([7, 8, 9])
        let shown = try #require(pictures.open(thread: thread, message: message, index: 1, preview: preview))
        #expect(shown.path.hasPrefix(pictures.temporary.path))
        #expect(shown.lastPathComponent == "Image 2.jpg")
        #expect(try Data(contentsOf: shown) == preview)
        // Asked for again, it's the same file.
        #expect(pictures.open(thread: thread, message: message, index: 1, preview: preview) == shown)
        // A message whose thread isn't known has only its preview.
        #expect(pictures.open(thread: nil, message: UUID(), index: 0, preview: preview) != nil)
        #expect(!exists(pictures.root))
        try FileManager.default.removeItem(at: folder)
    }

    @Test func aThreadsPicturesGoWithItAndNoOthers() throws {
        let other = UUID()
        let sent = [SentPictures.Picture(data: Data([1]), mediaType: "image/png")]
        pictures.save(sent, thread: thread, message: message)
        pictures.save(sent, thread: other, message: message)
        pictures.remove(thread: thread)
        #expect(pictures.find(thread: thread, message: message, index: 0) == nil)
        #expect(!exists(pictures.folder(of: thread)))
        #expect(pictures.find(thread: other, message: message, index: 0) != nil)
        // A thread that never had any is removed without complaint.
        pictures.remove(thread: UUID())
        try FileManager.default.removeItem(at: folder)
    }

    @Test func aMessagesPicturesGoWithoutItsThreadsOthers() throws {
        let later = UUID()
        let sent = [SentPictures.Picture(data: Data([1]), mediaType: "image/png")]
        pictures.save(sent, thread: thread, message: message)
        pictures.save(sent, thread: thread, message: later)
        pictures.remove(message: message, in: thread)
        #expect(pictures.find(thread: thread, message: message, index: 0) == nil)
        #expect(pictures.find(thread: thread, message: later, index: 0) != nil)
        try FileManager.default.removeItem(at: folder)
    }

    @Test func aMessageSentIntoATurnKeepsItsPicturesUnderTheIdItKeeps() async throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let project = Project(name: "alpha", path: "/tmp/alpha")
        context.insert(project)
        let chat = Chat(project: project)
        context.insert(chat)
        let conversation = Conversation(chat: chat, context: context, pictures: pictures)
        conversation.userSent("Look at the layout")
        let image = try attachment()

        let taken = conversation.sentIntoTurn("And this", images: [image])
        conversation.taken(taken.id, newTurn: false)
        // Reads wait behind the write, so the file is there by the time one answers.
        let files = await pictures.opened(thread: chat.id, message: taken.id, previews: taken.previews)
        let kept = try #require(files.first ?? nil)
        #expect(kept == pictures.find(thread: chat.id, message: taken.id, index: 0))
        #expect(try Data(contentsOf: kept) == image.data)
        guard case .user(let id, _, _, _)? = conversation.items.last else {
            Issue.record("The message taken up isn't the transcript's last item")
            return
        }
        #expect(id == taken.id)

        // Handed back, it never ran, so nothing was kept for it.
        let back = conversation.sentIntoTurn("Or this", images: [image])
        conversation.handBack(back.id)
        let previews = await pictures.opened(thread: chat.id, message: back.id, previews: back.previews)
        let shown = try #require(previews.first ?? nil)
        #expect(shown.path.hasPrefix(pictures.temporary.path))
        #expect(pictures.find(thread: chat.id, message: back.id, index: 0) == nil)
        try FileManager.default.removeItem(at: folder)
    }
}
