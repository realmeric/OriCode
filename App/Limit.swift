import SwiftUI

/// Claude's plan limits as a thread meets them: a turn one of them refused says which, and when
/// it resets. The session limit resets within five hours, and a thread it stopped goes on by
/// itself then, the way the Claude Code app's does, unless Settings says not to; a weekly one
/// only says when, unless its card is told to wait for it.
enum Limit {
    /// Settings' "Go on when a limit resets", on unless turned off.
    static let goOnKey = "goOnWhenLimitResets"

    static var goesOn: Bool {
        UserDefaults.standard.object(forKey: goOnKey) as? Bool ?? true
    }

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

    /// What a window measures, as in "90% of the session used".
    static func span(of window: String?) -> String {
        switch window {
        case "five_hour": "the session"
        case "seven_day": "the week"
        case "seven_day_opus": "the Opus week"
        case "seven_day_sonnet": "the Sonnet week"
        default: "the limit"
        }
    }

    static func weekly(_ window: String?) -> Bool {
        window?.hasPrefix("seven_day") == true
    }

    /// "23:30" today, "Fri 23:30" later, in the Mac's own clock.
    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

/// A turn stopped at one of the plan's limits, before the thread's latest: what stopped it and
/// when that reset.
struct LimitLine: View {
    let resetsAt: Date
    let window: String?

    var body: some View {
        Text("Stopped at Claude's \(Limit.name(of: window)), which \(resetsAt > .now ? "resets" : "reset") at \(Limit.time(resetsAt)).")
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
    }
}

/// The thread's latest limit: the glass full, which limit, when it resets and how long that is,
/// and whether the thread goes on by itself then. Once the reset has passed it only says when.
struct LimitCard: View {
    @Environment(AppModel.self) private var model
    let resetsAt: Date
    let window: String?
    /// Whether the thread waits to go on when it resets.
    let resumes: Bool

    var body: some View {
        // Drawn again once, at the reset. The countdown in between is the system's to draw.
        TimelineView(.explicit([resetsAt])) { _ in
            let passed = resetsAt <= .now
            let when = Limit.weekly(window) ? resetsAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()) : Limit.time(resetsAt)
            HStack(spacing: 14) {
                GlassLevel(level: 1, side: 34)
                    .opacity(passed ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Limit.name(of: window).capitalizedFirst)
                        .font(Type.body.weight(.semibold))
                        .foregroundStyle(Ink.primary)
                    if passed {
                        Text("Reset at \(when)")
                    } else {
                        // An offset keeps two fields, "1 hour, 9 minutes", where a reference rounds to
                        // "in 1 hour"; to the minute, it changes once a minute.
                        Text("Resets at \(when) · in \(Text(.currentDate, format: .offset(to: resetsAt, allowedFields: [.day, .hour, .minute], sign: .never)))")
                    }
                }
                .font(Type.secondary)
                .foregroundStyle(Ink.secondary)
                Spacer(minLength: 12)
                if !passed {
                    Toggle("Go on when it resets", isOn: Binding(get: { resumes }, set: { model.goOn($0, at: resetsAt) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                }
            }
            .padding(14)
            .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Stopped at Claude's \(Limit.name(of: window))")
        }
    }
}

/// A limit getting close, said once each time its window fills: how much is gone, with only the
/// number in the band's colour, and how long the window had left when it was said.
struct NearLimitLine: View {
    let window: String
    let used: Double
    let resetsAt: Date
    let said: Date

    var body: some View {
        let left = resetsAt.timeIntervalSince(said)
        let resets = left < 86_400 ? "resets in \(ResetCopy.span(left))" : "resets \(Limit.time(resetsAt))"
        Text("\(Text("\(Int((used * 100).rounded()))%").foregroundStyle(Band.of(used).color)) of \(Limit.span(of: window)) used · \(resets)")
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
