import AppKit
import CloudKit
import CryptoKit
import Link
import os

/// The Mac's side of the phone (KANBAN-phone.md): its pairing, and the records it meets the phone
/// in, in a zone of its own in the private database. With the switch off, or on with no phone
/// paired and no code up, it does nothing and CloudKit is never touched. Paired, it writes only
/// when something the phone shows has changed, and reads when a push says the phone wrote.
@MainActor
@Observable
final class PhoneLink {
    static let onKey = "phone"
    /// Whether a phone is paired, so launch knows without reading the keychain.
    static let pairedKey = "phonePaired"
    nonisolated static let logger = Logger(subsystem: "com.realmeric.oricode", category: "phone")
    /// How long a pairing code stays good, and how often the Mac looks for the phone that read it
    /// while the code is on screen.
    static let codeLife = Duration.seconds(300)
    static let codeLook = Duration.seconds(3)

    private(set) var on = UserDefaults.standard.bool(forKey: onKey)
    private(set) var phones: [PhoneKeys.Phone] = []
    /// The code on screen while pairing.
    private(set) var code: PairingCode?
    /// The phone that read it, by its name, for the sheet to say before it goes.
    private(set) var justPaired: String?
    /// Why the phone can't be used, in one line, when iCloud says so.
    private(set) var problem: String?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored var keys: PhoneKeys?
    @ObservationIgnored var sync: ZoneSync?
    /// The phone on the same Wi-Fi, told the moment the Mac wrote, and telling it the same.
    @ObservationIgnored var near: NearHost?
    /// What's to be saved and deleted at the next write.
    @ObservationIgnored var outbox: [CKRecord.ID: CKRecord] = [:]
    @ObservationIgnored var doomed: Set<CKRecord.ID> = []
    /// CloudKit's copy of each record the Mac has read, the phones' among them.
    @ObservationIgnored var known: [CKRecord.ID: CKRecord] = [:]
    /// What was last sealed for each record, as the JSON it was sealed from, so only a change is written.
    @ObservationIgnored var sentBoxes: [String: Data] = [:]
    @ObservationIgnored var sentAsks: [String] = []
    @ObservationIgnored var writing: Task<Void, Never>?
    @ObservationIgnored var lastWrite = ContinuousClock.now - .seconds(60)
    /// Threads seen at work since OriCode opened, which the phone lists as ⌘⇧I does.
    @ObservationIgnored var seen: Set<UUID> = []
    /// Each listed thread's latest finished reply.
    @ObservationIgnored var replies: [UUID: String?] = [:]
    /// The threads whose reply is being read from the store.
    @ObservationIgnored var readingReplies: Set<UUID> = []
    /// When each ask was first seen waiting.
    @ObservationIgnored var askedAt: [String: Date] = [:]
    /// The threads phones are watching, and their pages (PhoneLink+Talk.swift).
    @ObservationIgnored var talk = TalkState()
    /// OriPass's socket, looked for only while a phone is paired (PhoneLink+OriPass.swift).
    @ObservationIgnored var oriPass = OriPassLine()
    /// Threads the phone wrote to, whose turn's end the phone always hears about, those it stopped,
    /// whose end it knows of, how each thread stood at the last write, and the nudges ends made.
    @ObservationIgnored var messaged: Set<UUID> = []
    @ObservationIgnored var stoppedHere: Set<UUID> = []
    @ObservationIgnored var statuses: [UUID: ThreadStatus] = [:]
    @ObservationIgnored var endNudges: [CKRecord.ID] = []
    /// Asks the phone was buzzed for, and asks seen while Meriç was at the Mac, which aren't.
    @ObservationIgnored var nudged: Set<String> = []
    @ObservationIgnored var passed: Set<String> = []
    @ObservationIgnored private var lockWatch: NSObjectProtocol?
    /// The zone being made and subscribed to, which every read and write waits for.
    @ObservationIgnored var making: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var fetching = false
    @ObservationIgnored private var fetchAgain = false
    @ObservationIgnored private var secret: Data?
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private var sleepWatch: [NSObjectProtocol] = []
    @ObservationIgnored private var activeWatch: NSObjectProtocol?
    @ObservationIgnored private var tearing: Task<Void, Never>?
    /// The look for the phone's answers while something waits on it (see `pace`).
    @ObservationIgnored private var pacing: (every: Duration, task: Task<Void, Never>)?
    /// What the look's pace is read from: the last write's asks and work, the screen, the window,
    /// whether the zone's pushes are known to come, and when the phone was last buzzed.
    @ObservationIgnored private var asking = false
    @ObservationIgnored private var working = false
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var asleep = false
    @ObservationIgnored private var shown = true
    @ObservationIgnored private var pushesCome = false
    @ObservationIgnored var nudgedAt: ContinuousClock.Instant?
    @ObservationIgnored private var unlockWatch: NSObjectProtocol?
    @ObservationIgnored private var shownWatch: NSObjectProtocol?

    var container: CKContainer { CKContainer(identifier: Container.identifier) }
    var running: Bool { sync != nil }

    /// At launch, after the first frame: picks up the phones paired before, and with none, nothing.
    func resume() {
        guard on, UserDefaults.standard.bool(forKey: Self.pairedKey), let keys = PhoneKeys.read(), !keys.phones.isEmpty else { return }
        self.keys = keys
        phones = keys.phones
        start()
    }

    func turn(on: Bool) {
        self.on = on
        UserDefaults.standard.set(on, forKey: Self.onKey)
        if on {
            Task { await checkAccount() }
        } else {
            stopPairing()
            tearDownSoon(forgetting: true)
        }
    }

    func checkAccount() async {
        let status = try? await container.accountStatus()
        problem = status == .available ? nil : "Sign in to iCloud in System Settings to use your phone."
    }

    // MARK: The zone

    /// The zone made if it isn't there, its push asked for, and read whole: a few kilobytes, so
    /// what an earlier launch wrote and nothing holds now is known, and goes at the first write.
    func start() {
        guard sync == nil, let keys else { return }
        let sync = ZoneSync(zone: keys.zone)
        self.sync = sync
        NSApp.registerForRemoteNotifications()
        let near = NearHost(mac: keys.mac, key: { [weak self] name in self?.keys?.phones.first { $0.id == name }?.pairingKey }) { [weak self] in
            self?.fetchNow(.near)
        }
        near.start()
        self.near = near
        oriPass.start()
        watchSleep()
        Self.logger.notice("link started")
        making = Task {
            do {
                try await sync.makeZone()
                try await sync.subscribe(mac: true)
            } catch {
                Self.logger.error("couldn't make the zone: \(error.localizedDescription, privacy: .public)")
            }
        }
        Task {
            await fetch()
            published()
        }
    }

    func stop() {
        sync = nil
        near?.stop()
        near = nil
        oriPass.stop()
        making = nil
        writing?.cancel()
        writing = nil
        _ = endingTalk()
        outbox = [:]
        doomed = []
        known = [:]
        sentBoxes = [:]
        sentAsks = []
        for observer in sleepWatch { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        sleepWatch = []
        activeWatch.map(NotificationCenter.default.removeObserver)
        activeWatch = nil
        lockWatch.map(DistributedNotificationCenter.default().removeObserver)
        lockWatch = nil
        unlockWatch.map(DistributedNotificationCenter.default().removeObserver)
        unlockWatch = nil
        shownWatch.map(NotificationCenter.default.removeObserver)
        shownWatch = nil
        pushesCome = false
        nudgedAt = nil
        nudged = []
        passed = []
        pacing?.task.cancel()
        pacing = nil
        Self.logger.notice("link stopped")
    }

    /// Kept so a code put up while the zone is still going waits for it to have gone.
    func tearDownSoon(forgetting: Bool) {
        let before = tearing
        tearing = Task {
            await before?.value
            await tearDown(forgetting: forgetting)
        }
    }

    /// The zone goes, and every record in it, and the link stops; with `forgetting`, the Mac's keys go too.
    private func tearDown(forgetting: Bool) async {
        if let sync { try? await sync.deleteZone() }
        stop()
        phones = []
        UserDefaults.standard.set(false, forKey: Self.pairedKey)
        if forgetting {
            PhoneKeys.remove()
            keys = nil
        } else if var keys {
            keys.phones = []
            keys.write()
            self.keys = keys
        }
    }

    /// A record to write: the one waiting to go, or the copy read from CloudKit, or a new one,
    /// which a save puts over whatever is there.
    func record(_ type: String, _ name: String) -> CKRecord? {
        guard let keys else { return nil }
        let id = CKRecord.ID(recordName: name, zoneID: keys.zone)
        return outbox[id] ?? known[id] ?? CKRecord(recordType: type, recordID: id)
    }

    func put(_ record: CKRecord) {
        doomed.remove(record.recordID)
        outbox[record.recordID] = record
    }

    func delete(_ id: CKRecord.ID) {
        outbox[id] = nil
        known[id] = nil
        doomed.insert(id)
    }

    /// Everything put or deleted since the last write, in one request; what's put meanwhile goes
    /// in the next.
    func sendNow() {
        guard let sync, !flushing, !outbox.isEmpty || !doomed.isEmpty else { return }
        flushing = true
        let saving = Array(outbox.values)
        let deleting = Array(doomed)
        outbox = [:]
        doomed = []
        Task {
            await making?.value
            do {
                let failed = try await sync.write(saving: saving, deleting: deleting)
                near?.tell()
                for (id, error) in failed { Self.logger.error("couldn't write \(id.recordName, privacy: .public): \(error.localizedDescription, privacy: .public)") }
            } catch {
                // The zone is gone from under the link, an iCloud reset say: made again, and
                // everything written into it again.
                Self.logger.error("couldn't write: \(error.localizedDescription, privacy: .public)")
                if sync === self.sync, error is ZoneSync.Gone {
                    try? await sync.makeZone()
                    try? await sync.subscribe(mac: true)
                    published(again: true)
                }
            }
            flushing = false
            if sync === self.sync { sendNow() }
        }
    }

    /// Why the Mac reads: a push, the phone on the same Wi-Fi, the timed look, Meriç back at it,
    /// a code on screen, or a read asked for while one ran.
    enum Reading { case pushed, near, polled, back, pairing, again }

    /// What the phone wrote since the last read. One at a time; asked again meanwhile, it reads
    /// again after. A look or a return that finds a command or a phone's record no push brought
    /// says the pushes don't come, and the look goes back to its untrusting pace.
    func fetch(_ reading: Reading = .back) async {
        guard let sync else { return }
        guard !fetching else {
            if reading != .polled { fetchAgain = true }
            return
        }
        fetching = true
        defer { fetching = false }
        await making?.value
        var reading = reading
        repeat {
            fetchAgain = false
            do {
                let changes = try await sync.fetch()
                guard sync === self.sync else { return }
                Self.logger.notice("read, \(String(describing: reading), privacy: .public)")
                let phoneWrote = changes.changed.contains(where: Self.phoneWrote) || changes.deleted.contains { $0.type == RecordType.phone }
                if phoneWrote, pushesCome, reading == .polled || reading == .back {
                    Self.logger.notice("the phone wrote and no push said so")
                    pushesCome = false
                    repace()
                }
                for record in changes.changed { fetched(record) }
                for (id, type) in changes.deleted { gone(id, type: type) }
            } catch {
                Self.logger.error("couldn't read: \(error.localizedDescription, privacy: .public)")
            }
            reading = .again
        } while fetchAgain
        sendNow()
    }

    /// What the phone writes and the Mac hasn't answered: a command with no outcome, or a phone's own record.
    nonisolated static func phoneWrote(_ record: CKRecord) -> Bool {
        record.recordType == RecordType.phone || record.recordType == RecordType.command && record.data(Field.outcome) == nil
    }

    func fetchNow(_ reading: Reading = .back) {
        Task { await fetch(reading) }
    }

    /// A silent push from the zone's subscription: the phone wrote, and the pushes come.
    func pushed(_ userInfo: [AnyHashable: Any]) {
        guard let keys else { return }
        let ours = ZoneSync.isPush(userInfo, for: keys.zone)
        Self.logger.notice("a push, \(ours ? "the zone's" : "not the zone's", privacy: .public)")
        guard ours else { return }
        if !pushesCome {
            pushesCome = true
            repace()
        }
        fetchNow(.pushed)
    }

    /// What the timed look is paced by.
    struct Poll: Equatable {
        var asking = false
        var watched = false
        var working = false
        /// The phone was buzzed in the last ten minutes, and may be answered from its notification.
        var nudged = false
        var pushesCome = false
        var locked = false
        var asleep = false
        var shown = true
    }

    static let nudgeWindow: Duration = .seconds(600)

    /// A push is how the phone's commands reach the Mac, but CloudKit's silent pushes come late or
    /// not at all: on Meriç's Mac none came, and a message from the phone waited until something on
    /// the Mac started working (2026-10-26). So the Mac also looks, as little as that allows. Asleep,
    /// never. While the phone is in use, an ask waiting, a thread watched or a buzz in the last ten
    /// minutes, it looks whatever the screen, every five seconds for an ask or a watched thread and
    /// fifteen after a buzz, or once a minute once a push has come. Otherwise it looks only while
    /// Meriç is at the window, unlocked and shown, every fifteen seconds while a thread works and
    /// twenty with nothing working, and not at all once pushes come: the look was waking the Mac
    /// three times a minute all day (K-384). Every return, a wake, an unlock, the window shown or
    /// OriCode brought forward, reads at once, so a write a lost push left behind is read the moment
    /// Meriç is back. Without a phone paired the Mac never looks (rule 6).
    nonisolated static func pollEvery(_ poll: Poll) -> Duration? {
        guard !poll.asleep else { return nil }
        let phoneInUse = poll.asking || poll.watched || poll.nudged
        if poll.pushesCome { return phoneInUse ? .seconds(60) : nil }
        if poll.asking || poll.watched { return .seconds(5) }
        if poll.nudged { return .seconds(15) }
        guard !poll.locked, poll.shown else { return nil }
        return poll.working ? .seconds(15) : .seconds(20)
    }

    private var poll: Poll {
        Poll(asking: asking, watched: !talk.leases.threads.isEmpty, working: working,
             nudged: nudgedAt.map { ContinuousClock.now - $0 < Self.nudgeWindow } ?? false,
             pushesCome: pushesCome, locked: locked, asleep: asleep, shown: shown)
    }

    func pace(asking: Bool, working: Bool) {
        self.asking = asking
        self.working = working
        repace()
    }

    /// The look started, changed or stopped for how things stand now; each look asks again after
    /// it reads, so a buzz's ten minutes run out by themselves.
    func repace() {
        let every = sync == nil ? nil : Self.pollEvery(poll)
        guard every != pacing?.every else { return }
        pacing?.task.cancel()
        Self.logger.notice("looking \(every.map { "every \($0.components.seconds)s" } ?? "no more", privacy: .public)")
        guard let every else { return pacing = nil }
        pacing = (every, Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                await self?.fetch(.polled)
                self?.repace()
            }
        })
    }

    /// Back at the Mac: whatever the phone did meanwhile is read now, and the look paced again.
    private func back() {
        repace()
        fetchNow(.back)
    }

    private func fetched(_ record: CKRecord) {
        known[record.recordID] = record
        switch record.recordType {
        case RecordType.phone: phoneWrote(record)
        case RecordType.command: commanded(record)
        default: break
        }
    }

    private func gone(_ id: CKRecord.ID, type: String) {
        known[id] = nil
        if type == RecordType.phone, phones.contains(where: { $0.id == id.recordName }) {
            Self.logger.notice("a phone unpaired itself")
            forget(phone: id.recordName)
        }
    }

    // MARK: Pairing

    /// A code for the sheet, good for five minutes or until the sheet closes, with the Mac looking
    /// for the phone that reads it every few seconds while it's up.
    func startPairing() {
        if let going = tearing {
            tearing = nil
            Task {
                await going.value
                startPairing()
            }
            return
        }
        if keys == nil, let kept = PhoneKeys.read() {
            keys = kept
        } else if keys == nil {
            let made = PhoneKeys.make()
            made.write()
            keys = made
        }
        guard let keys else { return }
        start()
        let secret = Pairing.newSecret()
        self.secret = secret
        justPaired = nil
        code = PairingCode(mac: keys.mac, macKey: keys.agreement.publicKey.rawRepresentation, secret: secret)
        publishMac(.awake)
        sendNow()
        looking?.cancel()
        looking = Task { [weak self] in
            let until = ContinuousClock.now + Self.codeLife
            while ContinuousClock.now < until {
                try? await Task.sleep(for: Self.codeLook)
                guard !Task.isCancelled else { return }
                await self?.fetch(.pairing)
            }
            // Run out, and not replaced by a newer code meanwhile.
            guard !Task.isCancelled else { return }
            self?.code = nil
            self?.secret = nil
        }
    }

    /// The sheet closed: the code is worth nothing from now on, and with no phone paired the
    /// zone goes and CloudKit isn't touched again.
    func stopPairing() {
        looking?.cancel()
        looking = nil
        code = nil
        secret = nil
        if phones.isEmpty, running { tearDownSoon(forgetting: false) }
    }

    private func phoneWrote(_ record: CKRecord) {
        let name = record.recordID.recordName
        guard !phones.contains(where: { $0.id == name }) else { return }
        guard var keys, let secret, let phoneKey = record.data(Field.key), let proof = record.data(Field.proof),
              record.data(Field.wrapped) == nil, Pairing.check(proof: proof, phoneKey: phoneKey, secret: secret),
              let pairingKey = try? Pairing.key(own: keys.agreement, other: phoneKey, secret: secret, mac: keys.mac, phone: name),
              let info = try? record.open(PhoneInfo.self, key: pairingKey),
              let wrapped = try? Pairing.wrap(keys.state, with: pairingKey, phone: name)
        else {
            // A code used already, or a phone that never read it: nothing of it stays.
            Self.logger.notice("a phone's record that didn't pair was deleted")
            delete(record.recordID)
            return
        }
        record.encryptedValues[Field.wrapped] = wrapped
        put(record)
        keys.phones.append(PhoneKeys.Phone(id: name, name: info.name, key: pairingKey.data))
        keys.write()
        self.keys = keys
        phones = keys.phones
        UserDefaults.standard.set(true, forKey: Self.pairedKey)
        // Single use: the same code read again pairs nothing.
        self.secret = nil
        code = nil
        looking?.cancel()
        justPaired = info.name
        published()
        Self.logger.notice("paired a phone")
    }

    /// Unpair from the Mac: the phone's record goes, and so does every key it held.
    func unpair(_ phone: PhoneKeys.Phone) {
        guard let keys else { return }
        delete(CKRecord.ID(recordName: phone.id, zoneID: keys.zone))
        forget(phone: phone.id)
    }

    /// A phone gone, from either side: a new state key for the phones left, and everything sealed
    /// again with it, so the one that went reads nothing written after; with none left, the zone goes.
    private func forget(phone: String) {
        guard var keys else { return }
        keys.phones.removeAll { $0.id == phone }
        phones = keys.phones
        if keys.phones.isEmpty {
            keys.write()
            self.keys = keys
            UserDefaults.standard.set(false, forKey: Self.pairedKey)
            // A code on screen keeps the zone for the phone about to read it.
            if code == nil { tearDownSoon(forgetting: false) }
            return
        }
        keys.stateKey = SymmetricKey(size: .bits256).data
        keys.write()
        self.keys = keys
        for left in keys.phones {
            guard let record = record(RecordType.phone, left.id), let wrapped = try? Pairing.wrap(keys.state, with: left.pairingKey, phone: left.id) else { continue }
            record.encryptedValues[Field.wrapped] = wrapped
            put(record)
        }
        published(again: true)
    }

    // MARK: The Mac's state

    private func macRecord(_ state: MacState) -> CKRecord? {
        guard let keys, let record = record(RecordType.mac, RecordName.mac) else { return nil }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        try? record.seal(MacInfo(name: Host.current().localizedName ?? "Mac", version: version, state: state), key: keys.state)
        return record
    }

    func publishMac(_ state: MacState) {
        macRecord(state).map(put)
    }

    private func watchSleep() {
        guard sleepWatch.isEmpty else { return }
        // Back at the Mac: whatever the phone did meanwhile is read now.
        activeWatch = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.back() }
        }
        lockWatch = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.locked = true
                self?.repace()
                self?.screenLocked()
            }
        }
        unlockWatch = DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.locked = false
                self?.back()
            }
        }
        shownWatch = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow, window.identifier?.rawValue.hasPrefix("main") == true else { return }
            let visible = window.occlusionState.contains(.visible)
            MainActor.assumeIsolated {
                guard let self, visible != self.shown else { return }
                self.shown = visible
                if visible { self.back() } else { self.repace() }
            }
        }
        let center = NSWorkspace.shared.notificationCenter
        sleepWatch = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.asleep = true
                    self?.repace()
                    self?.closing(as: .asleep)
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.asleep = false
                    self?.publishMac(.awake)
                    self?.sendNow()
                    self?.back()
                }
            },
        ]
    }

    /// Asleep or closed, written straight to CloudKit, waiting up to two seconds for it, since the
    /// Mac or the app may be gone before the next write. A conversation being watched goes with it.
    func closing(as state: MacState) {
        guard running, let record = macRecord(state) else { return }
        let database = container.privateCloudDatabase
        let written = OSAllocatedUnfairLock(initialState: false)
        let pages = endingTalk()
        Task.detached {
            _ = try? await database.modifyRecords(saving: [record], deleting: pages, savePolicy: .allKeys)
            written.withLock { $0 = true }
        }
        let until = Date.now.addingTimeInterval(2)
        while !written.withLock({ $0 }), Date.now < until { RunLoop.main.run(until: .now + 0.05) }
    }
}
