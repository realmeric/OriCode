import ActivityKit
import Foundation
import Link

/// The Live Activity for what's running. It starts only with the app in front, since the system
/// refuses it behind, and follows whatever the phone reads after that: the whole store in front,
/// and behind, what a push wakes the app to fetch. Nothing else can reach it without a sender of
/// APNs pushes, so it carries a date past which it rests rather than says what may no longer hold.
/// What that means for how fresh it is: P-25's Notes in KANBAN-phone.md.
struct Island {
    /// How long what it shows is taken as true after the last word from the Mac.
    var fresh: TimeInterval = 300

    func show(_ state: IslandState?, front: Bool) async {
        let running = Activity<IslandAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        guard let state else {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: state, staleDate: .now + fresh)
        if let activity = running.first {
            await activity.update(content)
        } else if front, ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                _ = try Activity.request(attributes: IslandAttributes(), content: content)
            } catch {
                PhoneClient.logger.error("couldn't start the Island: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
