import SwiftUI

/// Claude's plan limits as a thread meets them: a turn one of them refused says which, and when
/// it resets. The session limit resets within five hours, and a thread it stopped goes on by
/// itself then, the way the Claude Code app's does; a weekly one only says when.
enum Limit {
    static func resumes(window: String?, resetsAt: Date) -> Bool {
        window == "five_hour" || window == nil && resetsAt.timeIntervalSinceNow < 6 * 3600
    }

    static func name(of window: String?) -> String {
        switch window {
        case "five_hour": "session limit"
        case "seven_day": "weekly limit"
        case "seven_day_opus": "weekly Opus limit"
        case "seven_day_sonnet": "weekly Sonnet limit"
        default: "usage limit"
        }
    }

    /// "23:30" today, "Fri 23:30" later, in the Mac's own clock.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A turn stopped at one of the plan's limits. While the thread waits to go on when it resets,
/// the line says so and can call it off.
struct LimitLine: View {
    @Environment(AppModel.self) private var model
    let resetsAt: Date
    let window: String?
    /// When this is the limit the thread is waiting out.
    let pending: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(pending
                ? "Stopped at Claude's \(Limit.name(of: window)). This thread goes on when it resets at \(Limit.time(resetsAt))."
                : "Stopped at Claude's \(Limit.name(of: window)), which \(resetsAt > .now ? "resets" : "reset") at \(Limit.time(resetsAt)).")
            if pending {
                Button("Cancel") { model.cancelResume() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Ink.primary)
                    .help("Don't go on by itself when the limit resets")
            }
        }
        .font(Type.secondary)
        .foregroundStyle(Ink.secondary)
    }
}
