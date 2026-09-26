import Foundation
import SwiftData
import Testing
@testable import OriCode

/// Where the keyboard goes: an open block stays with its thread, a waiting card keeps Return from
/// the composer, and Esc puts away what's on top first.
@MainActor
struct KeyboardTests {
    private let container: ModelContainer
    private let model: AppModel
    private let first: Chat
    private let second: Chat

    init() throws {
        container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        // After the model, whose launch clears threads that never started.
        model = AppModel(container: container)
        first = Chat(project: project)
        second = Chat(project: project)
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = first.id
    }

    private func ask(in chat: Chat) {
        model.conversation(for: chat).receive(EngineEvent(name: "ask", threadId: chat.id.uuidString, body: [
            "event": "ask", "requestId": "r", "kind": "permission", "tool": "Bash", "input": ["command": "ls"],
        ]))
    }

    @Test func anOpenBlockStaysWithItsThread() throws {
        let block = try #require(model.runCommand("sleep 5"))
        defer { block.stop() }
        model.open(block)
        #expect(model.openShell === block)
        #expect(!model.composerTakesKeyboard)
        let focus = model.composerFocus
        model.selectedChatID = second.id
        #expect(model.openShell == nil)
        #expect(model.composerTakesKeyboard)
        #expect(model.composerFocus == focus + 1)
        model.selectedChatID = first.id
        #expect(model.openShell === block)
    }

    @Test func aBlockTakingTheScreenInAnotherThreadWaitsThere() throws {
        let block = try #require(model.runCommand("sleep 5"))
        defer { block.stop() }
        model.selectedChatID = second.id
        let other = try #require(model.runCommand("sleep 5"))
        defer { other.stop() }
        model.open(other)
        model.open(block)
        #expect(model.openShell === other)
        model.selectedChatID = first.id
        #expect(model.openShell === block)
        model.close(other)
        model.selectedChatID = second.id
        #expect(model.openShell == nil)
    }

    @Test func aBlockGoingByItselfLeavesTheKeyboardWithCommandK() throws {
        let block = try #require(model.runCommand("sleep 5"))
        defer { block.stop() }
        model.open(block)
        model.commandCenterShown = true
        let focus = model.composerFocus
        model.close(block)
        #expect(model.openShell == nil)
        #expect(model.composerFocus == focus)
        #expect(model.escape())
        #expect(model.composerFocus == focus + 1)
    }

    @Test func theRunningLineLeavesOutTheOpenBlock() throws {
        let block = try #require(model.runCommand("sleep 5"))
        defer { block.stop() }
        model.shellsInView[block.id] = false
        #expect(model.runningOutOfView?.block === block)
        model.open(block)
        #expect(model.runningOutOfView?.block == nil)
    }

    @Test func aWaitingCardKeepsReturnFromTheComposer() {
        ask(in: first)
        #expect(!model.composerTakesKeyboard)
        let focus = model.composerFocus
        model.fileFinderShown = true
        #expect(model.escape())
        #expect(!model.fileFinderShown)
        model.returnKeyboard()
        model.closeBlock()
        #expect(model.composerFocus == focus)
        // Another thread with nothing waiting has the composer.
        model.selectedChatID = second.id
        #expect(model.composerFocus == focus + 1)
        // Answered, the card gives it back.
        model.selectedChatID = first.id
        model.conversation(for: first).answered("r", allow: true)
        #expect(model.composerTakesKeyboard)
    }

    @Test func escapePutsAwayWhatsOnTopFirst() {
        model.composerMenu = true
        model.commandCenterShown = true
        #expect(model.escape())
        #expect(!model.commandCenterShown && model.composerMenu)
        model.reviewShown = true
        #expect(model.escape())
        #expect(!model.reviewShown && model.composerMenu)
        #expect(model.escape())
        #expect(!model.composerMenu)
    }
}
