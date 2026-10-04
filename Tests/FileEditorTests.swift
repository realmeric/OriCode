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

    @Test func theSideQuestionsKeyIsALetterEveryKeyboardHas() {
        let key = ShortcutAction.sideQuestion.standard
        #expect(key == KeyCombo("a", [.command, .shift]))
        // No other action's, and none of the system's.
        #expect(ShortcutAction.allCases.filter { $0.standard == key } == [.sideQuestion])
        #expect(Shortcuts.reserved[key] == nil)
    }
}
