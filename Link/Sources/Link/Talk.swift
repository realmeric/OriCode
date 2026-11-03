import Foundation
import Observation

/// One row of a thread's conversation as the phone draws it, read off the Mac's transcript.
public struct TalkLine: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// What Meriç wrote, a bubble on the right.
        case mine
        /// What the thread that opened this one told it: not Meriç's message, so not his bubble.
        case task
        /// An agent's Markdown.
        case agent
        /// A call, or a run of them, as one quiet line.
        case tools
        /// An ask, in its place: its card while `AskInfo` holds it, afterwards `text`.
        case ask
        case note
    }

    /// The transcript's item, the first of a run's.
    public var id: String
    public var kind: Kind
    public var text: String
    /// A message's pictures, or a run's calls.
    public var count: Int
    /// Each of a run's calls, which a tap opens.
    public var calls: [String]
    /// How many calls failed.
    public var failed: Int
    /// An ask's request id.
    public var ask: String?

    public init(id: String, kind: Kind, text: String, count: Int = 0, calls: [String] = [], failed: Int = 0, ask: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.count = count
        self.calls = calls
        self.failed = failed
        self.ask = ask
    }
}

/// Part of a thread's conversation, oldest first by `index`. Every page but the newest is finished
/// and never changes; the newest is written again as the thread goes on.
public struct TalkPage: Codable, Equatable, Sendable {
    public var thread: UUID
    public var index: Int
    public var lines: [TalkLine]

    public init(thread: UUID, index: Int, lines: [TalkLine]) {
        self.thread = thread
        self.index = index
        self.lines = lines
    }
}

public enum Talk {
    /// What a page holds, well under CloudKit's megabyte: the newest page is sent again every two
    /// seconds while a reply streams into it.
    public static let pageBytes = 48_000
    /// The most of one reply a line carries: a page holds at least one line, however long.
    public static let lineBytes = 600_000
    /// What the Mac's bubble reads of a message (Item.headLength).
    public static let messageLength = 20_000
    /// The pages published as a thread opens.
    public static let openingPages = 2
    /// How many pages one ask for earlier ones adds.
    public static let earlierPages = 3

    /// How much of a page a line takes, field names and all, by its text alone, so a page is cut
    /// in the same place however many times it's made.
    static func size(of line: TalkLine) -> Int {
        line.text.utf8.count + line.calls.reduce(0) { $0 + $1.utf8.count + 3 } + 96
    }

    /// The lines cut into pages, each filled up to `pageBytes` and holding one line at least.
    public static func cut(_ lines: [TalkLine], pageBytes: Int = pageBytes) -> [Range<Int>] {
        var pages: [Range<Int>] = []
        var start = 0
        var bytes = 0
        for (index, line) in lines.enumerated() {
            let size = size(of: line)
            if index > start, bytes + size > pageBytes {
                pages.append(start..<index)
                start = index
                bytes = 0
            }
            bytes += size
        }
        if start < lines.count { pages.append(start..<lines.count) }
        return pages
    }

    /// The pages in hand as one conversation. A line found twice, after the Mac has read a thread
    /// again and cut it elsewhere, stands once, in the newest page that has it.
    public static func merged(_ pages: [Int: [TalkLine]]) -> [TalkLine] {
        var seen = Set<String>()
        var lines: [TalkLine] = []
        for index in pages.keys.sorted(by: >) {
            for line in (pages[index] ?? []).reversed() where seen.insert(line.id).inserted {
                lines.append(line)
            }
        }
        return lines.reversed()
    }

    /// A message sent from the phone: its words, and the last message the conversation held then.
    public struct Outgoing: Sendable {
        public var id: String
        public var text: String
        public var after: String?

        public init(id: String, text: String, after: String?) {
            self.id = id
            self.text = text
            self.after = after
        }
    }

    /// The messages the conversation carries now, oldest first: each is the first message after
    /// the one before it, or after what the conversation held when it was sent, with its words.
    /// Sent twice with the same words, each takes a line of its own.
    public static func carried(_ sent: [Outgoing], in lines: [TalkLine]) -> Set<String> {
        let mine = lines.filter { $0.kind == .mine || $0.kind == .task }
        var carried = Set<String>()
        var from = 0
        for message in sent {
            if let after = message.after, let held = mine.firstIndex(where: { $0.id == after }) { from = max(from, held + 1) }
            let words = String(message.text.prefix(messageLength))
            guard let found = mine[from...].firstIndex(where: { $0.text == words }) else { continue }
            carried.insert(message.id)
            from = found + 1
        }
        return carried
    }
}

/// Which thread each phone is watching and until when. A phone says so again every minute; the
/// word that lapses or says it left ends the lease, and with no lease the Mac publishes nothing.
public struct Leases: Equatable, Sendable {
    public static let life: TimeInterval = 120
    public static let renewal: Duration = .seconds(60)

    public struct Lease: Equatable, Sendable {
        public var thread: UUID?
        public var until: Date
        /// When the phone said so, by CloudKit's clock: commands can be read out of order.
        public var said: Date
    }

    public private(set) var phones: [String: Lease] = [:]

    public init() {}

    public var threads: Set<UUID> { Set(phones.values.compactMap(\.thread)) }

    /// When the next lease lapses.
    public var nextEnd: Date? { phones.values.filter { $0.thread != nil }.map(\.until).min() }

    /// A phone's word, `thread` nil for leaving. Older than the word it has given since, or already
    /// lapsed, it changes nothing. Returns whether it counted.
    @discardableResult
    public mutating func take(_ thread: UUID?, phone: String, said: Date, now: Date = .now) -> Bool {
        if let lease = phones[phone], lease.said > said { return false }
        let until = said.addingTimeInterval(Self.life)
        guard thread == nil || until > now else { return false }
        phones[phone] = Lease(thread: thread, until: until, said: said)
        return true
    }

    /// Drops what has lapsed, and what a phone left long enough ago that no late word can follow.
    public mutating func expire(now: Date = .now) {
        phones = phones.filter { $0.value.until > now }
    }
}

/// The conversation on screen, kept in memory only and gone with the screen: never in Cache.json,
/// never on disk. A row is an object of its own so a reply streaming into the last one draws that
/// row and leaves the list alone.
@MainActor
@Observable
public final class ThreadTalk {
    @MainActor
    @Observable
    public final class Row: Identifiable {
        public let id: String
        /// A row's kind never changes, so the list can read it for spacing without drawing again.
        public let kind: TalkLine.Kind
        public fileprivate(set) var line: TalkLine

        fileprivate init(_ line: TalkLine) {
            id = line.id
            kind = line.kind
            self.line = line
        }
    }

    public let thread: UUID
    public private(set) var rows: [Row] = []
    /// The earliest page in hand, nil until one has come.
    public private(set) var first: Int?
    /// The latest page in hand.
    public private(set) var last: Int?
    /// The page asked for, until it's in hand.
    public private(set) var asked: Int?
    @ObservationIgnored private var pages: [Int: [TalkLine]] = [:]
    @ObservationIgnored private var held: [String: Row] = [:]

    public init(thread: UUID) {
        self.thread = thread
    }

    public var hasEarlier: Bool { (first ?? 0) > 0 }

    /// The latest message in the conversation, which a message sent now will come after.
    public var lastMessage: String? {
        rows.last { $0.kind == .mine || $0.kind == .task }?.id
    }

    var lines: [TalkLine] { rows.map(\.line) }

    /// Whether a row holds this ask.
    public func holds(ask: String) -> Bool {
        held.values.contains { $0.line.ask == ask }
    }

    /// A page from the Mac. Rows stay the objects they were and only a changed one is touched, so
    /// `rows` changes only when a row comes.
    func take(_ page: TalkPage) {
        guard pages[page.index] != page.lines else { return }
        pages[page.index] = page.lines
        first = pages.keys.min()
        last = pages.keys.max()
        if let wanted = asked, let first, first <= wanted { asked = nil }
        var kept: [String: Row] = [:]
        let lines = Talk.merged(pages)
        let next = lines.map { line in
            let row = held[line.id].flatMap { $0.kind == line.kind ? $0 : nil } ?? Row(line)
            if row.line != line { row.line = line }
            kept[line.id] = row
            return row
        }
        held = kept
        if next.map(\.id) != rows.map(\.id) { rows = next }
    }

    /// The words of a message sent to `thread`, from `sent`.
    nonisolated static func written(_ message: PhoneClient.Sent, to thread: UUID) -> String? {
        switch message.action {
        case .send(thread, let text): text
        case .open(_, let text) where message.thread == thread: text
        default: nil
        }
    }

    /// The page to ask for next, once scrolled to the top of what's in hand.
    func askEarlier() -> Int? {
        guard asked == nil, let first, first > 0 else { return nil }
        asked = max(0, first - Talk.earlierPages)
        return asked
    }
}
