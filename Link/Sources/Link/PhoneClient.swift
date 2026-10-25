import CloudKit
import CryptoKit
import Foundation
import Observation
import os

/// The phone's side of the link: its pairing, the latest records its Mac wrote, opened with the
/// Mac's state key, and the commands it sends back. It reads on every push CloudKit sends and
/// whenever it's asked to; it never polls on its own.
@MainActor
@Observable
public final class PhoneClient {
    public nonisolated static let logger = Logger(subsystem: "com.realmeric.oricode.phone", category: "client")
    public nonisolated static let differentAccount = "Sign in to the same Apple Account as your Mac."
    /// How long the Mac takes a command before refusing it, by CloudKit's clock.
    public nonisolated static let commandLife: TimeInterval = 600

    /// A command sent, until it has been answered and seen.
    public struct Sent: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case waiting
            case done
            case refused(String)
        }

        public let id: String
        public let action: Command.Action
        public var state: State
        /// For a new thread, the thread the Mac made.
        public var thread: UUID?
        public let at: Date

        /// Refused by the Mac, or never taken in its time.
        public func undelivered(now: Date = .now) -> Bool {
            if case .refused = state { return true }
            return state == .waiting && now.timeIntervalSince(at) > PhoneClient.commandLife
        }
    }

    public private(set) var paired: Paired?
    public private(set) var pairing = false
    /// The one line when the phone and the Mac can't meet.
    public private(set) var problem: String?
    public private(set) var mac: MacInfo?
    public private(set) var projects: [UUID: ProjectInfo] = [:]
    public private(set) var threads: [UUID: ThreadInfo] = [:]
    public private(set) var asks: [String: AskInfo] = [:]
    public private(set) var sent: [String: Sent] = [:]
    /// The nudges the Mac wrote, by ask or reply; the notification extension shows them.
    public private(set) var nudges: [String: NudgeInfo] = [:]

    @ObservationIgnored var sync: ZoneSync?
    /// Every record of the Mac's zone as fetched, so a new state key can open them again.
    @ObservationIgnored var records: [CKRecord.ID: CKRecord] = [:]
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchAgain = false
    /// Whether the Nudge subscription is saved: it can't be until the Mac has written a first
    /// Nudge, which makes the record type, so it's tried again after each read until it is.
    @ObservationIgnored private var nudgesAsked = false
    @ObservationIgnored let keychain: PhoneKeychain
    @ObservationIgnored let deviceName: String
    @ObservationIgnored let folder: URL
    @ObservationIgnored let registerForPushes: () -> Void

    var container: CKContainer { CKContainer(identifier: Container.identifier) }
    private var tokenFile: URL { folder.appending(path: "Token") }
    private var cacheFile: URL { folder.appending(path: "Cache.json") }

    /// What the phone last saw, kept so a launch shows it at once and reads behind it.
    public struct Cache: Codable, Sendable {
        public var mac: MacInfo?
        public var projects: [ProjectInfo]
        public var threads: [ThreadInfo]
        public var asks: [AskInfo]

        public init(mac: MacInfo?, projects: [ProjectInfo], threads: [ThreadInfo], asks: [AskInfo]) {
            self.mac = mac
            self.projects = projects
            self.threads = threads
            self.asks = asks
        }
    }

    public init(keychain: PhoneKeychain, deviceName: String, folder: URL, registerForPushes: @escaping () -> Void) {
        self.keychain = keychain
        self.deviceName = deviceName
        self.folder = folder
        self.registerForPushes = registerForPushes
        paired = keychain.read()
        if paired != nil {
            readCache()
            start()
        }
    }

    private func readCache() {
        guard let data = try? Data(contentsOf: cacheFile), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return }
        show(cache)
    }

    private func writeCache() {
        let cache = Cache(mac: mac, projects: Array(projects.values), threads: Array(threads.values), asks: Array(asks.values))
        guard let data = try? JSONEncoder().encode(cache) else { return }
#if os(iOS)
        try? data.write(to: cacheFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
#else
        try? data.write(to: cacheFile, options: .atomic)
#endif
    }

    private func show(_ cache: Cache) {
        mac = cache.mac
        projects = Dictionary(cache.projects.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        threads = Dictionary(cache.threads.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        asks = Dictionary(cache.asks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
    }

    /// A made-up Mac for screenshots of the screens, with nothing paired and nothing in CloudKit.
    public func showForScreenshots(_ cache: Cache) {
        paired = Paired(mac: UUID(), phone: "phone-screenshots", privateKey: Data(), pairingKey: Data(count: 32), stateKey: Data(count: 32))
        show(cache)
    }

    // MARK: Pairing

    /// The code read off the Mac's screen: the phone's record goes into the Mac's zone with its
    /// public key and the proof that it read the code, and the Mac writes the state key into it,
    /// wrapped for this phone alone.
    public func pair(with code: PairingCode) async {
        guard !pairing, paired == nil else { return }
        pairing = true
        problem = nil
        defer { pairing = false }
        guard (try? await container.accountStatus()) == .available else {
            Self.logger.notice("pairing: iCloud isn't available")
            problem = Self.differentAccount
            return
        }
        let own = Curve25519.KeyAgreement.PrivateKey()
        let name = "phone-\(UUID().uuidString)"
        let database = container.privateCloudDatabase
        do {
            let pairingKey = try Pairing.key(own: own, other: code.macKey, secret: code.secret, mac: code.mac, phone: name)
            let record = CKRecord(recordType: RecordType.phone, recordID: CKRecord.ID(recordName: name, zoneID: Zone.id(mac: code.mac)))
            record.encryptedValues[Field.key] = own.publicKey.rawRepresentation
            record.encryptedValues[Field.proof] = Pairing.proof(phoneKey: own.publicKey.rawRepresentation, secret: code.secret)
            try record.seal(PhoneInfo(name: deviceName), key: pairingKey)
            // A code read the moment it went up can beat the Mac's new zone to iCloud by a second.
            for attempt in 1...3 {
                do {
                    _ = try await database.save(record)
                    break
                } catch let error as CKError where (error.code == .zoneNotFound || error.code == .userDeletedZone) && attempt < 3 {
                    try await Task.sleep(for: .seconds(2))
                }
            }
            Self.logger.notice("pairing: the phone's record is saved")
            // The Mac looks every few seconds while its code is up.
            for _ in 0..<40 {
                try await Task.sleep(for: .seconds(1))
                let read = try await database.record(for: record.recordID)
                guard let wrapped = read.data(Field.wrapped) else { continue }
                let state = try Pairing.unwrap(wrapped, with: pairingKey, phone: name)
                let made = Paired(mac: code.mac, phone: name, privateKey: own.rawRepresentation, pairingKey: pairingKey.data, stateKey: state.data)
                keychain.write(made)
                paired = made
                Self.logger.notice("paired")
                start()
                return
            }
            _ = try? await database.deleteRecord(withID: record.recordID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The Mac's zone is in another account's database.
            problem = Self.differentAccount
        } catch {
            // A code used already, or one that ran out: its record was deleted by the Mac.
            Self.logger.notice("pairing failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// From the phone: its record goes, which tells the Mac, and so does everything it kept.
    public func unpair() {
        if let paired {
            let id = CKRecord.ID(recordName: paired.phone, zoneID: paired.zone)
            let database = container.privateCloudDatabase
            Task.detached { _ = try? await database.deleteRecord(withID: id) }
        }
        forget()
    }

    /// Unpaired, from either side: keys, records and the sync state go.
    public func forget() {
        keychain.remove()
        sync = nil
        records = [:]
        paired = nil
        mac = nil
        projects = [:]
        threads = [:]
        asks = [:]
        sent = [:]
        nudges = [:]
        nudgesAsked = false
        try? FileManager.default.removeItem(at: tokenFile)
        try? FileManager.default.removeItem(at: cacheFile)
    }

    // MARK: Commands

    /// Sealed with this phone's pairing key, so the Mac knows which phone sent it and no other can
    /// write as it; the Mac answers into the same record.
    @discardableResult
    public func send(_ action: Command.Action) -> String? {
        guard let record = command(action) else { return nil }
        write(saving: [record])
        return record.recordID.recordName
    }

    /// The same, for a notification's button, which has the app only until the command is in
    /// iCloud: it returns once it is, or once it couldn't be.
    public func sendNow(_ action: Command.Action) async -> Bool {
        guard let record = command(action), let sync else { return false }
        do {
            return try await sync.write(saving: [record], deleting: []).isEmpty
        } catch {
            return false
        }
    }

    private func command(_ action: Command.Action) -> CKRecord? {
        guard let paired else { return nil }
        let name = "command-\(UUID().uuidString)"
        let record = CKRecord(recordType: RecordType.command, recordID: CKRecord.ID(recordName: name, zoneID: paired.zone))
        record.encryptedValues[Field.phone] = paired.phone
        guard (try? record.seal(Command(action), key: paired.pairing)) != nil else { return nil }
        sent[name] = Sent(id: name, action: action, state: .waiting, at: .now)
        return record
    }

    /// The latest stop sent for a thread, while it matters.
    public func stopSent(for thread: UUID) -> Sent? {
        sent.values.filter { if case .stop(thread) = $0.action { true } else { false } }.max { $0.at < $1.at }
    }

    /// An undelivered command, sent again as a new one.
    public func resend(_ id: String) {
        guard let old = sent[id] else { return }
        clear(id)
        send(old.action)
    }

    /// Done with: its record goes.
    public func clear(_ id: String) {
        sent[id] = nil
        guard let paired else { return }
        write(deleting: [CKRecord.ID(recordName: id, zoneID: paired.zone)])
    }

    // MARK: The zone

    func start() {
        guard sync == nil, let paired else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sync = ZoneSync(zone: paired.zone, token: try? Data(contentsOf: tokenFile))
        self.sync = sync
        registerForPushes()
        Task {
            try? await sync.subscribe()
            await fetch()
        }
    }

    private func askForNudges() {
        guard !nudgesAsked, let sync else { return }
        nudgesAsked = true
        Task {
            do {
                try await sync.subscribeToNudges()
            } catch {
                nudgesAsked = false
            }
        }
    }

    /// What the Mac wrote since the last read; one at a time, and asked again meanwhile it reads
    /// again after. A zone that's gone is the Mac having turned the phone off.
    public func fetch() async {
        guard let sync else { return }
        guard !fetching else { return fetchAgain = true }
        fetching = true
        defer { fetching = false }
        repeat {
            fetchAgain = false
            do {
                let changes = try await sync.fetch()
                guard sync === self.sync else { return }
                for record in changes.changed { fetched(record) }
                for (id, type) in changes.deleted { gone(id, type: type) }
                try? sync.tokenData?.write(to: tokenFile, options: .atomic)
                if !changes.changed.isEmpty || !changes.deleted.isEmpty { writeCache() }
                askForNudges()
            } catch ZoneSync.Gone.zone {
                Self.logger.notice("the Mac's zone is gone")
                forget()
                return
            } catch {
                Self.logger.error("couldn't read: \(error.localizedDescription, privacy: .public)")
            }
        } while fetchAgain
    }

    /// A push from the Mac's zone.
    public func pushed(_ userInfo: [AnyHashable: Any]) async {
        guard let zone = paired?.zone, ZoneSync.isPush(userInfo, for: zone) else { return }
        await fetch()
    }

    private func write(saving: [CKRecord] = [], deleting: [CKRecord.ID] = []) {
        guard let sync else { return }
        Task {
            do {
                let failed = try await sync.write(saving: saving, deleting: deleting)
                for (id, error) in failed {
                    Self.logger.error("couldn't write \(id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    if sent[id.recordName] != nil { sent[id.recordName]?.state = .refused(error.localizedDescription) }
                }
            } catch {
                Self.logger.error("couldn't write: \(error.localizedDescription, privacy: .public)")
                for record in saving where sent[record.recordID.recordName] != nil {
                    sent[record.recordID.recordName]?.state = .refused(error.localizedDescription)
                }
            }
        }
    }

    private func fetched(_ record: CKRecord) {
        records[record.recordID] = record
        guard var paired else { return }
        switch record.recordType {
        case RecordType.phone:
            // The Mac's new state key, after another phone left: everything is opened again with it.
            guard record.recordID.recordName == paired.phone, let wrapped = record.data(Field.wrapped),
                  let state = try? Pairing.unwrap(wrapped, with: paired.pairing, phone: paired.phone), state.data != paired.stateKey
            else { return }
            paired.stateKey = state.data
            keychain.write(paired)
            self.paired = paired
            for record in records.values { open(record) }
        case RecordType.command:
            let name = record.recordID.recordName
            guard record.string(Field.phone) == paired.phone, let outcome = try? record.open(Outcome.self, key: paired.pairing, field: Field.outcome) else { return }
            if sent[name] != nil {
                sent[name]?.state = outcome.ok ? .done : .refused(outcome.reason ?? "")
                sent[name]?.thread = outcome.thread
            }
            // Read: the record has done its work. What it said stays in `sent` until cleared.
            records[record.recordID] = nil
            write(deleting: [record.recordID])
        default:
            open(record)
        }
    }

    /// One of the Mac's records, opened; one sealed with a key this phone no longer has is skipped
    /// until the Mac seals it again.
    private func open(_ record: CKRecord) {
        guard let key = paired?.state else { return }
        switch record.recordType {
        case RecordType.mac:
            if let info = try? record.open(MacInfo.self, key: key) { mac = info }
        case RecordType.project:
            if let info = try? record.open(ProjectInfo.self, key: key) { projects[info.id] = info }
        case RecordType.thread:
            if let info = try? record.open(ThreadInfo.self, key: key) { threads[info.id] = info }
        case RecordType.ask:
            if let info = try? record.open(AskInfo.self, key: key) { asks[info.id] = info }
        case RecordType.nudge:
            if let info = try? record.open(NudgeInfo.self, key: key) { nudges[RecordName.id(in: record.recordID.recordName)] = info }
        default:
            break
        }
    }

    private func gone(_ id: CKRecord.ID, type: String) {
        records[id] = nil
        let named = RecordName.id(in: id.recordName)
        switch type {
        case RecordType.phone where id.recordName == paired?.phone:
            Self.logger.notice("the Mac unpaired this phone")
            forget()
        case RecordType.project:
            if let project = UUID(uuidString: named) { projects[project] = nil }
        case RecordType.thread:
            if let thread = UUID(uuidString: named) { threads[thread] = nil }
        case RecordType.ask:
            asks[named] = nil
        case RecordType.nudge:
            nudges[named] = nil
        default:
            break
        }
    }
}
