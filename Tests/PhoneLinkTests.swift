import CloudKit
import Link
import XCTest
@testable import OriCode

@MainActor
final class PhoneLinkTests: XCTestCase {
    func testACommandIsTakenOnceAndOnlyWhileFresh() {
        let now = Date.now
        XCTAssertNil(PhoneLink.refusal(seen: false, made: now.addingTimeInterval(-30), now: now))
        XCTAssertEqual(PhoneLink.refusal(seen: true, made: now.addingTimeInterval(-30), now: now), "Sent before")
        // Saved while the Mac slept eleven minutes.
        XCTAssertEqual(PhoneLink.refusal(seen: false, made: now.addingTimeInterval(-660), now: now), "Too late")
    }

    func testANonceIsRememberedOnceSeen() {
        let nonce = UUID()
        XCTAssertFalse(PhoneLink.seen(nonce))
        PhoneLink.remember(nonce)
        XCTAssertTrue(PhoneLink.seen(nonce))
    }

    /// A paired phone and nothing waiting on it: the Mac looks only while Meriç is at the window,
    /// and never once pushes come, so the installed app doesn't wake itself all day (K-384).
    func testAPairedPhoneIdleLooksOnlyAtTheWindow() {
        typealias Poll = PhoneLink.Poll
        XCTAssertEqual(PhoneLink.pollEvery(Poll()), .seconds(20))
        XCTAssertEqual(PhoneLink.pollEvery(Poll(working: true)), .seconds(15))
        XCTAssertNil(PhoneLink.pollEvery(Poll(locked: true)))
        XCTAssertNil(PhoneLink.pollEvery(Poll(shown: false)))
        XCTAssertNil(PhoneLink.pollEvery(Poll(working: true, shown: false)))
        XCTAssertNil(PhoneLink.pollEvery(Poll(asleep: true)))
        XCTAssertNil(PhoneLink.pollEvery(Poll(pushesCome: true)))
        XCTAssertNil(PhoneLink.pollEvery(Poll(working: true, pushesCome: true)))
    }

    /// While the phone is in use the Mac looks whatever the screen, since that is when Meriç is
    /// away answering from it, and once a minute when pushes come.
    func testThePhoneInUseIsLookedForAway() {
        typealias Poll = PhoneLink.Poll
        XCTAssertEqual(PhoneLink.pollEvery(Poll(asking: true, locked: true)), .seconds(5))
        XCTAssertEqual(PhoneLink.pollEvery(Poll(watched: true, shown: false)), .seconds(5))
        XCTAssertEqual(PhoneLink.pollEvery(Poll(nudged: true, locked: true)), .seconds(15))
        XCTAssertEqual(PhoneLink.pollEvery(Poll(asking: true, pushesCome: true)), .seconds(60))
        XCTAssertEqual(PhoneLink.pollEvery(Poll(nudged: true, pushesCome: true, locked: true)), .seconds(60))
        XCTAssertNil(PhoneLink.pollEvery(Poll(asking: true, asleep: true)))
    }

    /// What the phone writes says a push was missed when a look finds it; the Mac's answer doesn't.
    func testWhatThePhoneWroteIsTold() {
        let zone = CKRecordZone.ID(zoneName: "z")
        let command = CKRecord(recordType: RecordType.command, recordID: .init(recordName: "c", zoneID: zone))
        XCTAssertTrue(PhoneLink.phoneWrote(command))
        command.encryptedValues[Field.outcome] = Data([1])
        XCTAssertFalse(PhoneLink.phoneWrote(command))
        XCTAssertTrue(PhoneLink.phoneWrote(CKRecord(recordType: RecordType.phone, recordID: .init(recordName: "p", zoneID: zone))))
        XCTAssertFalse(PhoneLink.phoneWrote(CKRecord(recordType: RecordType.mac, recordID: .init(recordName: "m", zoneID: zone))))
    }
}
