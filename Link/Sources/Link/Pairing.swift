import CryptoKit
import Foundation

/// What the Mac's pairing code holds: the Mac's id, its public key and a single-use secret. Read
/// off the Mac's screen by the phone's camera, never through iCloud.
public struct PairingCode: Equatable, Sendable {
    public let mac: UUID
    public let macKey: Data
    public let secret: Data

    static let scheme = "oricode-pair:"
    static let version: UInt8 = 1

    public init(mac: UUID, macKey: Data, secret: Data) {
        self.mac = mac
        self.macKey = macKey
        self.secret = secret
    }

    public var string: String {
        var bytes = Data([Self.version])
        bytes.append(contentsOf: withUnsafeBytes(of: mac.uuid) { Array($0) })
        bytes.append(macKey)
        bytes.append(secret)
        return Self.scheme + bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public init?(string: String) {
        guard string.hasPrefix(Self.scheme) else { return nil }
        var base = String(string.dropFirst(Self.scheme.count))
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base), bytes.count == 81, bytes.first == Self.version else { return nil }
        let uuid = Array(bytes[1..<17])
        mac = UUID(uuid: (uuid[0], uuid[1], uuid[2], uuid[3], uuid[4], uuid[5], uuid[6], uuid[7],
                          uuid[8], uuid[9], uuid[10], uuid[11], uuid[12], uuid[13], uuid[14], uuid[15]))
        macKey = Data(bytes[17..<49])
        secret = Data(bytes[49..<81])
    }
}

/// The key agreement. The phone proves it read the code with an HMAC of its public key under the
/// code's secret; both sides derive the pairing key from their X25519 keys with the secret as
/// salt, so the secret never travels, and a photo of the code taken after it closed is worth nothing.
public enum Pairing {
    public static func newSecret() -> Data {
        SymmetricKey(size: .bits256).data
    }

    public static func proof(phoneKey: Data, secret: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: phoneKey, using: SymmetricKey(data: secret)))
    }

    public static func check(proof: Data, phoneKey: Data, secret: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: phoneKey, using: SymmetricKey(data: secret))
    }

    /// The same key on both sides: the Mac passes its private key and the phone's public one, the
    /// phone its own private key and the Mac's public one.
    public static func key(own: Curve25519.KeyAgreement.PrivateKey, other: Data, secret: Data, mac: UUID, phone: String) throws -> SymmetricKey {
        let shared = try own.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: other))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret, sharedInfo: Data("OriCode pairing \(mac.uuidString) \(phone)".utf8), outputByteCount: 32)
    }

    /// The Mac's state key, sealed under a phone's pairing key into that phone's record.
    public static func wrap(_ stateKey: SymmetricKey, with pairingKey: SymmetricKey, phone: String) throws -> Data {
        try Seal.seal(stateKey.data, key: pairingKey, type: RecordType.stateKey, name: phone)
    }

    public static func unwrap(_ wrapped: Data, with pairingKey: SymmetricKey, phone: String) throws -> SymmetricKey {
        SymmetricKey(data: try Seal.open(wrapped, key: pairingKey, type: RecordType.stateKey, name: phone))
    }
}
