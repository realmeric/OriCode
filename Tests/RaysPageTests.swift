import AppKit
import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import OriCode

/// The rays chosen on the mark: the effort page's mark opens the rays' page by a tap or ↑ from
/// the rail, its rows light and put out rays from the keyboard, six at most, and the thread keeps
/// them.
@MainActor
struct RaysPageTests {
    private let container: ModelContainer
    private let chat: Chat
    private let model: AppModel

    private static func option(_ id: String, _ name: String) -> ModelOption {
        ModelOption(id: id, name: name, description: "", efforts: ["low", "medium", "high"], fast: false, defaultEffort: "medium",
                    ultra: false, ultraBlocked: nil, more: nil, needs: nil)
    }

    private static func agent(_ id: String, _ name: String) -> ProviderInfo {
        ProviderInfo(
            id: id, name: name, agent: name, state: .ready, hint: nil, cli: "/usr/local/bin/\(id)", version: "1.0",
            capabilities: ProviderInfo.Capabilities(
                steer: true, resume: true, modeLive: false, attachments: false, heads: false, stopTask: false, limits: false,
                usage: false, commands: false, compact: false, commitMessage: false, handoff: nil, workers: true),
            levels: ["low", "medium", "high"], modes: ["default"])
    }

    init() throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        model = AppModel(container: container)
        chat = Chat(project: project)
        chat.model = "opus"
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.models = [Self.option("opus", "Opus"), Self.option("sonnet", "Sonnet")]
        model.modelsByAgent["codex"] = (1...5).map { Self.option("gpt-\($0)", "GPT-6-\($0)") }
        model.providers = [.claude, Self.agent("codex", "Codex")]
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        UserDefaults.standard.removeObject(forKey: Rays.allowKey)
    }

    /// The picker as the composer shows it, in a window that takes keys and clicks.
    private func picker() async throws -> NSWindow {
        let host = FirstClickHost(rootView: MarkPicker(chat: chat).frame(width: 320, height: 470, alignment: .top)
            .environment(model).environment(\.colorScheme, .dark))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 470)
        let window = TestKeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Kept by the test, which closes it: a window made key and released as it closes crashes the host.
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.makeKeyAndOrderFront(nil)
        try await settle()
        return window
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(250))
    }

    private func key(_ window: NSWindow, _ code: UInt16, _ character: Int, function: Bool = true) {
        let text = String(UnicodeScalar(character)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: function ? [.function, .numericPad] : [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                         characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
            window.sendEvent(event)
        }
    }

    private func up(_ window: NSWindow) { key(window, 126, NSUpArrowFunctionKey) }
    private func down(_ window: NSWindow) { key(window, 125, NSDownArrowFunctionKey) }
    private func left(_ window: NSWindow) { key(window, 123, NSLeftArrowFunctionKey) }
    private func space(_ window: NSWindow) { key(window, 49, 0x20, function: false) }
    private func enter(_ window: NSWindow) { key(window, 36, 0x0D, function: false) }

    @Test func upFromTheRailOpensTheRaysAndLeftGoesBack() async throws {
        let window = try await picker()
        defer { close(window) }
        #expect(!model.raysShown)
        up(window)
        try await settle()
        #expect(model.raysShown)
        // With none picked, every agent but the head's opens.
        #expect(model.raysOpen == ["codex"])
        left(window)
        try await settle()
        #expect(!model.raysShown)
    }

    @Test func aTapOnTheMarkOpensTheRaysAndAnotherGoesBack() async throws {
        let window = try await picker()
        defer { close(window) }
        // The mark's middle: 12 of padding, the 30 of the header, 4, and half its 92.
        let point = NSPoint(x: 160, y: 470 - (12 + 30 + 4 + 46))
        func click() {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
                window.sendEvent(event)
            }
        }
        click()
        try await settle()
        #expect(model.raysShown)
        click()
        try await settle()
        #expect(!model.raysShown)
    }

    @Test func returnAndSpaceLightARayAndPutItOut() async throws {
        let window = try await picker()
        defer { close(window) }
        up(window)
        try await settle()
        // Claude Code's heading, Codex's, then Codex's first model.
        for _ in 0..<3 { down(window) }
        try await settle()
        space(window)
        try await settle()
        #expect(chat.rays == ["codex/gpt-1"])
        down(window)
        try await settle()
        enter(window)
        try await settle()
        #expect(chat.rays == ["codex/gpt-1", "codex/gpt-2"])
        #expect(model.raySlots(for: chat) == [ModelRef(provider: "codex", id: "gpt-1"): 0, ModelRef(provider: "codex", id: "gpt-2"): 1])
        space(window)
        try await settle()
        #expect(chat.rays == ["codex/gpt-1"])
        #expect(model.pairLine(for: chat) == "Opus, 1 ray: GPT-6-1")
    }

    @Test func theMarkHasSixRaysAndASeventhWaits() {
        let refs = (1...5).map { ModelRef(provider: "codex", id: "gpt-\($0)") }
            + [ModelRef(provider: ProviderInfo.claudeID, id: "opus"), ModelRef(provider: ProviderInfo.claudeID, id: "sonnet")]
        for ref in refs { model.setRay(ref, true, for: chat) }
        #expect(chat.rays?.count == 6)
        #expect(chat.rays?.contains("sonnet") == false)
        #expect(Set(model.raySlots(for: chat).values) == Set(0..<6))
        #expect(model.rayColors(for: chat)[5] == MarkPalette.color(for: ProviderInfo.claudeID))
        // One goes out, and the seventh takes the arc that's free at the end.
        model.setRay(refs[0], false, for: chat)
        model.setRay(refs[6], true, for: chat)
        #expect(chat.rays?.last == "sonnet")
        #expect(model.raySlots(for: chat)[refs[6]] == 5)
    }

    @Test func aThreadKeepsItsRaysInTheStore() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "rays-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "OriCode.store")
        let id: UUID
        do {
            let container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(url: url))
            let project = Project(name: "alpha", path: "/tmp/alpha")
            container.mainContext.insert(project)
            let chat = Chat(project: project)
            container.mainContext.insert(chat)
            id = chat.id
            model.setRay(ModelRef(provider: "codex", id: "gpt-2"), true, for: chat)
            model.setRay(ModelRef(provider: ProviderInfo.claudeID, id: "sonnet"), true, for: chat)
        }
        let again = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(url: url))
        let read = try #require(try again.mainContext.fetch(FetchDescriptor<Chat>()).first { $0.id == id })
        #expect(read.rays == ["codex/gpt-2", "sonnet"])
        #expect(model.raySlots(for: read) == [ModelRef(provider: "codex", id: "gpt-2"): 0, ModelRef(provider: ProviderInfo.claudeID, id: "sonnet"): 1])
    }
}

/// A borderless window that takes the keyboard and clicks as the app's key window does, though the
/// test host isn't the active app: without it a click goes to activating the app and is dropped.
private final class TestKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
}

private final class FirstClickHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
