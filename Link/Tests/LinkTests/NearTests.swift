import CryptoKit
import Foundation
import Testing
@testable import Link

/// The Mac and a phone on this Mac's network: found by Bonjour, proven, and each told when the
/// other wrote; a phone with the wrong key is told nothing.
@MainActor
@Suite(.serialized)
struct NearTests {
    let paired = Paired(mac: UUID(), phone: "phone-1", privateKey: Data(), pairingKey: SymmetricKey(size: .bits256).data, stateKey: Data())

    @Test func eachSideHearsTheOther() async throws {
        var macHeard = 0
        var phoneHeard = 0
        let key = paired.pairing
        let host = NearHost(mac: paired.mac, key: { $0 == "phone-1" ? key : nil }) { macHeard += 1 }
        let client = NearClient(paired: paired) { phoneHeard += 1 }
        host.start()
        client.start()
        defer {
            client.stop()
            host.stop()
        }
        try await until { client.tell(); return macHeard > 0 }
        try await until { host.tell(); return phoneHeard > 0 }
    }

    @Test func aPhoneWithAnotherKeyHearsNothing() async throws {
        var phoneHeard = 0
        let host = NearHost(mac: paired.mac, key: { _ in SymmetricKey(size: .bits256) }) {}
        let client = NearClient(paired: paired) { phoneHeard += 1 }
        host.start()
        client.start()
        defer {
            client.stop()
            host.stop()
        }
        for _ in 0..<30 {
            host.tell()
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(phoneHeard == 0)
    }

    private func until(_ check: () -> Bool) async throws {
        for _ in 0..<100 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("never heard")
    }
}
