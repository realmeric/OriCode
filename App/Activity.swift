import Charts
import SwiftData
import SwiftUI

/// The tokens that went through OriCode's threads, by day, from the turns the app has stored.
enum TokenActivity {
    /// A stored turn's tokens: what was read, cached or not, and what was written.
    static func tokens(in payload: Data) -> Int {
        guard let usage = (try? JSONDecoder().decode(JSON.self, from: payload))?["usage"] else { return 0 }
        return ["input", "output", "cacheRead", "cacheWrite"].reduce(0) { $0 + (usage[$1]?.int ?? 0) }
    }

    /// Each day's total, by the day's first moment in `calendar`.
    static func days(_ turns: [(at: Date, tokens: Int)], calendar: Calendar = .current) -> [Date: Int] {
        var days: [Date: Int] = [:]
        for turn in turns where turn.tokens > 0 {
            days[calendar.startOfDay(for: turn.at), default: 0] += turn.tokens
        }
        return days
    }

    /// Every day from `weeks` weeks back to today, the quiet ones too, oldest first, starting on
    /// the first day of a week.
    static func span(_ days: [Date: Int], weeks: Int, until today: Date = .now, calendar: Calendar = .current) -> [Day] {
        let end = calendar.startOfDay(for: today)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: end)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) else { return [] }
        var all: [Day] = []
        var day = start
        var running = 0
        while day <= end {
            let tokens = days[day] ?? 0
            running += tokens
            all.append(Day(day: day, week: calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day,
                           weekday: (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7, tokens: tokens, total: running))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return all
    }

    struct Day: Identifiable, Equatable {
        let day: Date
        let week: Date
        /// 0 for the week's first day.
        let weekday: Int
        let tokens: Int
        /// Everything up to and including this day, within the span.
        let total: Int

        var id: Date { day }
    }

    /// "108.4M", "12.3K", "640".
    static func short(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000_000...: String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...: String(format: "%.1fK", Double(tokens) / 1_000)
        default: "\(tokens)"
        }
    }
}

extension AppModel {
    /// Every stored turn's day and tokens, read once when Settings › Activity opens.
    func storedTurns() -> [(at: Date, tokens: Int)] {
        let ended = FetchDescriptor<Event>(predicate: #Predicate { $0.kind == "turn.done" })
        return ((try? context.fetch(ended)) ?? []).map { ($0.createdAt, TokenActivity.tokens(in: $0.payload)) }
    }
}

/// Settings › Activity: half a year of days shaded by the tokens that went through, the same by
/// week, or adding up, in the glass's own white. Drawn by Swift Charts.
struct ActivityPane: View {
    @Environment(AppModel.self) private var model
    @State private var days: [TokenActivity.Day] = []
    @State private var recorded = 0
    @AppStorage("activityView") private var view = "daily"

    private static let weeks = 26

    var body: some View {
        PaneTitle(text: "Activity")
        HStack(alignment: .firstTextBaseline) {
            Text(recorded == 0 ? "No tokens recorded yet" : "\(TokenActivity.short(recorded)) tokens recorded")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ink.secondary)
            Spacer()
            Picker("View", selection: $view) {
                Text("Daily").tag("daily")
                Text("Weekly").tag("weekly")
                Text("Cumulative").tag("cumulative")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.top, 22)
        .padding(.bottom, 10)
        VStack(alignment: .leading, spacing: 0) {
            chart
                .frame(height: view == "daily" ? 150 : 220)
                .padding(18)
        }
        .background(Surface.card, in: .rect(cornerRadius: 16, style: .continuous))
        Text("What OriCode's own threads read and wrote, cached tokens included, on every agent that reports them, over the last \(Self.weeks) weeks. Turns run in a terminal aren't counted.")
            .font(Type.secondary)
            .foregroundStyle(Ink.faint)
            .padding(.top, 10)
            .task {
                let turns = model.storedTurns()
                recorded = turns.reduce(0) { $0 + $1.tokens }
                days = TokenActivity.span(TokenActivity.days(turns), weeks: Self.weeks)
            }
    }

    @ViewBuilder
    private var chart: some View {
        let most = max(days.map(\.tokens).max() ?? 0, 1)
        switch view {
        case "weekly":
            Chart(weekly) { week in
                BarMark(x: .value("Week", week.week, unit: .weekOfYear), y: .value("Tokens", week.tokens))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .cornerRadius(3)
            }
            .quiet()
        case "cumulative":
            Chart(days) { day in
                AreaMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.total))
                    .foregroundStyle(Color.white.opacity(0.10))
                LineMark(x: .value("Day", day.day, unit: .day), y: .value("Tokens", day.total))
                    .foregroundStyle(Color.white.opacity(0.8))
            }
            .quiet()
        default:
            Chart(days) { day in
                // Weekdays as a band scale, a row each; a number's axis gave a mark no height.
                RectangleMark(x: .value("Week", day.week, unit: .weekOfYear), y: .value("Day", String(day.weekday)), width: .ratio(0.82), height: .ratio(0.82))
                    // A quiet day is the card's own tint; the busiest is nearly white.
                    .foregroundStyle(Color.white.opacity(day.tokens == 0 ? 0.05 : 0.14 + 0.76 * (Double(day.tokens) / Double(most)).squareRoot()))
                    .cornerRadius(3)
            }
            .chartYScale(domain: (0..<7).map(String.init))
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Ink.faint)
                }
            }
        }
    }

    private var weekly: [TokenActivity.Day] {
        Dictionary(grouping: days, by: \.week).map { week, days in
            TokenActivity.Day(day: week, week: week, weekday: 0, tokens: days.reduce(0) { $0 + $1.tokens }, total: days.last?.total ?? 0)
        }
        .sorted { $0.week < $1.week }
    }
}

private extension View {
    /// Axes in the glass's faint ink, months along the bottom and round token counts up the side.
    func quiet() -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated)).foregroundStyle(Ink.faint)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let tokens = value.as(Int.self) { Text(TokenActivity.short(tokens)).foregroundStyle(Ink.faint) }
                }
            }
        }
    }
}
