import Foundation

/// What the Island and the Lock Screen show: what waits on Meriç first, then the threads at work.
/// It's a Live Activity's content, which can't pass 4 KB with its attributes, so what's written
/// here is cut to fit.
public struct IslandState: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable, Identifiable {
        /// The thread.
        public var id: UUID
        public var project: ProjectInfo?
        public var title: String
        /// What it's on, or for one that waits, what it asks.
        public var step: String?
        public var asking: Bool
    }

    /// More than the Island or the Lock Screen has room for.
    static let rowsKept = 4
    static let lineKept = 48

    public var rows: [Row]
    /// Threads at work, the asking ones among them.
    public var working: Int
    public var asks: Int
    /// The mark's lit rays, by where they stand, each with the agent that holds it.
    public var rays: [Int: String]

    /// Nil when nothing is at work and nothing waits, and when the Mac has gone, since what it
    /// last said of its threads no longer holds.
    public init?(mac: MacInfo?, projects: [UUID: ProjectInfo], threads: [UUID: ThreadInfo], asks: [String: AskInfo]) {
        guard (mac?.state ?? .awake) == .awake else { return nil }
        let working = threads.values.filter { $0.status == .working || $0.status == .asking }
            .sorted { ($0.updated, $0.id.uuidString) > ($1.updated, $1.id.uuidString) }
        guard !working.isEmpty || !asks.isEmpty else { return nil }
        let waiting = asks.values.sorted { ($0.asked, $0.id) < ($1.asked, $1.id) }
        var asked: Set<UUID> = []
        var rows: [Row] = []
        for ask in waiting where asked.insert(ask.thread).inserted {
            guard let thread = threads[ask.thread] else { continue }
            rows.append(Row(id: thread.id, project: projects[thread.project], title: Self.cut(thread.title), step: Self.cut(ask.line), asking: true))
        }
        for thread in working where !asked.contains(thread.id) {
            rows.append(Row(id: thread.id, project: projects[thread.project], title: Self.cut(thread.title), step: thread.step.map(Self.cut), asking: false))
        }
        self.rows = Array(rows.prefix(Self.rowsKept))
        self.working = working.count
        self.asks = asks.count
        let agents = working.flatMap { thread in
            thread.rays.isEmpty ? [thread.agent] : thread.rays.sorted { $0.key < $1.key }.map(\.value)
        }
        rays = Dictionary(uniqueKeysWithValues: agents.prefix(6).enumerated().map { ($0.offset, $0.element) })
    }

    private static func cut(_ line: String) -> String {
        String(line.prefix(lineKept))
    }

    /// Where a tap on the Island lands: the first thread that waits, else home.
    public var link: URL {
        rows.first(where: \.asking).map { IslandLink.thread($0.id) } ?? IslandLink.home
    }
}

/// oricode://thread/<uuid> and oricode://home, the app's links from its Live Activity.
public enum IslandLink {
    public static let scheme = "oricode"
    public static let home = URL(string: "\(scheme)://home")!

    public static func thread(_ id: UUID) -> URL {
        URL(string: "\(scheme)://thread/\(id.uuidString)")!
    }

    /// The thread a link names; nil for home and for what isn't ours.
    public static func thread(in url: URL) -> UUID? {
        guard url.scheme == scheme, url.host() == "thread" else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
}

extension PhoneClient {
    public var island: IslandState? {
        IslandState(mac: mac, projects: projects, threads: threads, asks: asks)
    }
}
