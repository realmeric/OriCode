import CloudKit
import Foundation

/// One Mac's zone in the private database, read and written directly: its changes since a token,
/// records saved over whatever copy is there, and the subscription whose silent push says the
/// other side wrote. CKSyncEngine was the first way, but it fetches only what a push told it of
/// and finishes an asked-for fetch without asking the server, so a fetch when the app comes to the
/// front, or while an answer is awaited, did nothing when a push was late; here a fetch asks.
@MainActor
public final class ZoneSync {
    public struct Changes: Sendable {
        public var changed: [CKRecord] = []
        public var deleted: [(id: CKRecord.ID, type: String)] = []
    }

    public enum Gone: Error {
        /// The zone isn't there: deleted by the Mac, or in another account's database.
        case zone
    }

    public let zone: CKRecordZone.ID
    private let database: CKDatabase
    public private(set) var token: CKServerChangeToken?
    /// Kept for the log of what rule 6 costs.
    public private(set) var requests = 0

    public init(zone: CKRecordZone.ID, token: Data? = nil) {
        self.zone = zone
        database = CKContainer(identifier: Container.identifier).privateCloudDatabase
        self.token = token.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    }

    public var tokenData: Data? {
        token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
    }

    public func forgetToken() {
        token = nil
    }

    public func makeZone() async throws {
        requests += 1
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zone)], deleting: [])
    }

    public func deleteZone() async throws {
        requests += 1
        _ = try await database.modifyRecordZones(saving: [], deleting: [zone])
    }

    /// Everything changed since the last fetch, every page of it.
    public func fetch() async throws -> Changes {
        var changes = Changes()
        var more = true
        while more {
            requests += 1
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                throw Gone.zone
            } catch let error as CKError where error.code == .changeTokenExpired {
                token = nil
                continue
            }
            for result in page.modificationResultsByID.values {
                if case .success(let modification) = result { changes.changed.append(modification.record) }
            }
            changes.deleted += page.deletions.map { ($0.recordID, $0.recordType) }
            token = page.changeToken
            more = page.moreComing
        }
        return changes
    }

    /// Saved over whatever copy is there, `changedKeys` writing only the fields set here, and
    /// deleted, in batches CloudKit takes. Returns what failed, by record.
    @discardableResult
    public func write(saving: [CKRecord], deleting: [CKRecord.ID], changedKeys: Bool = false) async throws -> [CKRecord.ID: any Error] {
        var failed: [CKRecord.ID: any Error] = [:]
        var saving = saving[...]
        var deleting = deleting[...]
        while !saving.isEmpty || !deleting.isEmpty {
            let saves = Array(saving.prefix(200))
            saving = saving.dropFirst(saves.count)
            let deletes = Array(deleting.prefix(200 - saves.count))
            deleting = deleting.dropFirst(deletes.count)
            requests += 1
            do {
                let result = try await database.modifyRecords(saving: saves, deleting: deletes, savePolicy: changedKeys ? .changedKeys : .allKeys, atomically: false)
                for (id, outcome) in result.saveResults { if case .failure(let error) = outcome { failed[id] = error } }
                for (id, outcome) in result.deleteResults {
                    if case .failure(let error) = outcome, (error as? CKError)?.code != .unknownItem { failed[id] = error }
                }
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                throw Gone.zone
            }
        }
        return failed
    }

    /// The silent push that says the zone changed, sent to every device but the one that wrote. The
    /// Mac's has an id of its own: saved under the phone's, the phone's save replaced it, and the
    /// Mac never heard a push (2026-10-26).
    public func subscribe(mac: Bool = false) async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zone, subscriptionID: mac ? Self.macSubscriptionID(zone) : Self.subscriptionID(zone))
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        requests += 1
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    /// The one visible push: a Nudge made in the zone. Its words are CloudKit's fallback, "Waiting
    /// on you"; the phone's notification extension opens the Nudge and writes the real ones.
    public func subscribeToNudges() async throws {
        let subscription = CKQuerySubscription(recordType: RecordType.nudge, predicate: NSPredicate(value: true),
                                               subscriptionID: "nudges-\(zone.zoneName)", options: [.firesOnRecordCreation])
        subscription.zoneID = zone
        let info = CKSubscription.NotificationInfo()
        info.alertBody = "Waiting on you"
        info.soundName = "default"
        info.shouldSendMutableContent = true
        subscription.notificationInfo = info
        requests += 1
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    public func save(subscription: CKSubscription) async throws {
        requests += 1
        _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
    }

    public func record(_ id: CKRecord.ID) async throws -> CKRecord {
        requests += 1
        return try await database.record(for: id)
    }

    public nonisolated static func subscriptionID(_ zone: CKRecordZone.ID) -> String {
        "changes-\(zone.zoneName)"
    }

    public nonisolated static func macSubscriptionID(_ zone: CKRecordZone.ID) -> String {
        "mac-changes-\(zone.zoneName)"
    }

    /// Whether a push is one of this zone's, by the zone's name: a push names the zone's owner by
    /// the account's record name where the link holds CKCurrentUserDefaultName, so comparing whole
    /// ids turned every push away and each side waited on its timed read (2026-10-26).
    public nonisolated static func isPush(_ userInfo: [AnyHashable: Any], for zone: CKRecordZone.ID) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        if let zoneNotification = notification as? CKRecordZoneNotification { return zoneNotification.recordZoneID?.zoneName == zone.zoneName }
        if let query = notification as? CKQueryNotification { return query.recordID?.zoneID.zoneName == zone.zoneName }
        return notification.subscriptionID == subscriptionID(zone) || notification.subscriptionID == macSubscriptionID(zone)
    }
}
