import Foundation

enum NodeLocator {
    static let minimumMajor = 24

    struct NotFound: Error {
        let message: String
    }

    /// Finds a `node` that is 24 or newer: the Settings override first, then what a login
    /// shell sees, then the usual install places.
    static func find(override: String?) async throws -> URL {
        if let override, !override.isEmpty {
            if let major = await major(of: override), major >= minimumMajor { return URL(filePath: override) }
            throw NotFound(message: "The node chosen in Settings isn't Node \(minimumMajor) or newer.")
        }
        var candidates: [String] = []
        if let fromShell = await run("/bin/zsh", ["-lc", "command -v node"])?.split(separator: "\n").last {
            candidates.append(String(fromShell))
        }
        candidates += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        let nvm = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            candidates += versions.sorted().reversed().map { nvm.appending(path: "\($0)/bin/node").path }
        }
        for candidate in candidates where candidate.hasPrefix("/") {
            if let major = await major(of: candidate), major >= minimumMajor { return URL(filePath: candidate) }
        }
        throw NotFound(message: "OriCode needs Node \(minimumMajor) or newer. Install it with `brew install node`, or choose one in Settings.")
    }

    static func major(of node: String) async -> Int? {
        guard FileManager.default.isExecutableFile(atPath: node),
              let version = await run(node, ["--version"])
        else { return nil }
        return Int(version.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().split(separator: ".").first ?? "")
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
