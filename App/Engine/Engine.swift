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
/// Bytes in, whole lines out. Only ever touched from one readability handler at a time.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

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
    /// Keeps App Nap off while the engine runs. A napped app's children are throttled,
    /// network included, and a turn behind another window would stall with them.
    private var activity: NSObjectProtocol?

    static let logger = Logger(subsystem: "com.realmeric.oricode", category: "engine")
    static let logFile = Build.logs.appending(path: "engine.log")

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
        // Opened from a shell, the app inherits that shell's PWD, and the CLI treats it as a
        // place to read. The engine has its own working directory and each turn its cwd.
        environment["PWD"] = nil
        environment["OLDPWD"] = nil
        environment["PATH"] = [node.deletingLastPathComponent().path, environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        if UserDefaults.standard.bool(forKey: "traceEngine") {
            environment["ORICODE_TRACE"] = "1"
            environment["ORICODE_CLI_DEBUG"] = Self.logFile.deletingLastPathComponent().appending(path: "cli").path
        }
        process.environment = environment
        process.qualityOfService = .userInitiated

        let input = Pipe(), output = Pipe(), errors = Pipe()
        // The pipes stay out of the terminal's shells, which inherit whatever isn't marked: a job
        // left running there would otherwise hold the engine's stdin open after the app quits,
        // and the engine lives until stdin ends. Marked before the engine starts, so a shell
        // forked meanwhile gets none of them; the engine's own ends become its stdin, stdout
        // and stderr, which exec keeps.
        for pipe in [input, output, errors] {
            Self.closeOnExec(pipe.fileHandleForReading)
            Self.closeOnExec(pipe.fileHandleForWriting)
        }
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

        // Not FileHandle.bytes: its reads block on one shared queue, so a stderr read waiting
        // for output held back stdout, and replies sat in the pipe until the engine logged.
        let (replies, reply) = AsyncStream<String>.makeStream()
        Self.lines(from: output.fileHandleForReading, onEnd: { reply.finish() }) { reply.yield($0) }
        // One consumer, so events arrive in the order the engine wrote them.
        Task { [weak self] in
            for await line in replies { await self?.receive(line) }
        }
        try? FileManager.default.createDirectory(at: Self.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        Self.tidyLogs()
        if !FileManager.default.fileExists(atPath: Self.logFile.path) {
            FileManager.default.createFile(atPath: Self.logFile.path, contents: nil)
        }
        let log = try? FileHandle(forWritingTo: Self.logFile)
        if let log { Self.closeOnExec(log) }
        _ = try? log?.seekToEnd()
        Self.lines(from: errors.fileHandleForReading, onEnd: {}) { line in
            try? log?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    private nonisolated static func closeOnExec(_ handle: FileHandle) {
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
    }

    /// engine.log takes every line the engine prints, and tracing adds the CLI's own debug logs,
    /// so neither is left to grow: the first starts over past 5MB, the others go after a week.
    private nonisolated static func tidyLogs() {
        let files = FileManager.default
        if let size = (try? files.attributesOfItem(atPath: logFile.path))?[.size] as? Int, size > 5_000_000 {
            try? files.removeItem(at: logFile)
        }
        let cli = logFile.deletingLastPathComponent().appending(path: "cli")
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        let logs = (try? files.contentsOfDirectory(at: cli, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for log in logs where ((try? log.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now) < weekAgo {
            try? files.removeItem(at: log)
        }
    }

    /// Calls `line` for each newline-terminated line, in order, from a GCD readability handler.
    private nonisolated static func lines(
        from handle: FileHandle, onEnd: @escaping @Sendable () -> Void, _ line: @escaping @Sendable (String) -> Void
    ) {
        let buffer = LineBuffer()
        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                onEnd()
                return
            }
            for complete in buffer.append(chunk) { line(complete) }
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
            Self.logger.debug("event \(name, privacy: .public)")
            continuation.yield(.event(EngineEvent(name: name, threadId: message["threadId"]?.string, body: message)))
        }
    }

    private func exited(generation: Int, status: Int32) {
        guard generation == self.generation else { return }
        Self.logger.notice("engine exited with status \(status)")
        process = nil
        stdin = nil
        failPending()
        hold(false)
        continuation.yield(.stopped)
    }

    /// App Nap slows a hidden app's timers and pipe reads, which carry a turn's answer, so the
    /// app asks not to nap while a turn runs, and only then: idle, it can nap like any other.
    func hold(_ busy: Bool) {
        if busy, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Claude is working in a thread")
            Self.logger.notice("holding off App Nap for a turn")
        } else if !busy, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            Self.logger.notice("letting the app nap again")
        }
    }

    private func failPending() {
        for waiting in pending.values { waiting.resume(throwing: EngineError.stopped) }
        pending.removeAll()
    }
}
