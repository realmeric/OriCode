import Foundation
import Testing
@testable import OriCode

/// OpenSSH's own ssh-agent on a socket in a scratch folder, with a throwaway key.
@MainActor
struct SSHAgentTests {
    /// /tmp and not the long per-user folder: a socket's path has about a hundred characters.
    private static func scratch() throws -> URL {
        let folder = URL(filePath: "/tmp/oricode-ssh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String], socket: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/" + tool)
        process.arguments = arguments
        if let socket { process.environment = ["SSH_AUTH_SOCK": socket] }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static func variable(in environment: [String]) -> String? {
        environment.first { $0.hasPrefix("SSH_AUTH_SOCK=") }.map { String($0.dropFirst("SSH_AUTH_SOCK=".count)) }
    }

    /// The socket exists only once it's switched on in OriPass, so the switch starts on.
    @Test func theSwitchStartsOnAndTurnsOff() {
        let defaults = UserDefaults.standard
        let stored = defaults.object(forKey: SSHAgent.key)
        defer { defaults.set(stored, forKey: SSHAgent.key) }
        defaults.removeObject(forKey: SSHAgent.key)
        #expect(SSHAgent.isOn)
        #expect(SSHAgent.forEngine == .string(SSHAgent.socket))
        defaults.set(false, forKey: SSHAgent.key)
        #expect(!SSHAgent.isOn)
        #expect(SSHAgent.forEngine == .null)
    }

    @Test func noSwitchNoSocketOrNoSocketThereLeavesItAlone() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "plain").path
        FileManager.default.createFile(atPath: file, contents: Data())
        #expect(SSHAgent.path(at: folder.appending(path: "nothing").path, on: true) == nil)
        #expect(SSHAgent.path(at: file, on: true) == nil)

        let given = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
        #expect(Self.variable(in: TerminalEnvironment.make(agent: nil)) == given)
    }

    @Test func aTerminalSignsWithTheKeyOnTheAgent() async throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let socket = folder.appending(path: "agent.sock").path
        let key = folder.appending(path: "key").path
        try Self.run("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "throwaway", "-f", key])
        let agent = Process()
        agent.executableURL = URL(filePath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", socket]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) { try await Task.sleep(for: .milliseconds(20)) }
        try Self.run("ssh-add", ["-q", key], socket: socket)
        try FileManager.default.removeItem(atPath: key)

        #expect(SSHAgent.path(at: socket, on: false) == nil)
        #expect(SSHAgent.path(at: socket, on: true) == socket)
        #expect(Self.variable(in: TerminalEnvironment.make(agent: socket)) == socket)

        let block = ShellBlock(id: UUID(), chatID: UUID(), command: "ssh-add -l", folder: folder.path)
        #expect(block.start(agent: socket))
        // A login shell, whose profile can take seconds on a busy Mac.
        for _ in 0..<600 where block.running { try await Task.sleep(for: .milliseconds(50)) }
        #expect(block.exitCode == 0)
        #expect(block.text.contains("throwaway"))
    }
}
