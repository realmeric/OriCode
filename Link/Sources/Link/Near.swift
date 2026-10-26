import CryptoKit
import Foundation
import Network
import os

/// The way across the same Wi-Fi: no content goes over it, only "I wrote", so the other side reads
/// iCloud at once instead of waiting on a push that comes late or not at all. The Mac listens,
/// advertised by Bonjour under its id; the phone, while it's in front, finds it and connects, and
/// proves which paired phone it is with an HMAC of the Mac's nonce under its pairing key. Lines of
/// text: the Mac's `hi <nonce>`, the phone's `me <phone> <proof>`, then `wrote` either way.
public enum Near {
    public static let service = "_oricode._tcp"
    static let logger = Logger(subsystem: "com.realmeric.oricode", category: "near")
    static let wrote = "wrote"
    /// A line longer than this is no line of ours.
    static let longest = 512

    static func proof(nonce: Data, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("OriCode near".utf8) + nonce, using: key))
    }

    /// Every line that came, read as it comes, until the connection ends or sends what isn't ours.
    @MainActor
    final class Lines {
        let connection: NWConnection
        private var buffer = Data()
        var line: (String) -> Void = { _ in }

        init(_ connection: NWConnection) {
            self.connection = connection
        }

        func send(_ line: String) {
            connection.send(content: Data((line + "\n").utf8), completion: .idempotent)
        }

        func read() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let data { self.buffer += data }
                    while let end = self.buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: self.buffer[..<end], as: UTF8.self)
                        self.buffer = Data(self.buffer[self.buffer.index(after: end)...])
                        self.line(line)
                    }
                    guard !complete, error == nil, self.buffer.count <= Near.longest else { return self.connection.cancel() }
                    self.read()
                }
            }
        }
    }
}

/// The Mac's side: listening only while a phone is paired, which costs nothing until a phone
/// connects, and telling every phone that proved itself when it has written.
@MainActor
public final class NearHost {
    private let name: String
    private let key: (String) -> SymmetricKey?
    private let heard: () -> Void
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: (lines: Near.Lines, proven: Bool)] = [:]

    /// `key` gives a paired phone's pairing key by its record's name; `heard` is a phone having written.
    public init(mac: UUID, key: @escaping (String) -> SymmetricKey?, heard: @escaping () -> Void) {
        name = mac.uuidString
        self.key = key
        self.heard = heard
    }

    public func start() {
        guard listener == nil, let listener = try? NWListener(using: .tcp) else { return }
        self.listener = listener
        listener.service = NWListener.Service(name: name, type: Near.service)
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard case .failed(let error) = state else { return }
                Near.logger.error("the listener failed: \(error.localizedDescription, privacy: .public)")
                self?.stop()
            }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for phone in phones.values { phone.lines.connection.cancel() }
        phones = [:]
    }

    /// The Mac wrote: every phone connected reads now.
    public func tell() {
        for phone in phones.values where phone.proven { phone.lines.send(Near.wrote) }
    }

    private func accept(_ connection: NWConnection) {
        let lines = Near.Lines(connection)
        let id = ObjectIdentifier(lines)
        let nonce = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        phones[id] = (lines, false)
        lines.line = { [weak self] line in self?.said(line, by: id, nonce: nonce) }
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: lines.send("hi \(nonce.base64EncodedString())")
                case .failed, .cancelled: self?.phones[id] = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        lines.read()
    }

    private func said(_ line: String, by id: ObjectIdentifier, nonce: Data) {
        guard let phone = phones[id] else { return }
        let words = line.split(separator: " ").map(String.init)
        if phone.proven {
            if line == Near.wrote { heard() }
        } else if words.count == 3, words[0] == "me", let key = key(words[1]), let proof = Data(base64Encoded: words[2]),
                  HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data("OriCode near".utf8) + nonce, using: key) {
            phones[id]?.proven = true
            Near.logger.notice("a phone is near")
        } else {
            phone.lines.connection.cancel()
        }
    }
}

/// The phone's side: while it's in front, it looks for its Mac on the network, stays connected,
/// and says when it wrote; what the Mac says it wrote, it reads.
@MainActor
public final class NearClient {
    private let mac: String
    private let phone: String
    private let key: SymmetricKey
    private let heard: () -> Void
    private var browser: NWBrowser?
    private var endpoint: NWEndpoint?
    private var lines: Near.Lines?
    private var ready = false

    public init(paired: Paired, heard: @escaping () -> Void) {
        mac = paired.mac.uuidString
        phone = paired.phone
        key = paired.pairing
        self.heard = heard
    }

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Near.service, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.found(results) }
        }
        browser.start(queue: .main)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        endpoint = nil
        drop()
    }

    /// The phone wrote: the Mac reads now, if it's near.
    public func tell() {
        if ready { lines?.send(Near.wrote) }
    }

    private func found(_ results: Set<NWBrowser.Result>) {
        endpoint = results.first { result in
            if case .service(let name, _, _, _) = result.endpoint { name == mac } else { false }
        }?.endpoint
        if endpoint == nil { drop() } else { connect() }
    }

    private func connect() {
        guard lines == nil, let endpoint else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        let lines = Near.Lines(connection)
        self.lines = lines
        lines.line = { [weak self] line in self?.said(line) }
        connection.stateUpdateHandler = { [weak self, weak lines] state in
            MainActor.assumeIsolated {
                guard let self, let lines, lines === self.lines else { return }
                switch state {
                case .failed, .cancelled:
                    self.drop()
                    // Still advertised: once more, after a moment, while the phone is in front.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        guard let self, self.browser != nil else { return }
                        self.connect()
                    }
                case .waiting:
                    connection.cancel()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        lines.read()
    }

    private func drop() {
        lines?.connection.cancel()
        lines = nil
        ready = false
    }

    private func said(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        if words.count == 2, words[0] == "hi", let nonce = Data(base64Encoded: words[1]) {
            lines?.send("me \(phone) \(Near.proof(nonce: nonce, key: key).base64EncodedString())")
            ready = true
            Near.logger.notice("near the Mac")
        } else if line == Near.wrote {
            heard()
        }
    }
}
