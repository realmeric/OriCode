import Foundation
import os

struct EngineEvent: Sendable {
    let name: String
    let threadId: String?
    let body: JSON
}

enum EngineError: LocalizedError {
    case notRunning
    case stopped
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notRunning, .stopped: "Engine stopped."
        case .remote(let message): message
        }
    }
}

/// The node sidecar. Requests go out as JSON lines on stdin; replies are matched back
/// by id, and everything else the engine prints is an event on `output`.
actor Engine {
    enum Output: Sendable {
        case event(EngineEvent)
        case stopped
    }

    nonisolated let output: AsyncStream<Output>
    private let continuation: AsyncStream<Output>.Continuation
    private var process: Process?
    private var stdin: FileHandle?
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var generation = 0

    static let logger = Logger(subsystem: "com.realmeric.oricode", category: "engine")
    static let logFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/OriCode/engine.log")

    init() {
        (output, continuation) = AsyncStream.makeStream()
    }

    func start(nodeOverride: String?) async throws {
        stop()
        let node = try await NodeLocator.find(override: nodeOverride)
        guard let script = Bundle.main.url(forResource: "engine", withExtension: nil)?.appending(path: "main.ts") else {
            throw EngineError.remote("The engine is missing from the app bundle.")
        }
        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [node.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        process.environment = environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        generation += 1
        let current = generation
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.exited(generation: current, status: status) }
        }
        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
        Self.logger.notice("engine started with \(node.path, privacy: .public)")

        Task.detached { [weak self] in
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    await self?.receive(line)
                }
            } catch {}
        }
        Task.detached {
            try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: Self.logFile.path) {
                FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
            }
            let log = try? FileHandle(forWritingTo: Self.logFile)
            _ = try? log?.seekToEnd()
            do {
                for try await line in errors.fileHandleForReading.bytes.lines {
                    try? log?.write(contentsOf: Data((line + "\n").utf8))
                }
            } catch {}
        }
    }

    func stop() {
        generation += 1
        failPending()
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
    }

    func request(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        guard let stdin else { throw EngineError.notRunning }
        let id = nextId
        nextId += 1
        var line = try JSON.object(["id": .number(Double(id)), "method": .string(method), "params": params]).data()
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdin.write(contentsOf: line)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: EngineError.stopped)
            }
        }
    }

    private func receive(_ line: String) {
        guard let message = try? JSONDecoder().decode(JSON.self, from: Data(line.utf8)) else {
            Self.logger.error("engine printed something that isn't JSON: \(line, privacy: .public)")
            return
        }
        if let id = message["id"]?.int {
            guard let waiting = pending.removeValue(forKey: id) else { return }
            if let error = message["error"]?.string {
                waiting.resume(throwing: EngineError.remote(error))
            } else {
                waiting.resume(returning: message["result"] ?? .null)
            }
        } else if let name = message["event"]?.string {
            continuation.yield(.event(EngineEvent(name: name, threadId: message["threadId"]?.string, body: message)))
        }
    }

    private func exited(generation: Int, status: Int32) {
        guard generation == self.generation else { return }
        Self.logger.notice("engine exited with status \(status)")
        process = nil
        stdin = nil
        failPending()
        continuation.yield(.stopped)
    }

    private func failPending() {
        for waiting in pending.values { waiting.resume(throwing: EngineError.stopped) }
        pending.removeAll()
    }
}
