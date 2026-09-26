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
        #expect(ShellContext.block(command: "make test", output: "ok\nFAIL x", exitCode: 2, running: false) == """
            <bash-input>make test</bash-input>
            <bash-stdout>ok
            FAIL x</bash-stdout>
            (It exited with code 2.)
            """)
        #expect(ShellContext.block(command: "npm run dev", output: "GET /", exitCode: nil, running: true) == """
            <bash-input>npm run dev</bash-input>
            <bash-stdout>GET /</bash-stdout>
            (It's still running.)
            """)
        let long = String(repeating: "y", count: ShellContext.limit + 5)
        #expect(ShellContext.block(command: "cat big", output: long, exitCode: 0, running: false)
            .contains("[5 earlier characters left out]"))
    }

    @Test func claudeReadsOnFromWhereItWasEvenAfterAClear() throws {
        let block = ShellBlock(id: UUID(), chatID: UUID(), command: "npm test -- --watch", folder: NSTemporaryDirectory())
        func read() -> String? {
            guard let unread = block.unread() else { return nil }
            block.read(to: unread.mark)
            return unread.text
        }
        block.view.feed(text: "one\r\ntwo\r\nthree\r\n")
        #expect(read() == "one\ntwo\nthree")
        #expect(read() == nil)
        block.view.feed(text: "four\r\n")
        #expect(read() == "four")
        // A watcher clears the screen and its scrollback and prints more lines than before.
        let run = (1...6).map { "pass \($0)" }
        block.view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J" + run.joined(separator: "\r\n") + "\r\n")
        #expect(read() == run.joined(separator: "\n"))
        // Only the screen this time, and fewer lines.
        block.view.feed(text: "\u{1B}[H\u{1B}[2Jfail 1\r\n")
        #expect(read() == "fail 1")
        // Past the scrollback, which lets go of its first lines and not of the lines' numbers.
        block.view.feed(text: (1...ShellBlock.scrollback + 100).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        #expect(read()?.hasSuffix("line \(ShellBlock.scrollback + 100)") == true)
        block.view.feed(text: "after\r\n")
        #expect(read() == "after")
        #expect(block.unreadLines == 0)
        // A program takes the whole screen, and gives it back.
        block.view.feed(text: "\u{1B}[?1049h\u{1B}[Hfull")
        #expect(read() == "full")
        block.view.feed(text: "\u{1B}[?1049l")
        #expect(read()?.hasSuffix("line \(ShellBlock.scrollback + 100)\nafter") == true)
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
        let (model, chat, container) = try thread()
        let block = try #require(model.runCommand("echo hello from the shell"))
        for _ in 0..<100 where block.running || !block.text.hasSuffix("hello from the shell") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(chat.started)
        #expect(chat.title == "echo hello from the shell")
        let message = model.withShells("what happened?", in: chat)
        #expect(message.text.hasPrefix("<bash-input>echo hello from the shell</bash-input>"))
        #expect(message.text.hasSuffix("hello from the shell</bash-stdout>\n\nwhat happened?"))
        // Read once the message has been taken, and not before.
        #expect(model.withShells("and now?", in: chat).text != "and now?")
        message.read()
        #expect(model.withShells("and now?", in: chat).text == "and now?")
        // The block and what Claude has read of it are stored with the thread.
        let again = Conversation(chat: chat, context: container.mainContext)
        guard case .shell(_, let run) = again.items.last else {
            Issue.record("no block")
            return
        }
        #expect(run.exitCode == 0 && run.unread == 0 && !run.output.isEmpty)
    }

    @Test func aSlashCommandGoesAloneAndAFailedSendLeavesBlocksUnread() async throws {
        let (model, chat, container) = try thread()
        let block = try #require(model.runCommand("echo waiting"))
        for _ in 0..<100 where block.running || !block.text.hasSuffix("waiting") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.withShells("/compact", in: chat).text == "/compact")
        // No engine runs here, so every send fails, and the block waits for the next message.
        let conversation = model.conversation(for: chat)
        for text in ["/compact", "why?"] {
            #expect(model.send(text))
            for _ in 0..<100 where conversation.running { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(model.withShells("why?", in: chat).text.hasPrefix("<bash-input>echo waiting</bash-input>"))
        let again = Conversation(chat: chat, context: container.mainContext)
        #expect(again.items.contains { if case .shell(_, let run) = $0 { run.unread == -1 } else { false } })
    }

    @Test func aFastCommandsLastLinesArriveAfterItEnds() async throws {
        let (model, chat, container) = try thread()
        // About 300KB through the pty, printed faster than the main queue takes it, and gone.
        var blocks: [ShellBlock] = []
        for _ in 0..<20 {
            let block = try #require(model.runCommand("seq -f '%089.0f' 1 3400; echo done"))
            for _ in 0..<200 where block.running || String(block.screen.characters.suffix(4)) != "done" {
                try await Task.sleep(for: .milliseconds(50))
            }
            blocks.append(block)
        }
        #expect(blocks.allSatisfy { $0.exitCode == 0 && $0.text.hasSuffix("3399\n" + String(repeating: "0", count: 85) + "3400\ndone") })
        // Stored as soon as it's drawn.
        let runs = Conversation(chat: chat, context: container.mainContext).items.compactMap { if case .shell(_, let run) = $0 { run } else { nil } }
        #expect(runs.count == 20)
        #expect(runs.allSatisfy { $0.output.suffix(12) == Data("3400\r\ndone\r\n".utf8) })
    }

    @Test func aBlockRunWhileAReplyStreamsDoesntSplitIt() throws {
        let (model, chat, container) = try thread()
        let conversation = model.conversation(for: chat)
        func delta(_ text: String) -> EngineEvent {
            EngineEvent(name: "text", threadId: chat.id.uuidString, body: ["event": "text", "delta": .string(text)])
        }
        conversation.receive(delta("Running the "))
        conversation.shellStarted(ShellRun(command: "ls", folder: chat.cwd), id: UUID())
        conversation.receive(delta("tests now."))
        conversation.flush()
        // And after a relaunch.
        for items in [conversation.items, Conversation(chat: chat, context: container.mainContext).items] {
            #expect(items.map(\.text) == ["Running the tests now.", nil])
        }
    }

    /// A model with one thread open.
    private func thread() throws -> (AppModel, Chat, ModelContainer) {
        let container = try ModelContainer(
            for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        // After the model, whose launch clears threads that never started.
        let model = AppModel(container: container)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        try container.mainContext.save()
        model.selectedProjectID = project.id
        model.selectedChatID = chat.id
        return (model, chat, container)
    }
}
