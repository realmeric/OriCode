// OriCode Probe: the phone's client, Link's PhoneClient, running headless on this Mac against
// CloudKit's Development environment, so the Mac's side of KANBAN-phone.md can be checked end to
// end from a script while no iPhone is at hand. Never shipped.
//
// Launched with `-PairCode <code>` it pairs with OriCode Bridge's test code (PhoneLink+Test.swift).
// It writes everything it holds to /tmp/oricode-probe-state.json whenever that changes, and takes
// one command at a time from /tmp/oricode-probe-cmd.json: a Command.Action as JSON, or the words
// fetch, unpair, watch <thread>, leave or earlier, or for OriPass, register or approve <id>, which
// sign with a software key that stands in for the phone's enclave.
import AppKit
import CryptoKit
import Link
import Observation

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    var client: PhoneClient!
    let state = URL(filePath: "/tmp/oricode-probe-state.json")
    let commands = URL(filePath: "/tmp/oricode-probe-cmd.json")
    let passKey = P256.Signing.PrivateKey()

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
            let passes: [PassAsk]
            let sent: [String]
            let talk: Talk?
            let written: Date
        }
        struct Talk: Encodable {
            let thread: UUID
            let first: Int?
            let last: Int?
            let asked: Int?
            let rows: [TalkLine]
        }
        let snapshot = Snapshot(
            paired: client.paired != nil, pairing: client.pairing, problem: client.problem, mac: client.mac,
            projects: client.projects.values.sorted { $0.order < $1.order },
            threads: client.threads.values.sorted { $0.updated > $1.updated },
            asks: Array(client.asks.values),
            nudges: Array(client.nudges.values),
            passes: Array(client.passes.values),
            sent: client.sent.values.map { "\($0.id) \($0.state) \($0.thread?.uuidString ?? "")" },
            talk: client.talk.map { talk in Talk(thread: talk.thread, first: talk.first, last: talk.last, asked: talk.asked, rows: talk.rows.map(\.line)) },
            written: .now)
        let coder = JSONEncoder()
        coder.outputFormatting = [.prettyPrinted, .sortedKeys]
        coder.dateEncodingStrategy = .iso8601
        try? coder.encode(snapshot).write(to: state, options: .atomic)
    }

    private func take() {
        guard let data = try? Data(contentsOf: commands) else { return }
        try? FileManager.default.removeItem(at: commands)
        let word = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        switch word {
        case "fetch": Task { await client.fetch() }
        case "unpair": client.unpair()
        case "leave": if let talk = client.talk { client.leave(talk.thread) }
        case "earlier": client.earlier()
        case "zone":
            // What's in iCloud now, read from the start, for a script to see what a lease left.
            Task {
                guard let zone = client.paired?.zone else { return }
                let names = (try? await ZoneSync(zone: zone).fetch().changed.map(\.recordID.recordName)) ?? []
                try? names.sorted().joined(separator: "\n").write(toFile: "/tmp/oricode-probe-zone.txt", atomically: true, encoding: .utf8)
            }
        case "register":
            guard let ask = client.passes.values.first(where: { $0.request == nil }) else { return }
            let key = passKey.publicKey.x963Representation
            guard let proof = try? passKey.signature(for: PassWire.registration(name: "Probe", publicKey: key)).derRepresentation else { return }
            client.send(.register(ask: ask.id, name: "Probe", publicKey: key, proof: proof))
        case _ where word.hasPrefix("approve "):
            guard let request = client.passes[String(word.dropFirst(8))]?.request,
                  let signature = try? passKey.signature(for: request.message).derRepresentation
            else { return }
            client.send(.approve(request: request.id, signature: signature))
        case _ where word.hasPrefix("watch "):
            if let thread = UUID(uuidString: String(word.dropFirst(6))) { client.watch(thread) }
        default:
            if let action = try? JSONDecoder().decode(Command.Action.self, from: data) { client.send(action) }
        }
    }
}

let probe = Probe()
NSApplication.shared.delegate = probe
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()
