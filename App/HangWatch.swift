import Foundation

/// While threads work, a thread of its own checks that the main thread still answers, and one that
/// hasn't for eight seconds is sampled into the logs. A hang of the window is over by the time
/// anyone can look at it, and the one of 2026-11-02 took the agents' tools with it. Off with
/// nothing working, so it wakes nothing then.
final class HangWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.realmeric.oricode.hangwatch", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var asked: DispatchTime?
    private var sampled = false

    private static let beat = DispatchTimeInterval.seconds(2)
    private static let stalled: UInt64 = 8_000_000_000
    /// The samples kept: each is a megabyte or two, and the latest says what the hang was.
    private static let kept = 5

    func watch(_ on: Bool) {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            asked = nil
            guard on else { return }
            let beating = DispatchSource.makeTimerSource(queue: queue)
            beating.schedule(deadline: .now() + Self.beat, repeating: Self.beat, leeway: .seconds(1))
            beating.setEventHandler { [weak self] in self?.beat() }
            beating.resume()
            timer = beating
        }
    }

    private func beat() {
        guard let asked else {
            self.asked = .now()
            DispatchQueue.main.async { [self] in
                queue.async { [self] in
                    self.asked = nil
                    sampled = false
                }
            }
            return
        }
        guard !sampled, DispatchTime.now().uptimeNanoseconds - asked.uptimeNanoseconds > Self.stalled else { return }
        sampled = true
        sample()
    }

    private func sample() {
        let folder = Build.logs
        let stamp = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        let file = folder.appending(path: "hang-\(stamp).txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sampler = Process()
        sampler.executableURL = URL(filePath: "/usr/bin/sample")
        sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "5", "-file", file.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        guard (try? sampler.run()) != nil else { return }
        sampler.waitUntilExit()
        let samples = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("hang-") }.sorted { $0.path < $1.path } ?? []
        for old in samples.dropLast(Self.kept) { try? FileManager.default.removeItem(at: old) }
    }
}
