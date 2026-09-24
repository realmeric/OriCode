import SwiftUI

/// Claude plan usage as the engine reports it: one entry per metered window.
struct PlanUsage: Sendable {
    struct Window: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        /// A fraction; nil when the plan meters the window but didn't say how much is gone.
        let used: Double?
        let resetsAt: Date?
    }

    let available: Bool
    let plan: String?
    let windows: [Window]

    /// What the ring means: the session window, as kullanym-notch shows it.
    var headline: Window? {
        windows.first { $0.id == "five_hour" } ?? windows.first
    }

    init(json: JSON) {
        available = json["available"]?.bool ?? false
        plan = json["plan"]?.string
        windows = (json["windows"]?.array ?? []).map { window in
            Window(
                id: window["id"]?.string ?? "",
                label: window["label"]?.string ?? "",
                used: window["used"]?.double,
                resetsAt: window["resetsAt"]?.string.flatMap(Self.date))
        }
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// kullanym-notch's bands: how close a window is to its ceiling. Only a near one takes a colour;
/// with room left it's the app's white, since there's nothing to tell.
enum Band {
    case ample, watch, critical

    static func of(_ used: Double) -> Band {
        switch used {
        case ..<0.5: .ample
        case ..<0.7: .watch
        default: .critical
        }
    }

    var color: Color {
        switch self {
        case .ample: Ink.secondary
        case .watch: Color(red: 0xFA / 255, green: 0xCC / 255, blue: 0x15 / 255)
        case .critical: Color(red: 0xFB / 255, green: 0x5A / 255, blue: 0x2C / 255)
        }
    }
}

/// When a window rolls over, in kullanym-notch's wording: minutes and hours while it's
/// close, a weekday and time within the week, a date past that.
enum ResetCopy {
    static func text(for resetsAt: Date, now: Date = .now) -> String {
        let seconds = resetsAt.timeIntervalSince(now)
        if seconds <= 0 { return "Resetting…" }
        if seconds < 86_400 { return "Resets in \(span(seconds))" }
        let formatter = DateFormatter()
        if seconds >= 7 * 86_400 {
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
        } else {
            // A literal pattern, so the separator stays a colon in every region.
            formatter.dateFormat = "E h:mm a"
        }
        return "Resets \(formatter.string(from: resetsAt))"
    }

    static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

extension AppModel {
    /// Asks the engine, which keeps an answer a minute; `fresh` after a turn, when it moved.
    func refreshUsage(fresh: Bool = false) {
        guard engineState == .ready, !usageLoading else { return }
        if !fresh, let usageAt, Date.now.timeIntervalSince(usageAt) < 60 { return }
        usageLoading = true
        Task {
            defer { usageLoading = false }
            do {
                let reply = try await engine.request("usage", ["fresh": .bool(fresh)])
                usage = PlanUsage(json: reply)
                usageAt = .now
                usageStale = false
            } catch {
                usageStale = usage != nil
            }
        }
    }
}
