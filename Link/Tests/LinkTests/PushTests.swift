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

    func nudge(zone name: String, record: String) -> [AnyHashable: Any] {
        ["aps": ["alert": ["body": "Waiting on you"], "mutable-content": 1],
         "ck": ["ce": 2, "cid": Container.identifier, "ckuserid": "_0123abcd", "nid": UUID().uuidString,
                "qry": ["af": [:] as [String: Any], "dbs": 1, "fo": 1, "rid": record, "sid": "nudges-\(name)", "zid": name, "zoid": "_0123abcd"]]]
    }

    /// The push's zone isn't the phone's by whole id, which is why no Nudge was ever opened, and
    /// the id handed on is in the zone the phone holds.
    @Test func aNudgesPushNamesItsRecordInTheZoneThePhoneHolds() throws {
        let info = nudge(zone: zone.zoneName, record: "nudge-ask-1")
        let query = try #require(CKNotification(fromRemoteNotificationDictionary: info) as? CKQueryNotification)
        #expect(query.recordID?.zoneID != zone)
        let id = try #require(ZoneSync.nudge(in: info, for: zone))
        #expect(id.recordName == "nudge-ask-1")
        #expect(id.zoneID == zone)
    }

    @Test func anotherZonesNudgeIsNot() {
        #expect(ZoneSync.nudge(in: nudge(zone: Zone.id(mac: UUID()).zoneName, record: "nudge-ask-1"), for: zone) == nil)
        #expect(ZoneSync.nudge(in: push(zone: zone.zoneName, subscription: ZoneSync.subscriptionID(zone)), for: zone) == nil)
    }
}
