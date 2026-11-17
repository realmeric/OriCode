import SwiftUI

/// An agent's plan usage as the engine reports it: one entry per metered window, each with when
/// it was read, since a thread's stream and the probe read different windows at different times.
struct PlanUsage: Codable, Sendable {
    struct Window: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let label: String
        /// A fraction; nil when the plan meters the window but didn't say how much is gone.
        let used: Double?
        let resetsAt: Date?
        /// When this reading was taken; nil in one kept by an earlier version.
        var at: Date?
    }

    /// A reset the account was granted, which the agent's own CLI spends on its limits.
    struct Reset: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let title: String?
        let expiresAt: Date?
    }

    let available: Bool
    let plan: String?
    private(set) var windows: [Window]
    /// Nil in one kept by an earlier version, which is none.
    private(set) var resets: [Reset]?

    /// Whether it tells anything: a login the plan's limits don't apply to is an answer, a plan
    /// that came back with no window at all isn't.
    var says: Bool { !available || !windows.isEmpty }

    /// What the ring means: the session window, as kullanym-notch shows it.
    var headline: Window? {
        windows.first { $0.id == "five_hour" } ?? windows.first
    }

    /// The soonest reset still to come, after which a reading of its window no longer holds.
    var nextReset: Date? {
        windows.compactMap(\.resetsAt).filter { $0 > .now }.min()
    }

    init(json: JSON) {
        available = json["available"]?.bool ?? false
        plan = json["plan"]?.string
        let at = json["at"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        windows = (json["windows"]?.array ?? []).map { window in
            Window(
                id: window["id"]?.string ?? "",
                label: window["label"]?.string ?? "",
                used: window["used"]?.double,
                resetsAt: window["resetsAt"]?.string.flatMap(Self.date),
                at: at)
        }
        resets = (json["resets"]?.array ?? []).compactMap { reset in
            reset["id"]?.string.map { Reset(id: $0, title: reset["title"]?.string, expiresAt: reset["expiresAt"]?.string.flatMap(Self.date)) }
        }
    }

    /// As it stands at `now`: a window whose reset has passed has nothing used since, as far as
    /// is known, and its next reset isn't known until it's read again.
    func current(at now: Date = .now) -> PlanUsage {
        var usage = self
        usage.windows = windows.map { window in
            guard let resetsAt = window.resetsAt, resetsAt <= now else { return window }
            return Window(id: window.id, label: window.label, used: window.used == nil ? nil : 0, resetsAt: nil, at: window.at)
        }
        return usage
    }

    /// A probe's answer over what was known: each window the newer of the two readings, so a
    /// probe the CLI answered from its own earlier fetch doesn't put back what a thread's turn has
    /// since moved past. A window it leaves out stays until its reset.
    func merged(over known: PlanUsage?, now: Date = .now) -> PlanUsage {
        guard let known, available else { return self }
        var usage = self
        usage.windows = windows.map { window in
            guard let old = known.windows.first(where: { $0.id == window.id }), let oldAt = old.at, let at = window.at, oldAt > at else { return window }
            return old
        }
        for old in known.windows where !windows.contains(where: { $0.id == old.id }) && old.resetsAt.map({ $0 > now }) == true {
            usage.windows.append(old)
        }
        return usage
    }

    /// A window as a thread's CLI just reported it, over the probe's older reading. Windows the
    /// probe doesn't name are left out, as it leaves them out, unless the report names them itself,
    /// as Codex's "30-day window" does. Claude's weekly window for the models extra usage covers
    /// is the one model's week the probe names, when it names one.
    mutating func take(_ id: String, label named: String? = nil, used: Double, resetsAt: Date?, at: Date = .now) {
        let names = ["five_hour": "Session", "seven_day": "Week", "seven_day_opus": "Opus week", "seven_day_sonnet": "Sonnet week"]
        var id = id
        if id == "seven_day_overage_included" {
            let scoped = windows.filter { $0.id.hasPrefix("model:") }
            guard scoped.count == 1 else { return }
            id = scoped[0].id
        }
        guard let label = windows.first(where: { $0.id == id })?.label ?? names[id] ?? named else { return }
        let window = Window(id: id, label: label, used: used, resetsAt: resetsAt, at: at)
        if let index = windows.firstIndex(where: { $0.id == id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
    }

    /// The resets left once one is used.
    mutating func spend(_ reset: String) {
        resets?.removeAll { $0.id == reset }
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

/// The usage card a reset was asked for from: its thread, the next one's agent when nil.
struct UsingReset {
    let thread: Chat?
}

extension AppModel {
    /// What the ring shows is the thread's own agent's, the open thread's when it's the open
    /// thread asking, or with no thread the next one's, as it stands now.
    func usage(for thread: Chat?) -> PlanUsage? {
        usages[providerID(for: thread)]?.current()
    }

    func usageAt(for thread: Chat?) -> Date? {
        usagesAt[providerID(for: thread)]
    }

    var usage: PlanUsage? {
        usage(for: chat)
    }

    /// A reading older than the engine's own minute and a little, which the card dates and the
    /// ring dims. One kept from the last launch is that, until a hover asks again.
    func usageStale(for thread: Chat?) -> Bool {
        usageAt(for: thread).map { Date.now.timeIntervalSince($0) > 120 } ?? false
    }

    func usageLoading(for thread: Chat?) -> Bool {
        loadingUsage.contains(providerID(for: thread))
    }

    func refreshUsage() {
        refreshUsage(for: chat)
    }

    /// Asks the engine for the whole picture, which it keeps a minute. Only the pointer arriving
    /// asks: nothing here polls, and no key does. A thread's stream doesn't count as an ask, since
    /// it brings only some windows, and a reset passed since the last ask makes it old.
    func refreshUsage(for thread: Chat?) {
        let agent = providerID(for: thread)
        guard engineState == .ready, !loadingUsage.contains(agent), agentReady(for: thread), provider(for: thread)?.capabilities.usage == true else { return }
        if let asked = usagesAsked[agent], Date.now.timeIntervalSince(asked) < 60,
           usages[agent]?.windows.contains(where: { $0.resetsAt.map { $0 > asked && $0 <= .now } ?? false }) != true { return }
        loadingUsage.insert(agent)
        Task {
            defer { loadingUsage.remove(agent) }
            guard let reply = try? await engine.request("usage", .object([String: JSON]().naming(agent))) else { return }
            usagesAsked[agent] = .now
            takeUsage(reply, for: agent)
        }
    }

    /// The engine's answer, over what was known. One with no window says nothing, so what was
    /// known stays, dated as it was.
    func takeUsage(_ reply: JSON, for agent: String) {
        let taken = PlanUsage(json: reply)
        guard taken.says else { return }
        let usage = taken.merged(over: usages[agent])
        usages[agent] = usage
        usagesAt[agent] = usage.windows.compactMap(\.at).max() ?? .now
        keepUsages()
        goOnEarly(agent)
    }

    /// A thread's CLI reporting the plan's limits as its turn goes, which keeps the glass current
    /// without spawning a probe. Its readings are fractions already, as the probe's are once the
    /// engine has divided them.
    func takeLimits(_ body: JSON, for agent: String) {
        var readings = (body["windows"]?.array ?? []).compactMap { window -> (String, String?, Double, Date?)? in
            guard let id = window["id"]?.string, let used = window["used"]?.double else { return nil }
            return (id, window["label"]?.string, used, window["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        // The limit the CLI names, when it didn't send each window's reading.
        if let id = body["rateLimitType"]?.string, let used = body["utilization"]?.double, !readings.contains(where: { $0.0 == id }) {
            readings.append((id, nil, used, body["resetsAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) }))
        }
        guard !readings.isEmpty else { return }
        var taken = usages[agent] ?? PlanUsage(json: ["available": true])
        for (id, label, used, resetsAt) in readings { taken.take(id, label: label, used: used, resetsAt: resetsAt) }
        usages[agent] = taken
        usagesAt[agent] = .now
        keepUsages()
        goOnEarly(agent)
    }

    /// Spends one of the account's resets through the agent's own CLI, then asks for the limits
    /// again, which it has made old. A reset that went through is gone from the card at once.
    func useReset(_ reset: PlanUsage.Reset, for thread: Chat?) {
        let agent = providerID(for: thread)
        let attempt = UUID().uuidString
        Task {
            let reply = try? await engine.request("usage.reset", .object(["reset": .string(reset.id), "attempt": .string(attempt)].naming(agent)))
            let outcome = reply?["outcome"]?.string
            switch outcome {
            case "reset", "alreadyRedeemed":
                usages[agent]?.spend(reset.id)
                goOnEarly(agent, used: true)
            case "nothingToReset":
                resetRefused = "Nothing to reset yet."
            case "noCredit":
                usages[agent]?.spend(reset.id)
                resetRefused = "That reset has been used."
            default:
                resetRefused = "Couldn't use the reset."
            }
            usagesAsked[agent] = nil
            keepUsages()
            refreshUsage(for: thread)
        }
    }

    static let usageKey = "planUsages"

    private struct KeptUsage: Codable {
        let usage: PlanUsage
        let at: Date
    }

    static func keptUsages(in defaults: UserDefaults?) -> ([String: PlanUsage], [String: Date]) {
        guard let data = defaults?.data(forKey: usageKey), let kept = try? JSONDecoder().decode([String: KeptUsage].self, from: data) else { return ([:], [:]) }
        return (kept.mapValues(\.usage), kept.mapValues(\.at))
    }

    func keepUsages() {
        let kept = usages.compactMap { agent, usage in usagesAt[agent].map { (agent, KeptUsage(usage: usage, at: $0)) } }
        usageKept?.set(try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: kept)), forKey: Self.usageKey)
    }
}
