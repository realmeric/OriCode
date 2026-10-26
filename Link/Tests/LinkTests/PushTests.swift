import CloudKit
import Foundation
import Testing
@testable import Link

/// A zone's push names its owner by the account's record name, never by CKCurrentUserDefaultName,
/// and is still the zone's.
struct PushTests {
    let zone = Zone.id(mac: UUID())

    func push(zone name: String, subscription: String) -> [AnyHashable: Any] {
        ["aps": ["content-available": 1],
         "ck": ["ce": 2, "cid": Container.identifier, "ckuserid": "_0123abcd", "nid": UUID().uuidString,
                "fet": ["dbs": 1, "sid": subscription, "zid": name, "zoid": "_0123abcd"]]]
    }

    @Test func aPushNamingTheOwnerIsTheZones() {
        let info = push(zone: zone.zoneName, subscription: ZoneSync.macSubscriptionID(zone))
        #expect(CKNotification(fromRemoteNotificationDictionary: info) is CKRecordZoneNotification)
        #expect(ZoneSync.isPush(info, for: zone))
    }

    @Test func anotherZonesPushIsNot() {
        let other = Zone.id(mac: UUID())
        #expect(!ZoneSync.isPush(push(zone: other.zoneName, subscription: ZoneSync.subscriptionID(other)), for: zone))
    }
}
