import CloudKit
import CryptoKit
import Foundation
import Link
import Security

/// What the Mac keeps to talk to its phones, as one item in the login keychain's data protection
/// side, OriCode's own: the Mac's id, its X25519 key, the state key every Mac record is sealed
/// with, and each paired phone's name and pairing key. Never written anywhere else.
struct PhoneKeys: Codable, Equatable {
    struct Phone: Codable, Equatable, Identifiable {
        /// Its record's name, which is how commands name it.
        let id: String
        var name: String
        let key: Data

        var pairingKey: SymmetricKey { SymmetricKey(data: key) }
    }

    let mac: UUID
    let privateKey: Data
    var stateKey: Data
    var phones: [Phone] = []

    static func make() -> PhoneKeys {
        PhoneKeys(mac: UUID(), privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation, stateKey: SymmetricKey(size: .bits256).data)
    }

    var agreement: Curve25519.KeyAgreement.PrivateKey {
        // Made by make() from a key of the right size, so it reads back.
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
    }

    var state: SymmetricKey { SymmetricKey(data: stateKey) }

    var zone: CKRecordZone.ID { Zone.id(mac: mac) }

    // MARK: Keychain

    private static let service = (Bundle.main.bundleIdentifier ?? "com.realmeric.oricode") + ".phone"

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: "link", kSecUseDataProtectionKeychain: true]
    }

    static func read() -> PhoneKeys? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return try? JSONDecoder().decode(PhoneKeys.self, from: data)
    }

    func write() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let update = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        var status = SecItemUpdate(Self.query as CFDictionary, update)
        if status == errSecItemNotFound {
            var add = Self.query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { PhoneLink.logger.error("the keychain didn't keep the phone's keys: \(status)") }
    }

    static func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
