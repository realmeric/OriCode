import AppKit
import Testing
@testable import OriCode

@MainActor
struct FileEditorTests {
    private func key(_ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 1)!
    }

    @Test func commandSSavesFromTheEditorItself() {
        let scroll = FileTextView.scrollableTextView()
        let view = scroll.documentView as? FileTextView
        #expect(view != nil)
        var saves = 0
        view?.save = { saves += 1 }
        #expect(view?.performKeyEquivalent(with: key("s", .command)) == true)
        #expect(saves == 1)
        _ = view?.performKeyEquivalent(with: key("s", [.command, .shift]))
        _ = view?.performKeyEquivalent(with: key("d", .command))
        #expect(saves == 1)
    }

    /// A file with no stamp, one outside the project or a picture, stays read-only.
    @Test func aFileWithNoStampHasNoWayToAnEdit() throws {
        let container = try TestStore.memory()
        let model = AppModel(container: container)
        model.openFile = OpenFile(path: "/tmp/notes.md", cwd: "/tmp/alpha", code: AttributedString("kept"), lines: 1)
        model.editFile()
        #expect(model.openFile?.editing == false)
        #expect(!model.paletteSearchable(whole: true).contains { $0.id == "file.edit" })
        model.openFile?.stamp = "4 1"
        #expect(model.paletteSearchable(whole: true).contains { $0.id == "file.edit" })
        model.editFile()
        #expect(model.openFile?.editing == true)
        withExtendedLifetime(container) {}
    }

    private func written(_ name: String, _ data: Data) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "oricode-pictures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try data.write(to: file)
        return file.path
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try #require(bitmap.representation(using: .jpeg, properties: [:]))
    }

    @Test func aPictureComesBackAtItsOwnSizeOrTheLargestTheViewerShows() async throws {
        let small = await AppModel.picture(at: try written("sheet01.jpg", try jpeg(width: 64, height: 48)))
        #expect(small?.size == NSSize(width: 64, height: 48))
        let large = await AppModel.picture(at: try written("large", try jpeg(width: 6400, height: 3200)))
        #expect(large?.size == NSSize(width: 3200, height: 1600))
    }

    @Test func whatIsntAPictureIsSaidToBeNone() async throws {
        #expect(await AppModel.picture(at: try written("blob.bin", Data([1, 0, 2, 0, 3]))) == nil)
        #expect(await AppModel.picture(at: try written("lies.jpg", Data("not a jpeg".utf8))) == nil)
        #expect(await AppModel.picture(at: "/tmp/oricode-no-such-picture.jpg") == nil)
    }

    @Test func theSideQuestionsKeyIsALetterEveryKeyboardHas() {
        let key = ShortcutAction.sideQuestion.standard
        #expect(key == KeyCombo("a", [.command, .shift]))
        // No other action's, and none of the system's.
        #expect(ShortcutAction.allCases.filter { $0.standard == key } == [.sideQuestion])
        #expect(Shortcuts.reserved[key] == nil)
    }
}
