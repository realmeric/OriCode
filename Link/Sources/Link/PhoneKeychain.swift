import CloudKit
import CryptoKit
import Foundation
import Security

/// What a phone keeps of its pairing: which Mac, its own record and key, the pairing key and the
/// Mac's state key. The one secret the phone holds.
public struct Paired: Codable, Equatable, Sendable {
    public let mac: UUID
    /// Its Phone record's name, which its commands carry.
    public let phone: String
    public let privateKey: Data
    public let pairingKey: Data
    public var stateKey: Data

    public init(mac: UUID, phone: String, privateKey: Data, pairingKey: Data, stateKey: Data) {
        self.mac = mac
        self.phone = phone
        self.privateKey = privateKey
        self.pairingKey = pairingKey
        self.stateKey = stateKey
    }

    public var zone: CKRecordZone.ID { Zone.id(mac: mac) }
    public var pairing: SymmetricKey { SymmetricKey(data: pairingKey) }
    public var state: SymmetricKey { SymmetricKey(data: stateKey) }
}

/// The pairing in the keychain, on this device only, readable after the first unlock so the
/// notification extension can open a push while the phone is locked; in `group` when the app and
/// its extension share one.
public struct PhoneKeychain: Sendable {
    public let group: String?

    public init(group: String?) {
        self.group = group
    }

    private var query: [CFString: Any] {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.realmeric.oricode.phone",
                                      kSecAttrAccount: "paired", kSecUseDataProtectionKeychain: true]
        if let group { query[kSecAttrAccessGroup] = group }
        return query
    }

    public func read() -> Paired? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return try? JSONDecoder().decode(Paired.self, from: data)
    }

    public func write(_ paired: Paired) {
        guard let data = try? JSONEncoder().encode(paired) else { return }
        let update = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
        if SecItemUpdate(query as CFDictionary, update) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func remove() {
        SecItemDelete(query as CFDictionary)
    }
}
