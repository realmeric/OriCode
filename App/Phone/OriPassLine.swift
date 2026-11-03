import Foundation
import Link
import os

/// OriCode's end of OriPass's socket, as OriPass's card OP-88 writes it down: what OriPass would
/// ask a finger for under a pass goes to the phone, and the phone's answer comes back through here
/// as it was made. It carries a yes and can't make one: an approve holds the phone's signature,
/// which OriPass checks against the key it registered with a finger. Nothing here is a
/// conversation's ask, so no agent and no setting reaches it.
///
/// The socket is there only while a pass stands and a phone is registered, or while OriPass's Add
/// Phone waits, so not finding it is the usual state. It's looked for only while a phone is
/// paired: when OriPass's folder changes, and five seconds after a try that found the file and
/// nobody listening, or every five seconds while the folder itself isn't there. Idle, nothing wakes.
@MainActor
@Observable
final class OriPassLine {
    struct Phone: Equatable {
        var name: String
        var fingerprint: String
    }

    enum Registering: Equatable {
        case idle
        /// Register was pressed and the ask is with the phone, for five minutes at most.
        case asking(id: String, since: Date)
        /// The phone's key went to OriPass, whose card on the Mac waits on a finger.
        case sent(id: String, since: Date, phone: Phone)
        case refused(String)
    }

    nonisolated static let logger = Logger(subsystem: "com.realmeric.oricode", category: "oripass")
    static let retry: Duration = .seconds(5)
    static let registerLife: TimeInterval = 300

    /// `~/.oripass/approve.sock`; a Debug build launched with `-OriPassSocket <path>` takes that
    /// instead, so a check never meets the real one.
    static var path: String {
#if DEBUG
        let arguments = CommandLine.arguments
        if let at = arguments.firstIndex(of: "-OriPassSocket"), at + 1 < arguments.count { return arguments[at + 1] }
#endif
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".oripass/approve.sock").path
    }

    /// Connected and welcomed: the one row in Settings › Phone shows only then.
    private(set) var reachable = false
    /// The phone OriPass has registered, as its welcome named it.
    private(set) var phone: Phone?
    /// Each request still open, and when it came.
    private(set) var requests: [String: (request: PassRequest, came: Date)] = [:]
    private(set) var registering = Registering.idle

    @ObservationIgnored let path: String
    @ObservationIgnored private var connection: PassConnection?
    @ObservationIgnored private var folderWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var looking: Task<Void, Never>?
    @ObservationIgnored private var registerClock: Task<Void, Never>?
    @ObservationIgnored private var on = false

    init(path: String = OriPassLine.path) {
        self.path = path
    }

    var registeringAsk: (id: String, since: Date)? {
        switch registering {
        case .asking(let id, let since), .sent(let id, let since, _): (id, since)
        default: nil
        }
    }

    // MARK: Looking for the socket

    func start() {
        guard !on else { return }
        on = true
        look()
    }

    func stop() {
        on = false
        looking?.cancel()
        looking = nil
        folderWatch?.cancel()
        folderWatch = nil
        connection?.cut()
        connection = nil
        lost()
    }

    private func look() {
        guard on, connection == nil else { return }
        let path = path
        Task.detached {
            let tried = PassConnection.connect(to: path)
            await MainActor.run { self.tried(tried) }
        }
    }

    private func tried(_ result: Result<Int32, PassConnection.Failure>) {
        guard on, connection == nil else {
            if case .success(let descriptor) = result { close(descriptor) }
            return
        }
        switch result {
        case .success(let descriptor):
            looking?.cancel()
            looking = nil
            let connection = PassConnection(descriptor: descriptor) { [weak self] line in
                self?.heard(line)
            } ended: { [weak self] in
                self?.ended(descriptor)
            }
            self.connection = connection
            connection.start()
            say(["type": "hello"])
            Self.logger.notice("connected to OriPass")
        case .failure(let failure):
            watchFolder()
            // The file with nobody behind it is a socket being made or one left over; a folder
            // that isn't there yet can't be watched.
            if failure == .refused || folderWatch == nil { lookAgain() }
        }
    }

    private func lookAgain() {
        guard looking == nil else { return }
        looking = Task { [weak self] in
            try? await Task.sleep(for: Self.retry)
            guard !Task.isCancelled else { return }
            self?.looking = nil
            self?.look()
        }
    }

    /// Any file made or taken away in OriPass's folder, which is how the socket comes and goes.
    private func watchFolder() {
        guard folderWatch == nil else { return }
        let folder = (path as NSString).deletingLastPathComponent
        let descriptor = open(folder, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    // The folder itself went: watched again once it's back.
                    self.folderWatch?.cancel()
                    self.folderWatch = nil
                    self.lookAgain()
                } else {
                    self.look()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatch = source
    }

    private func ended(_ descriptor: Int32) {
        guard connection?.descriptor == descriptor else { return }
        connection = nil
        lost()
        Self.logger.notice("OriPass's socket closed")
        look()
    }

    /// What stood on the connection goes with it: OriPass sends what's still open down the next.
    private func lost() {
        reachable = false
        requests = [:]
        if registeringAsk != nil { endRegistering(.idle) }
    }

    // MARK: The wire

    private func say(_ line: [String: Any]) {
        var line = line
        line["v"] = PassWire.version
        guard let written = try? JSONSerialization.data(withJSONObject: line, options: [.withoutEscapingSlashes]) else { return }
        connection?.say(written)
    }

    private func heard(_ line: Data) {
        guard let said = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], said["v"] as? Int == PassWire.version else { return }
        let id = said["id"] as? String
        switch said["type"] as? String {
        case "welcome":
            reachable = true
            phone = (said["phone"] as? [String: Any]).flatMap { phone in
                guard let name = phone["name"] as? String, let fingerprint = phone["fingerprint"] as? String else { return nil }
                return Phone(name: name, fingerprint: fingerprint)
            }
        case "request":
            guard let request = PassRequest(line: said) else { return Self.logger.error("a request that didn't read") }
            requests[request.id] = (request, requests[request.id]?.came ?? .now)
        case "closed":
            // Heard twice for an id, when a late approve is a replay.
            guard let id else { return }
            requests[id] = nil
            Self.logger.notice("a request closed: \(said["outcome"] as? String ?? "", privacy: .public) \(said["reason"] as? String ?? "", privacy: .public)")
        case "registered":
            if case .sent(_, _, let sent) = registering, sent.fingerprint == said["fingerprint"] as? String {
                phone = sent
            }
            endRegistering(.idle)
        case "refused":
            endRegistering(.refused(Self.refusal(said["reason"] as? String)))
        case "error":
            Self.logger.error("OriPass: \(said["code"] as? String ?? "", privacy: .public)")
            if said["code"] as? String == "unknown-id", let id { requests[id] = nil }
        default:
            break
        }
    }

    /// The phone's yes, handed over as it came; only for a request OriPass sent and hasn't closed.
    func approve(_ id: String, signature: Data) -> Bool {
        guard requests[id] != nil else { return false }
        say(["type": "approve", "id": id, "signature": signature.base64EncodedString()])
        return true
    }

    func deny(_ id: String) -> Bool {
        guard requests[id] != nil else { return false }
        say(["type": "deny", "id": id])
        return true
    }

    // MARK: Registering

    /// Settings › Phone's Register: the phone is asked for its key, and has five minutes.
    func register() {
        guard reachable else { return }
        let id = "register-\(UUID().uuidString)"
        registering = .asking(id: id, since: .now)
        registerClock?.cancel()
        registerClock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.registerLife))
            guard !Task.isCancelled, self?.registeringAsk?.id == id else { return }
            self?.registering = .idle
        }
    }

    /// The phone's key and its proof, for the ask it was given, to OriPass as they came.
    func register(_ ask: String, name: String, publicKey: Data, proof: Data) -> Bool {
        guard case .asking(ask, let since) = registering, reachable else { return false }
        let phone = Phone(name: name, fingerprint: PassWire.fingerprint(of: publicKey))
        registering = .sent(id: ask, since: since, phone: phone)
        say(["type": "register", "name": name, "publicKey": publicKey.base64EncodedString(), "proof": proof.base64EncodedString()])
        return true
    }

    private func endRegistering(_ end: Registering) {
        registerClock?.cancel()
        registerClock = nil
        registering = end
    }

    private static func refusal(_ reason: String?) -> String {
        switch reason {
        case "denied": "OriPass's card was answered no."
        case "bad-proof": "OriPass couldn't check the phone's key."
        case "not-waiting": "Press Add Phone in OriPass's Settings › Developer first."
        case "busy": "OriPass had another card up. Try again."
        default: "OriPass refused it."
        }
    }
}

/// The socket itself: a line at a time each way, read on a queue of its own and heard on the
/// main actor in the order it came.
final class PassConnection: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// No file: the usual state.
        case missing
        /// A file with nobody listening.
        case refused
        case other(Int32)
    }

    let descriptor: Int32
    private let heard: @MainActor (Data) -> Void
    private let ended: @MainActor () -> Void
    private let reading = DispatchQueue(label: "com.realmeric.oricode.oripass.reading", qos: .userInitiated)
    private let writing = DispatchQueue(label: "com.realmeric.oricode.oripass.writing", qos: .userInitiated)
    private let lock = NSLock()
    private var isOver = false

    init(descriptor: Int32, heard: @escaping @MainActor (Data) -> Void, ended: @escaping @MainActor () -> Void) {
        self.descriptor = descriptor
        self.heard = heard
        self.ended = ended
    }

    static func connect(to path: String) -> Result<Int32, Failure> {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return .failure(.other(ENAMETOOLONG)) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(.other(errno)) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let failed = errno
            close(descriptor)
            switch failed {
            case ENOENT: return .failure(.missing)
            case ECONNREFUSED: return .failure(.refused)
            default: return .failure(.other(failed))
            }
        }
        return .success(descriptor)
    }

    func start() {
        reading.async { self.readLines() }
    }

    func say(_ line: Data) {
        writing.async {
            guard !self.lock.withLock({ self.isOver }) else { return }
            var written = line + [UInt8(ascii: "\n")]
            while !written.isEmpty {
                let sent = written.withUnsafeBytes { write(self.descriptor, $0.baseAddress, $0.count) }
                if sent < 0, errno == EINTR { continue }
                guard sent > 0 else { return self.cut() }
                written.removeFirst(sent)
            }
        }
    }

    /// Reading stops, and `ended` is heard once.
    func cut() {
        let wasOver = lock.withLock { () -> Bool in
            defer { isOver = true }
            return isOver
        }
        guard !wasOver else { return }
        shutdown(descriptor, SHUT_RDWR)
        let ended = ended
        DispatchQueue.main.async { MainActor.assumeIsolated { ended() } }
    }

    deinit {
        close(descriptor)
    }

    private func readLines() {
        var held = Data()
        var chunk = [UInt8](repeating: 0, count: PassWire.most)
        while true {
            let got = read(descriptor, &chunk, chunk.count)
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { return cut() }
            held.append(contentsOf: chunk.prefix(got))
            while let end = held.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(held[held.startIndex..<end])
                held = Data(held[held.index(after: end)...])
                let heard = heard
                DispatchQueue.main.async { MainActor.assumeIsolated { heard(line) } }
            }
            guard held.count < PassWire.most else { return cut() }
        }
    }
}
