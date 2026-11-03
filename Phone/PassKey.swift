import CryptoKit
import Foundation
import Link
import LocalAuthentication
import Security

/// The phone's key for OriPass (its card OP-88): P-256 in the Secure Enclave, made once and kept
/// as the enclave's own wrapped blob in this app's keychain, this device only. It signs only for a
/// face enrolled now, so a change to Face ID means registering again. Its public half reaches
/// OriPass through the Mac and is taken there with a finger; nothing on the Mac or in iCloud can
/// sign with it.
///
/// A simulator has no enclave it will sign with: it says `SecureEnclave.isAvailable` and then
/// refuses the access control as unsupported. So a Debug build for the simulator keeps a software
/// key behind the same Face ID; a build for an iPhone, and any Release build, has no such path.
enum PassKey {
    enum Failure: Error {
        /// Face ID was cancelled, or failed.
        case declined
        case noEnclave
    }

    private static let account = "oripass"

    private static var access: SecAccessControl? {
        SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], nil)
    }

    /// The key's public half, `04 || X || Y`, made the first time.
    static func publicKey() throws -> Data {
#if DEBUG && targetEnvironment(simulator)
        return try software().publicKey.x963Representation
#else
        return try enclave(authenticating: nil).publicKey.x963Representation
#endif
    }

    static func fingerprint() -> String? {
        (try? publicKey()).map(PassWire.fingerprint(of:))
    }

    /// Face ID, then the signature over `message`, which CryptoKit hashes with SHA-256.
    static func sign(_ message: Data, reason: String) async throws -> Data {
        let context = LAContext()
#if DEBUG && targetEnvironment(simulator)
        try await face { try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) }
        return try software().signature(for: message).derRepresentation
#else
        guard let access else { throw Failure.noEnclave }
        try await face { try await context.evaluateAccessControl(access, operation: .useKeySign, localizedReason: reason) }
        return try enclave(authenticating: context).signature(for: message).derRepresentation
#endif
    }

    private static func face(_ evaluation: () async throws -> Bool) async throws {
        do {
            guard try await evaluation() else { throw Failure.declined }
        } catch {
            PhoneClient.logger.notice("Face ID: \(error.localizedDescription, privacy: .public)")
            throw Failure.declined
        }
    }

    /// For Register: the key, and its proof that it's the phone's. A key Face ID has changed under
    /// signs nothing, so it's made again, and OriPass's card then names the new one.
    static func registration(name: String) async throws -> (publicKey: Data, proof: Data) {
        do {
            let key = try publicKey()
            return (key, try await sign(PassWire.registration(name: name, publicKey: key), reason: "Register this iPhone with OriPass"))
        } catch Failure.declined {
            throw Failure.declined
        } catch {
            forget()
            let key = try publicKey()
            return (key, try await sign(PassWire.registration(name: name, publicKey: key), reason: "Register this iPhone with OriPass"))
        }
    }

    private static func enclave(authenticating context: LAContext?) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard SecureEnclave.isAvailable, let access else { throw Failure.noEnclave }
        if let kept = read() { return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: kept, authenticationContext: context) }
        let made = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: false, accessControl: access)
        write(made.dataRepresentation)
        return made
    }

#if DEBUG && targetEnvironment(simulator)
    private static func software() throws -> P256.Signing.PrivateKey {
        if let kept = read() { return try P256.Signing.PrivateKey(rawRepresentation: kept) }
        let made = P256.Signing.PrivateKey()
        write(made.rawRepresentation)
        return made
    }
#endif

    // MARK: Keychain

    private static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.realmeric.oricode.phone", kSecAttrAccount: account, kSecUseDataProtectionKeychain: true]
    }

    private static func read() -> Data? {
        var query = query
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess else { return nil }
        return found as? Data
    }

    private static func write(_ data: Data) {
        var add = query
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func forget() {
        SecItemDelete(query as CFDictionary)
    }
}
