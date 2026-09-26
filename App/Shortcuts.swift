import AppKit
import SwiftUI

/// A key and the modifiers held with it, the way a menu item or the composer takes it.
struct KeyCombo: Codable, Hashable, Sendable {
    /// What the key types with nothing held, on the keyboard's own layout, or one of the named
    /// keys: return, tab, delete, space, escape, up, down, left, right.
    let key: String
    /// EventModifiers' raw value, since EventModifiers isn't Hashable.
    let flags: Int

    init(_ key: String, _ modifiers: EventModifiers = .command) {
        self.key = key
        flags = modifiers.intersection(.shortcut).rawValue
    }

    var modifiers: EventModifiers { EventModifiers(rawValue: flags) }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private var equivalent: KeyEquivalent {
        switch key {
        case "return": .return
        case "tab": .tab
        case "delete": .delete
        case "space": .space
        case "escape": .escape
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        default: KeyEquivalent(Character(key))
        }
    }

    /// As the menus write it: ⌃⌥⇧⌘, then the key.
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case "return": text += "Return"
        case "tab": text += "Tab"
        case "delete": text += "⌫"
        case "space": text += "Space"
        case "escape": text += "Esc"
        case "up": text += "↑"
        case "down": text += "↓"
        case "left": text += "←"
        case "right": text += "→"
        default: text += key.localizedUppercase
        }
        return text
    }

    private static let named: [UInt16: String] = [
        36: "return", 76: "return", 48: "tab", 51: "delete", 49: "space", 53: "escape",
        126: "up", 125: "down", 123: "left", 124: "right",
    ]

    /// The combination a key-down stands for, or nil for a key a shortcut can't name, a function
    /// key say.
    init?(_ event: NSEvent) {
        let modifiers = EventModifiers(event.modifierFlags)
        if let name = Self.named[event.keyCode] {
            self.init(name, modifiers)
            return
        }
        // Without modifiers, so ⇧⌘/ is / with shift rather than ?, and ⌥ doesn't turn a letter
        // into a symbol.
        guard let typed = event.characters(byApplyingModifiers: []), typed.count == 1,
              let scalar = typed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar), !(0xF700...0xF8FF).contains(scalar.value)
        else { return nil }
        self.init(typed.lowercased(), modifiers)
    }
}

extension EventModifiers {
    /// The four a shortcut is made of; caps lock, the keypad and fn don't count.
    static let shortcut: EventModifiers = [.command, .shift, .option, .control]

    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}

/// Everything a key can be given to: the menu items and the composer's Return.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newThread, newThreadOnBranch, addProject, close
    case toggleThreads, commandCenter, shellPrompt, heads, findFile, review
    case stop, switchBranch, nextThread, previousThread, modelPicker, rename, delete
    case shortcuts
    case send, queue, newLine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newThread: "New Thread"
        case .newThreadOnBranch: "New Thread on Its Own Branch"
        case .addProject: "Add Project"
        case .close: "Close Thread or Window"
        case .toggleThreads: "Show or Hide Threads"
        case .commandCenter: "Command Center"
        case .shellPrompt: "Shell Prompt"
        case .heads: "Show or Hide Heads"
        case .findFile: "Find File"
        case .review: "Review Changes"
        case .stop: "Stop"
        case .switchBranch: "Switch Branch"
        case .nextThread: "Next Thread"
        case .previousThread: "Previous Thread"
        case .modelPicker: "Model and Effort"
        case .rename: "Rename Thread"
        case .delete: "Delete Thread"
        case .shortcuts: "Keyboard Shortcuts"
        case .send: "Send"
        case .queue: "Send After This Turn"
        case .newLine: "New Line"
        }
    }

    var standard: KeyCombo {
        switch self {
        case .newThread: KeyCombo("n")
        case .newThreadOnBranch: KeyCombo("n", [.command, .shift])
        case .addProject: KeyCombo("o")
        case .close: KeyCombo("w")
        case .toggleThreads: KeyCombo("b")
        case .commandCenter: KeyCombo("k")
        case .shellPrompt: KeyCombo("j")
        case .heads: KeyCombo("i")
        case .findFile: KeyCombo("p")
        case .review: KeyCombo("d", [.command, .shift])
        case .stop: KeyCombo(".")
        case .switchBranch: KeyCombo("b", [.command, .shift])
        case .nextThread: KeyCombo("tab", .control)
        case .previousThread: KeyCombo("tab", [.control, .shift])
        case .modelPicker: KeyCombo("m", [.command, .shift])
        case .rename: KeyCombo("r")
        case .delete: KeyCombo("delete")
        case .shortcuts: KeyCombo("/")
        case .send: KeyCombo("return", [])
        case .queue: KeyCombo("return", .option)
        case .newLine: KeyCombo("return", .shift)
        }
    }

    /// The composer's own keys, which are all Return.
    var inComposer: Bool {
        self == .send || self == .queue || self == .newLine
    }
}

/// What Return does in the composer, by the modifiers held with it.
enum ReturnPress: Equatable {
    case send, queue, newLine
}

/// The keys every rebindable action has now: its default unless Settings › Shortcuts gave it
/// another, kept in the defaults. The menus, ⌘/, ⌘K and the composer all read it here.
@MainActor @Observable final class Shortcuts {
    /// Only what differs from the defaults, so a default that changes in a later version reaches
    /// everyone who never touched it.
    private(set) var changed: [ShortcutAction: KeyCombo] = [:]
    @ObservationIgnored private let defaults: UserDefaults

    static let key = "shortcuts"

    /// Keys macOS or the Edit menu already mean something by.
    static let reserved: [KeyCombo: String] = [
        KeyCombo("q"): "Quit",
        KeyCombo("h"): "Hide",
        KeyCombo("h", [.command, .option]): "Hide Others",
        KeyCombo("m"): "Minimize",
        KeyCombo(","): "Settings",
        KeyCombo("tab"): "switching apps",
        KeyCombo("tab", [.command, .shift]): "switching apps",
        KeyCombo("`"): "switching windows",
        KeyCombo("space"): "Spotlight",
        KeyCombo("f", [.command, .control]): "Full Screen",
        KeyCombo("z"): "Undo",
        KeyCombo("z", [.command, .shift]): "Redo",
        KeyCombo("x"): "Cut",
        KeyCombo("c"): "Copy",
        KeyCombo("v"): "Paste",
        KeyCombo("a"): "Select All",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([String: KeyCombo].self, from: data)
        else { return }
        for (id, combo) in stored {
            if let action = ShortcutAction(rawValue: id) { changed[action] = combo }
        }
    }

    subscript(action: ShortcutAction) -> KeyCombo {
        changed[action] ?? action.standard
    }

    func key(_ action: ShortcutAction) -> KeyboardShortcut {
        self[action].keyboardShortcut
    }

    func label(_ action: ShortcutAction) -> String {
        self[action].label
    }

    /// Why a key can't be given to an action, in a line for the row; nil when it can.
    func refusal(_ combo: KeyCombo, for action: ShortcutAction) -> String? {
        if action.inComposer {
            guard combo.key == "return" else { return "The composer's keys are Return, with any modifiers" }
        } else if !combo.modifiers.contains(.command), !combo.modifiers.contains(.control) {
            // Without one of these a menu's key would be typed into the composer.
            return "A menu's key needs ⌘ or ⌃"
        }
        if let meaning = Self.reserved[combo] {
            return "macOS keeps \(combo.label) for \(meaning)"
        }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self[$0] == combo }) {
            return "\(combo.label) is \(other.title)"
        }
        if combo.modifiers == .command, let digit = Int(combo.key), (1...9).contains(digit) {
            return "\(combo.label) is Go to Thread \(digit)"
        }
        return nil
    }

    /// Gives the action the key, or says why not and leaves everything as it was.
    @discardableResult
    func set(_ combo: KeyCombo, for action: ShortcutAction) -> String? {
        if self[action] == combo { return nil }
        if let refusal = refusal(combo, for: action) { return refusal }
        changed[action] = combo == action.standard ? nil : combo
        save()
        return nil
    }

    /// Back to the action's default, unless another action has taken it meanwhile.
    @discardableResult
    func restore(_ action: ShortcutAction) -> String? {
        set(action.standard, for: action)
    }

    func restoreAll() {
        changed = [:]
        save()
    }

    /// Return with these modifiers held. The queue's key queues only while there's a turn to wait
    /// for, and is a new line otherwise; any Return that isn't the send key is a new line, so
    /// plain Return becomes one once send has another key.
    func returnPress(_ modifiers: EventModifiers, working: Bool) -> ReturnPress {
        let pressed = KeyCombo("return", modifiers)
        if pressed == self[.queue] { return working ? .queue : .newLine }
        if pressed == self[.send] { return .send }
        return .newLine
    }

    private func save() {
        if changed.isEmpty {
            defaults.removeObject(forKey: Self.key)
            return
        }
        let stored = Dictionary(uniqueKeysWithValues: changed.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.key)
    }
}
