import Foundation
import SwiftData
import SwiftTerm
import SwiftUI
import Testing
@testable import OriCode

/// Commands from the composer's shell prompt: what their blocks show, and what Claude reads.
@MainActor
struct ShellTests {
    @Test func aTerminalReadsBackAsItsLinesWithWrappedOnesJoined() {
        let long = String(repeating: "x", count: ShellBlock.columns + 10)
        let terminal = ShellRender.replay(Data("one\r\n\u{1B}[31mtwo\u{1B}[0m three\r\n\(long)\r\n\r\n\r\n".utf8))
        let lines = ShellRender.lines(terminal)
        #expect(ShellRender.plain(lines) == "one\ntwo three\n\(long)")
    }

    @Test func coloursBecomeRunsAndTheDefaultIsLeftToTheBlock() {
        let terminal = ShellRender.replay(Data("\u{1B}[31mred\u{1B}[0m plain".utf8))
        let text = ShellRender.attributed(ShellRender.lines(terminal))
        let runs = text.runs.map { (String(text[$0.range].characters), $0.foregroundColor) }
        #expect(runs.count == 2)
        #expect(runs[0].0 == "red" && runs[0].1 == ShellRender.colour(.ansi256(code: 1)))
        #expect(runs[1].0 == " plain" && runs[1].1 == nil)
    }

    @Test func claudeReadsTheCommandAndWhatItPrinted() {
        #expect(ShellContext.block(command: "make test", text: "ok\nFAIL x", from: 0, exitCode: 2, running: false) == """
            <bash-input>make test</bash-input>
            <bash-stdout>ok
            FAIL x</bash-stdout>
            (It exited with code 2.)
            """)
        #expect(ShellContext.block(command: "npm run dev", text: "ready\nGET /", from: 6, exitCode: nil, running: true) == """
            <bash-input>npm run dev</bash-input>
            <bash-stdout>GET /</bash-stdout>
            (It's still running.)
            """)
        let long = String(repeating: "y", count: ShellContext.limit + 5)
        #expect(ShellContext.block(command: "cat big", text: long, from: 0, exitCode: 0, running: false)
            .contains("[5 earlier characters left out]"))
    }

    @Test func aCommandRunsInItsFolderAndEnds() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let block = ShellBlock(id: UUID(), chatID: UUID(), command: "pwd -P; printf 'a\\nb\\n'; exit 3", folder: folder.path)
        #expect(block.start())
        for _ in 0..<100 where block.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!block.running)
        #expect(block.exitCode == 3)
        #expect(block.text.hasSuffix("a\nb"))
        #expect(block.text.contains(folder.lastPathComponent))
    }

    @Test func stopIsAControlC() async throws {
        let block = ShellBlock(id: UUID(), chatID: UUID(), command: "echo started; sleep 30", folder: NSTemporaryDirectory())
        #expect(block.start())
        for _ in 0..<60 where !block.text.contains("started") { try await Task.sleep(for: .milliseconds(50)) }
        block.stop()
        for _ in 0..<60 where block.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!block.running)
        #expect(block.exitCode == 130)
    }

    @Test func aProgramTakingTheWholeScreenSaysSoAndLetsGo() async throws {
        let block = ShellBlock(id: UUID(), chatID: UUID(), command: "printf '\\033[?1049hfull'; sleep 0.4; printf '\\033[?1049lback'", folder: NSTemporaryDirectory())
        var changes: [Bool] = []
        block.onFullScreen = { changes.append($0.fullScreen) }
        #expect(block.start())
        for _ in 0..<60 where block.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(changes == [true, false])
        #expect(block.text.hasSuffix("back"))
    }

    @Test func commandJTogglesThePromptAndPutsAnOpenBlockBack() async throws {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        model.toggleShellPrompt()
        #expect(model.shellPrompt)
        let block = try #require(model.runCommand("sleep 5"))
        model.open(block)
        #expect(model.openShell === block)
        model.toggleShellPrompt()
        #expect(model.openShell == nil)
        #expect(model.shellPrompt)
        block.stop()
    }

    @Test func blocksGoToClaudeOnceWithTheNextMessage() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: folder.path)
        container.mainContext.insert(project)
        // After the model, whose launch clears threads that never started.
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        model.runCommand("echo hello from the shell")
        for _ in 0..<100 where model.shellBlocks.values.contains(where: \.running) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(chat.started)
        #expect(chat.title == "echo hello from the shell")
        let context = model.shellContext(for: chat)
        #expect(context?.contains("<bash-input>echo hello from the shell</bash-input>") == true)
        #expect(context?.contains("hello from the shell</bash-stdout>") == true)
        #expect(model.shellContext(for: chat) == nil)
        // The block and what Claude has read of it are stored with the thread.
        let again = Conversation(chat: chat, context: container.mainContext)
        guard case .shell(_, let run) = again.items.last else {
            Issue.record("no block")
            return
        }
        #expect(run.exitCode == 0 && run.sentUpTo > 0 && !run.output.isEmpty)
    }
}
