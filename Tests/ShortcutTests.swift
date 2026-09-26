import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OriCode

@MainActor
struct ShortcutTests {
    private let suite = "ShortcutTests-\(UUID().uuidString)"

    private func store() -> (Shortcuts, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        return (Shortcuts(defaults: defaults), defaults)
    }

    @Test func everyActionStartsAtItsDefaultAndNoTwoShareOne() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        for action in ShortcutAction.allCases {
            #expect(shortcuts[action] == action.standard)
            #expect(shortcuts.refusal(action.standard, for: action) == nil, "\(action)")
        }
        #expect(Set(ShortcutAction.allCases.map(\.standard)).count == ShortcutAction.allCases.count)
        #expect(shortcuts.label(.newThread) == "⌘N")
        #expect(shortcuts.label(.review) == "⇧⌘D")
        #expect(shortcuts.label(.previousThread) == "⌃⇧Tab")
        #expect(shortcuts.label(.queue) == "⌥Return")
        #expect(defaults.object(forKey: Shortcuts.key) == nil)
    }

    @Test func aChangeIsStoredAndReadBackAfterARelaunch() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.set(KeyCombo("t", [.command, .option]), for: .newThread) == nil)
        #expect(shortcuts.set(KeyCombo("return", .command), for: .queue) == nil)
        #expect(shortcuts.key(.newThread) == KeyboardShortcut("t", modifiers: [.command, .option]))

        let relaunched = Shortcuts(defaults: defaults)
        #expect(relaunched[.newThread] == KeyCombo("t", [.command, .option]))
        #expect(relaunched[.queue] == KeyCombo("return", .command))
        #expect(relaunched[.send] == ShortcutAction.send.standard)
        #expect(relaunched.changed.count == 2)
    }

    @Test func backToTheDefaultStoresNothing() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        shortcuts.set(KeyCombo("t"), for: .newThread)
        shortcuts.set(KeyCombo("e", [.command, .shift]), for: .review)
        #expect(shortcuts.restore(.newThread) == nil)
        #expect(Shortcuts(defaults: defaults).changed == [.review: KeyCombo("e", [.command, .shift])])
        shortcuts.restoreAll()
        #expect(shortcuts.changed.isEmpty)
        #expect(defaults.object(forKey: Shortcuts.key) == nil)
        #expect(Shortcuts(defaults: defaults)[.review] == ShortcutAction.review.standard)
    }

    @Test func aKeyAlreadyTakenIsRefusedWithItsAction() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.set(KeyCombo("n"), for: .rename) == "⌘N is New Thread")
        #expect(shortcuts[.rename] == ShortcutAction.rename.standard)
        #expect(shortcuts.set(KeyCombo("return", .shift), for: .queue) == "⇧Return is New Line")
        #expect(shortcuts.set(KeyCombo("3"), for: .findFile) == "⌘3 is Go to Thread 3")
        // A default another action took meanwhile can't come back to its own.
        shortcuts.set(KeyCombo("t"), for: .newThread)
        shortcuts.set(KeyCombo("n"), for: .rename)
        #expect(shortcuts.restore(.newThread) == "⌘N is Rename Thread")
        #expect(shortcuts[.newThread] == KeyCombo("t"))
    }

    @Test func keysMacOSKeepsAreRefused() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.refusal(KeyCombo("q"), for: .newThread) == "macOS keeps ⌘Q for Quit")
        #expect(shortcuts.refusal(KeyCombo("h"), for: .newThread) == "macOS keeps ⌘H for Hide")
        #expect(shortcuts.refusal(KeyCombo("m"), for: .newThread) == "macOS keeps ⌘M for Minimize")
        #expect(shortcuts.refusal(KeyCombo(","), for: .newThread) == "macOS keeps ⌘, for Settings")
        #expect(shortcuts.refusal(KeyCombo("tab"), for: .nextThread) == "macOS keeps ⌘Tab for switching apps")
        #expect(shortcuts.refusal(KeyCombo("c"), for: .newThread) == "macOS keeps ⌘C for Copy")
        #expect(shortcuts.changed.isEmpty)
    }

    @Test func menusNeedCommandOrControlAndTheComposerNeedsReturn() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.refusal(KeyCombo("n", []), for: .newThread) == "A menu's key needs ⌘ or ⌃")
        #expect(shortcuts.refusal(KeyCombo("n", .option), for: .newThread) == "A menu's key needs ⌘ or ⌃")
        #expect(shortcuts.refusal(KeyCombo("n", .control), for: .newThread) == nil)
        #expect(shortcuts.refusal(KeyCombo("s"), for: .send) == "The composer's keys are Return, with any modifiers")
        #expect(shortcuts.refusal(KeyCombo("return", [.control, .option]), for: .send) == nil)
        // ⌘\ is out of reach on a Turkish-QWERTY-PC keyboard; any key can move to one that isn't.
        #expect(shortcuts.set(KeyCombo("ş"), for: .toggleThreads) == nil)
        #expect(shortcuts.label(.toggleThreads) == "⌘Ş")
    }

    @Test func commandReturnQueuesOnceTheQueueHasIt() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        // As it ships: Return sends, ⌥Return queues during a turn, ⇧Return is a new line.
        #expect(shortcuts.returnPress([], working: true) == .send)
        #expect(shortcuts.returnPress(.option, working: true) == .queue)
        #expect(shortcuts.returnPress(.option, working: false) == .newLine)
        #expect(shortcuts.returnPress(.shift, working: true) == .newLine)

        #expect(shortcuts.set(KeyCombo("return", .command), for: .queue) == nil)
        #expect(shortcuts.returnPress(.command, working: true) == .queue)
        #expect(shortcuts.returnPress(.command, working: false) == .newLine)
        #expect(shortcuts.returnPress(.option, working: true) == .newLine)
        #expect(shortcuts.returnPress([], working: true) == .send)
        // Caps lock and the keypad's Enter don't change which Return it is.
        #expect(shortcuts.returnPress([.command, .capsLock, .numericPad], working: true) == .queue)
    }

    @Test func plainReturnIsANewLineOnceSendHasAnotherKey() {
        let (shortcuts, defaults) = store()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(shortcuts.set(KeyCombo("return", .command), for: .send) == nil)
        #expect(shortcuts.returnPress(.command, working: false) == .send)
        #expect(shortcuts.returnPress([], working: false) == .newLine)
        #expect(shortcuts.returnPress([], working: true) == .newLine)
        #expect(shortcuts.returnPress(.option, working: true) == .queue)
    }

    @Test func aKeyDownIsReadOnTheKeyboardsOwnLayout() throws {
        func event(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }
        #expect(KeyCombo(try event("\r", code: 36, [.command])) == KeyCombo("return", .command))
        #expect(KeyCombo(try event("\t", code: 48, [.control, .shift])) == KeyCombo("tab", [.control, .shift]))
        #expect(KeyCombo(try event("\u{7F}", code: 51, [.command])) == KeyCombo("delete"))
        #expect(KeyCombo(try event(String(UnicodeScalar(0xF704)!), code: 122, [.command])) == nil)
    }
}
