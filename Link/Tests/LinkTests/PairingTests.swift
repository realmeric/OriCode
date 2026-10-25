import CryptoKit
import Foundation
import Testing
@testable import Link

struct PairingTests {
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let secret = Pairing.newSecret()
    let macID = UUID()

    @Test func codeReadsBackAsWritten() throws {
        let code = PairingCode(mac: macID, macKey: mac.publicKey.rawRepresentation, secret: secret)
        #expect(PairingCode(string: code.string) == code)
        #expect(PairingCode(string: "oricode-pair:short") == nil)
        #expect(PairingCode(string: "https://example.com") == nil)
    }

    @Test func proofHoldsOnlyForTheKeyAndSecretItWasMadeWith() {
        let key = phone.publicKey.rawRepresentation
        let proof = Pairing.proof(phoneKey: key, secret: secret)
        #expect(Pairing.check(proof: proof, phoneKey: key, secret: secret))
        #expect(!Pairing.check(proof: proof, phoneKey: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation, secret: secret))
        #expect(!Pairing.check(proof: proof, phoneKey: key, secret: Pairing.newSecret()))
    }

    @Test func bothSidesDeriveTheSameKey() throws {
        let onMac = try Pairing.key(own: mac, other: phone.publicKey.rawRepresentation, secret: secret, mac: macID, phone: "phone-1")
        let onPhone = try Pairing.key(own: phone, other: mac.publicKey.rawRepresentation, secret: secret, mac: macID, phone: "phone-1")
        #expect(onMac == onPhone)
        let otherSecret = try Pairing.key(own: phone, other: mac.publicKey.rawRepresentation, secret: Pairing.newSecret(), mac: macID, phone: "phone-1")
        #expect(onMac != otherSecret)
    }

    @Test func stateKeyUnwrapsOnlyForItsPhone() throws {
        let pairingKey = try Pairing.key(own: mac, other: phone.publicKey.rawRepresentation, secret: secret, mac: macID, phone: "phone-1")
        let state = SymmetricKey(size: .bits256)
        let wrapped = try Pairing.wrap(state, with: pairingKey, phone: "phone-1")
        #expect(try Pairing.unwrap(wrapped, with: pairingKey, phone: "phone-1") == state)
        #expect(throws: Seal.Refused.self) { try Pairing.unwrap(wrapped, with: pairingKey, phone: "phone-2") }
    }
}
