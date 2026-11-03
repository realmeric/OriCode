import CryptoKit
import Foundation

/// OriPass's wire for an answer from the phone, as its card OP-88 writes it down, byte for byte:
/// what a request says and what the phone's key signs for it. OriCode carries a yes and can't make
/// one: the signature is the phone's, by a key OriPass registered with a finger, and OriPass works
/// the signed bytes out from its own copy of what it sent.
public enum PassWire {
    public static let version = 1
    /// A line longer than this closes the connection.
    public static let most = 16_384
    /// The longest name a phone may give itself.
    public static let longestName = 64
    private static let approving = "oripass.approve.v1"
    private static let registering = "oripass.register.v1"

    /// Four bytes of length, most significant first, and these bytes.
    public static func field(_ bytes: some Collection<UInt8>) -> Data {
        var count = UInt32(bytes.count).bigEndian
        return Data(bytes: &count, count: 4) + Data(bytes)
    }

    public static func field(_ words: String) -> Data { field(Data(words.utf8)) }

    /// The first eight bytes of the key's hash in capitals, a `-` after every four, as OriPass's
    /// card shows it beside the phone's name.
    public static func fingerprint(of publicKey: Data) -> String {
        let hex = SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { start in
            let from = hex.index(hex.startIndex, offsetBy: start)
            return String(hex[from..<hex.index(from, offsetBy: 4)])
        }.joined(separator: "-")
    }

    /// What a new key signs to show it's the phone's and not only a key.
    public static func registration(name: String, publicKey: Data) -> Data {
        Data(registering.utf8) + [0] + field(name) + field(publicKey)
    }

    static func approval(id: String, nonce: Data, wordsHash: Data) -> Data {
        Data(approving.utf8) + [0] + field(id) + field(nonce) + wordsHash
    }

    /// `yyyy-MM-ddTHH:mm:ssZ`, UTC.
    static func date(_ written: String) -> Date? {
        try? Date(written, strategy: .iso8601)
    }
}

/// One request of OriPass's, as it came down the socket. Every field is a string, `""` for one
/// with nothing to say, so every field is hashed; `act` stays the word OriPass sent, since the
/// hash is over that word.
public struct PassRequest: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Thirty-two random bytes.
    public var nonce: Data
    /// `stranger`, `forwarded`, `signature` or `list`.
    public var act: String
    /// What OriPass's card says, in lines, which the phone shows as it is.
    public var words: String
    public var app: String
    public var appID: String
    public var key: String
    public var keyFingerprint: String
    public var host: String
    public var hostKey: String
    public var expires: String

    public init(id: String, nonce: Data, act: String, words: String, app: String, appID: String, key: String,
                keyFingerprint: String, host: String, hostKey: String, expires: String) {
        self.id = id
        self.nonce = nonce
        self.act = act
        self.words = words
        self.app = app
        self.appID = appID
        self.key = key
        self.keyFingerprint = keyFingerprint
        self.host = host
        self.hostKey = hostKey
        self.expires = expires
    }

    /// A `request` line, read; nil for one missing a field.
    public init?(line: [String: Any]) {
        func string(_ name: String) -> String? { line[name] as? String }
        guard let id = string("id"), let nonce = string("nonce").flatMap({ Data(base64Encoded: $0) }), nonce.count == 32,
              let act = string("act"), let words = string("words"), let app = string("app"), let appID = string("appID"),
              let key = string("key"), let keyFingerprint = string("keyFingerprint"), let host = string("host"),
              let hostKey = string("hostKey"), let expires = string("expires")
        else { return nil }
        self.init(id: id, nonce: nonce, act: act, words: words, app: app, appID: appID, key: key, keyFingerprint: keyFingerprint,
                  host: host, hostKey: hostKey, expires: expires)
    }

    public var wordsHash: Data {
        let shown = [act, words, app, appID, key, keyFingerprint, host, hostKey, expires]
        return Data(SHA256.hash(data: shown.reduce(into: Data()) { $0.append(PassWire.field($1)) }))
    }

    /// What the phone's key signs: CryptoKit hashes it, so it's handed over whole.
    public var message: Data { PassWire.approval(id: id, nonce: nonce, wordsHash: wordsHash) }

    public var expiry: Date? { PassWire.date(expires) }

    /// Past `expires` the phone refuses by itself, and one that can't be read is past it.
    public func expired(now: Date = .now) -> Bool {
        guard let expiry else { return true }
        return now >= expiry
    }

    /// The card's first line, which says what it is: "OriCode wants to connect to buzul".
    public var statement: String {
        words.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? words
    }

    /// The lines after it, as they were sent.
    public var particulars: String {
        let lines = words.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return lines.count > 1 ? String(lines[1]) : ""
    }
}

/// What OriPass leaves to the phone, in an `Ask` record named `oripass-<id>`: a request to answer,
/// or this phone's key to register. No thread holds it and no agent sees it: it isn't an ask of any
/// conversation, so only a command sealed by a paired phone reaches it.
public struct PassAsk: Codable, Equatable, Sendable, Identifiable {
    public enum Want: Codable, Equatable, Sendable {
        case approve(PassRequest)
        /// Settings › Phone's Register, which wants the phone's key and its proof.
        case register
    }

    public var id: String
    public var want: Want
    public var asked: Date

    public init(id: String, want: Want, asked: Date) {
        self.id = id
        self.want = want
        self.asked = asked
    }

    public var request: PassRequest? {
        if case .approve(let request) = want { request } else { nil }
    }
}
