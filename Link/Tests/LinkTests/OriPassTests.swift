import CryptoKit
import Foundation
import Testing
@testable import Link

/// OriPass's bytes, held to its card OP-88 and to the vector its own tests hold.
struct OriPassTests {
    /// The request on OP-88's card.
    nonisolated(unsafe) static let line: [String: Any] = [
        "v": 1, "type": "request", "id": "6f1d2c3a-0b7e-4f10-9a55-3e1c7a2b9d04", "nonce": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        "act": "stranger",
        "words": "OriCode wants to use an SSH key\nKey: Sunucu anahtarı\nGoing to: buzul\nHost key: SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem\nAsked by: ssh › zsh › claude › OriCode",
        "app": "OriCode", "appID": "com.realmeric.oricode", "key": "Sunucu anahtarı", "keyFingerprint": "SHA256:KeyDemoKeyDemoKeyDemoKeyDemoKeyDemoKeyDemoK",
        "host": "buzul", "hostKey": "SHA256:DemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDem", "expires": "2026-11-02T21:03:00Z",
    ]

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func theMessageIsTheCardsTo() throws {
        let request = try #require(PassRequest(line: Self.line))
        #expect(request.nonce == Data(0..<32))
        #expect(hex(request.wordsHash) == "e50a7383763f73c21489aa4985b93bc6abacc8bd28e6f3f5240b04eb92c920c8")
        #expect(request.message.count == 127)
        #expect(hex(request.message) == "6f7269706173732e617070726f76652e7631000000002436663164326333612d30623765"
            + "2d346631302d396135352d3365316337613262396430340000002000010203040506"
            + "0708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1fe50a7383763f73c21489"
            + "aa4985b93bc6abacc8bd28e6f3f5240b04eb92c920c8")
    }

    @Test func aRequestOutlivesTheTripThroughICloud() throws {
        let request = try #require(PassRequest(line: Self.line))
        let ask = PassAsk(id: request.id, want: .approve(request), asked: .now)
        let key = SymmetricKey(size: .bits256)
        let box = try Seal.seal(ask, key: key, type: "Ask", name: RecordName.pass(request.id))
        let back = try Seal.open(PassAsk.self, from: box, key: key, type: "Ask", name: RecordName.pass(request.id))
        #expect(back.request?.message == request.message)
    }

    @Test func aSignatureByThePhonesKeyVerifiesOverOriPasssOwnCopy() throws {
        let request = try #require(PassRequest(line: Self.line))
        let phone = P256.Signing.PrivateKey()
        let signature = try phone.signature(for: request.message).derRepresentation
        let verified = try P256.Signing.ECDSASignature(derRepresentation: signature)
        #expect(phone.publicKey.isValidSignature(verified, for: request.message))
        var altered = request
        altered.words += " "
        #expect(!phone.publicKey.isValidSignature(verified, for: altered.message))
    }

    @Test func aLineMissingAFieldIsNoRequest() {
        var line = Self.line
        line["hostKey"] = nil
        #expect(PassRequest(line: line) == nil)
        line = Self.line
        line["nonce"] = Data(count: 16).base64EncodedString()
        #expect(PassRequest(line: line) == nil)
    }

    @Test func itsExpiryIsOriPasssClock() throws {
        let request = try #require(PassRequest(line: Self.line))
        #expect(request.expiry == Date(timeIntervalSince1970: 1_793_653_380))
        #expect(!request.expired(now: Date(timeIntervalSince1970: 1_793_653_379)))
        #expect(request.expired(now: Date(timeIntervalSince1970: 1_793_653_380)))
        var unreadable = request
        unreadable.expires = "soon"
        #expect(unreadable.expired(now: .distantPast))
    }

    @Test func theFirstLineSaysWhatItIsAndTheRestStaysAsSent() throws {
        let request = try #require(PassRequest(line: Self.line))
        #expect(request.statement == "OriCode wants to use an SSH key")
        #expect(request.statement + "\n" + request.particulars == request.words)
        let nudge = NudgeInfo(kind: .pass, title: "OriPass", body: request.words, thread: NudgeInfo.noThread, ask: request.id, options: [])
        #expect(nudge.subtitle == request.statement)
    }

    @Test func aFingerprintIsEightBytesInFours() {
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let fingerprint = PassWire.fingerprint(of: key)
        #expect(fingerprint.replacingOccurrences(of: "-", with: "") == SHA256.hash(data: key).prefix(8).map { String(format: "%02X", $0) }.joined())
        #expect(fingerprint.split(separator: "-").map(\.count) == [4, 4, 4, 4])
    }

    @Test func aRegistrationIsTheNameAndTheKeyCounted() {
        let key = Data(repeating: 4, count: 65)
        let bytes = PassWire.registration(name: "iPhone", publicKey: key)
        let written: [UInt8] = Array("oripass.register.v1".utf8) + [0, 0, 0, 0, 6] + Array("iPhone".utf8) + [0, 0, 0, 65]
        #expect(bytes == Data(written) + key)
    }

    @Test func theCommandsComeBackAsTheyWent() throws {
        for action in [Command.Action.approve(request: "r", signature: Data([1, 2])), .deny(request: "r"),
                       .register(ask: "a", name: "iPhone", publicKey: Data([4]), proof: Data([5]))] {
            let back = try JSONDecoder().decode(Command.self, from: JSONEncoder().encode(Command(action)))
            #expect(back.action == action)
        }
    }

    @Test func aPassIsNamedApartFromAnAgentsAsk() {
        #expect(RecordName.isPass(RecordName.pass("6f1d")))
        #expect(!RecordName.isPass(RecordName.ask("6f1d")))
        #expect(RecordName.id(in: RecordName.pass("6f1d")) == "6f1d")
    }
}
