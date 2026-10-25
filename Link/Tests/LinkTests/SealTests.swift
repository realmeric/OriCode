import CryptoKit
import Foundation
import Testing
@testable import Link

struct SealTests {
    let key = SymmetricKey(size: .bits256)

    @Test func roundTrip() throws {
        let box = try Seal.seal(Data("Run swift test".utf8), key: key, type: "Ask", name: "A1")
        #expect(try Seal.open(box, key: key, type: "Ask", name: "A1") == Data("Run swift test".utf8))
    }

    @Test func boxMovedToAnotherRecordIsRefused() throws {
        let box = try Seal.seal(Data("Run swift test".utf8), key: key, type: "Ask", name: "A1")
        #expect(throws: Seal.Refused.self) { try Seal.open(box, key: key, type: "Ask", name: "A2") }
        #expect(throws: Seal.Refused.self) { try Seal.open(box, key: key, type: "Thread", name: "A1") }
        #expect(throws: Seal.Refused.self) { try Seal.open(box, key: SymmetricKey(size: .bits256), type: "Ask", name: "A1") }
    }
}
