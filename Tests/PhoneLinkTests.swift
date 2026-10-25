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
}
