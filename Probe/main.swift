// OriCode Probe: the phone's client, Link's PhoneClient, running headless on this Mac against
// CloudKit's Development environment, so the Mac's side of KANBAN-phone.md can be checked end to
// end from a script while no iPhone is at hand. Never shipped.
//
// Launched with `-PairCode <code>` it pairs with OriCode Bridge's test code (PhoneLink+Test.swift).
// It writes everything it holds to /tmp/oricode-probe-state.json whenever that changes, and takes
// one command at a time from /tmp/oricode-probe-cmd.json: a Command.Action as JSON, or the words
// fetch or unpair.
import AppKit
import Link
import Observation

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    var client: PhoneClient!
    let state = URL(filePath: "/tmp/oricode-probe-state.json")
    let commands = URL(filePath: "/tmp/oricode-probe-cmd.json")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let folder = URL.applicationSupportDirectory.appending(path: "OriCode Probe")
        client = PhoneClient(keychain: PhoneKeychain(group: nil), deviceName: "Probe", folder: folder) {
            NSApp.registerForRemoteNotifications()
        }
        let arguments = CommandLine.arguments
        if let at = arguments.firstIndex(of: "-PairCode"), at + 1 < arguments.count, let code = PairingCode(string: arguments[at + 1]) {
            Task { await client.pair(with: code) }
        }
        watch()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.take() }
        }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        Task { await client.pushed(userInfo) }
    }

    private func watch() {
        withObservationTracking {
            write()
        } onChange: {
            Task { @MainActor in self.watch() }
        }
    }

    private func write() {
        struct Snapshot: Encodable {
            let paired: Bool
            let pairing: Bool
            let problem: String?
            let mac: MacInfo?
            let projects: [ProjectInfo]
            let threads: [ThreadInfo]
            let asks: [AskInfo]
            let nudges: [NudgeInfo]
            let sent: [String]
            let written: Date
        }
        let snapshot = Snapshot(
            paired: client.paired != nil, pairing: client.pairing, problem: client.problem, mac: client.mac,
            projects: client.projects.values.sorted { $0.order < $1.order },
            threads: client.threads.values.sorted { $0.updated > $1.updated },
            asks: Array(client.asks.values),
            nudges: Array(client.nudges.values),
            sent: client.sent.values.map { "\($0.id) \($0.state) \($0.thread?.uuidString ?? "")" },
            written: .now)
        let coder = JSONEncoder()
        coder.outputFormatting = [.prettyPrinted, .sortedKeys]
        coder.dateEncodingStrategy = .iso8601
        try? coder.encode(snapshot).write(to: state, options: .atomic)
    }

    private func take() {
        guard let data = try? Data(contentsOf: commands) else { return }
        try? FileManager.default.removeItem(at: commands)
        switch String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) {
        case "fetch": Task { await client.fetch() }
        case "unpair": client.unpair()
        default:
            if let action = try? JSONDecoder().decode(Command.Action.self, from: data) { client.send(action) }
        }
    }
}

let probe = Probe()
NSApplication.shared.delegate = probe
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
