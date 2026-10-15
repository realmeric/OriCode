import Foundation
import Observation

/// A session's estimated water (K-264), the window's side of the ori-water mod. `water.json`
/// beside this file is the definition, a byte-identical copy of the mod's: every coefficient and
/// display number comes from it, and its `formula` says in words what this file does. Nothing
/// else in the app counts or writes the figure.
enum Water {
    enum Kind: String, CaseIterable, Sendable {
        case input, output, cacheRead, cacheWrite

        /// As the mod's `/water` names it.
        var name: String {
            switch self {
            case .input: "input"
            case .output: "output"
            case .cacheRead: "cache read"
            case .cacheWrite: "cache write"
            }
        }
    }

    /// A number per kind of token, in doubles as the formula has them.
    struct Tokens: Equatable, Sendable {
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var cacheWrite = 0.0

        subscript(kind: Kind) -> Double {
            get {
                switch kind {
                case .input: input
                case .output: output
                case .cacheRead: cacheRead
                case .cacheWrite: cacheWrite
                }
            }
            set {
                switch kind {
                case .input: input = newValue
                case .output: output = newValue
                case .cacheRead: cacheRead = newValue
                case .cacheWrite: cacheWrite = newValue
                }
            }
        }

        static func += (sum: inout Tokens, more: Tokens) {
            for kind in Kind.allCases { sum[kind] += more[kind] }
        }
    }

    struct Definition: Decodable, Sendable {
        struct Source: Decodable, Sendable {
            let name: String
            let url: String
            let quote: String
        }

        struct Display: Decodable, Sendable {
            let mlPerLitre: Double
            let litreUnit: String
            let litreDecimals: Int
            let glassDecimals: Int
            let decimalSeparator: String
        }

        struct Fields: Decodable, Sendable {
            let input: String
            let output: String
            let cacheRead: String
            let cacheWrite: String

            subscript(kind: Kind) -> String {
                switch kind {
                case .input: input
                case .output: output
                case .cacheRead: cacheRead
                case .cacheWrite: cacheWrite
                }
            }
        }

        let version: Int
        let source: Source
        let mlPerThousandTokens: Tokens
        let usageFields: Fields
        let glassMl: Double
        let display: Display

        /// The copy the app carries.
        static let bundled: Definition? = Bundle.main.url(forResource: "water", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(Definition.self, from: $0) }
    }

    /// The "thousand" in mlPerThousandTokens.
    private static let tokensPerCoefficient = 1000.0

    /// The four products added left to right in the kinds' order and the sum divided once.
    static func millilitres(_ tokens: Tokens, by definition: Definition) -> Double {
        var sum = 0.0
        for kind in Kind.allCases {
            sum += tokens[kind] * definition.mlPerThousandTokens[kind]
        }
        return sum / tokensPerCoefficient
    }

    /// Half up everywhere.
    private static func round(_ x: Double) -> Double {
        (x + 0.5).rounded(.down)
    }

    /// A whole number in decimal digits, with no grouping and nothing from the locale.
    private static func digits(_ x: Double) -> String {
        Int64(exactly: x).map(String.init) ?? String(x)
    }

    private static func fixed(_ x: Double, per: Double, decimals: Int, by definition: Definition) -> String {
        let scale = pow(10, Double(decimals))
        // Multiplied before it is divided.
        let n = round(x * scale / per)
        let remainder = digits(n.truncatingRemainder(dividingBy: scale))
        return digits((n / scale).rounded(.down)) + definition.display.decimalSeparator
            + String(repeating: "0", count: max(0, decimals - remainder.count)) + remainder
    }

    /// In litres at every size, as a water meter keeps one unit: "0.0003 L", "1.1250 L".
    static func volume(_ ml: Double, by definition: Definition) -> String {
        let display = definition.display
        return "\(fixed(ml, per: display.mlPerLitre, decimals: display.litreDecimals, by: definition)) \(display.litreUnit)"
    }

    static func glasses(_ ml: Double, by definition: Definition) -> String {
        fixed(ml, per: definition.glassMl, decimals: definition.display.glassDecimals, by: definition)
    }

    /// One assistant message as its lines have it so far: each kind at the largest value among
    /// them, and the earliest of their timestamps, which is when the calendar counts it. A
    /// message whose lines carry none counts in its session and in no day.
    struct Message: Sendable {
        var tokens = Tokens()
        var time: Date?

        /// The same message read again, on another line or in a transcript that carried it over.
        mutating func merge(_ other: Message) {
            for kind in Kind.allCases { tokens[kind] = max(tokens[kind], other.tokens[kind]) }
            if let time = other.time, self.time.map({ time < $0 }) ?? true { self.time = time }
        }
    }

    /// A transcript's count so far: each message's tokens by its id, their sum, and how far into
    /// the file it has read, so a turn's end reads only what the turn appended.
    struct Tally: Sendable {
        private(set) var tokens = Tokens()
        private(set) var offset: UInt64 = 0
        private(set) var messages: [String: Message] = [:]
        /// The head of a line whose line feed hasn't been written yet. It counts once it has one.
        private var unfinished = Data()

        private static let lineFeed = UInt8(ascii: "\n")

        /// Takes the file's next bytes, counting each line they finish.
        mutating func take(_ bytes: Data, by definition: Definition) {
            var start = bytes.startIndex
            while let feed = Self.lineFeed(in: bytes, from: start) {
                if unfinished.isEmpty {
                    count(line: bytes[start..<feed], by: definition)
                } else {
                    unfinished.append(bytes[start..<feed])
                    count(line: unfinished, by: definition)
                    unfinished = Data()
                }
                start = bytes.index(after: feed)
            }
            unfinished.append(bytes[start...])
            offset += UInt64(bytes.count)
        }

        /// By memchr: a byte at a time, the search was most of a month's first reading.
        private static func lineFeed(in bytes: Data, from start: Data.Index) -> Data.Index? {
            bytes.withUnsafeBytes { buffer in
                let skipped = start - bytes.startIndex
                guard let base = buffer.baseAddress, skipped < buffer.count,
                      let found = memchr(base + skipped, Int32(lineFeed), buffer.count - skipped)
                else { return nil }
                return bytes.startIndex + (UnsafeRawPointer(found) - base)
            }
        }

        /// One line of a transcript. It counts when it is an assistant's, not a sidechain's, with
        /// a message id and a usage; the lines of one message count once, each kind at the largest
        /// value among them.
        mutating func count(line: Data, by definition: Definition) {
            guard Self.mayBeAssistant(line), let row = Self.object(in: line), row["type"] as? String == "assistant",
                  !Self.isTrue(row["isSidechain"]),
                  let message = row["message"] as? [String: Any],
                  let id = message["id"] as? String, !id.isEmpty
            else { return }
            let usage: [String: Any]
            switch message["usage"] {
            case let object as [String: Any]: usage = object
            // An array is an object to the mod, one with none of the fields.
            case is [Any]: usage = [:]
            default: return
            }
            var line = Message(time: (row["timestamp"] as? String).flatMap { try? Date($0, strategy: Self.timestamp) })
            for kind in Kind.allCases {
                guard let number = usage[definition.usageFields[kind]] as? NSNumber, !Self.isBoolean(number) else { continue }
                let value = number.doubleValue
                if value.isFinite, value > 0 { line.tokens[kind] = value }
            }
            var counted = messages[id] ?? Message()
            let before = counted.tokens
            counted.merge(line)
            for kind in Kind.allCases { tokens[kind] += counted.tokens[kind] - before[kind] }
            messages[id] = counted
        }

        /// Claude Code's, as JavaScript's toISOString writes it: "2026-10-15T09:41:07.123Z".
        private static let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

        /// A line whose type is "assistant" has the word in it, or an escape that could spell it.
        /// Most of a transcript's bytes are tool results with neither, six in seven of this
        /// month's on one Mac, and those aren't parsed.
        private static func mayBeAssistant(_ line: Data) -> Bool {
            line.withUnsafeBytes { bytes in
                [assistantWord, escape].contains { needle in
                    needle.withUnsafeBytes { memmem(bytes.baseAddress, bytes.count, $0.baseAddress, $0.count) != nil }
                }
            }
        }

        private static let assistantWord = Data("assistant".utf8)
        private static let escape = Data(#"\u"#.utf8)

        /// A line that doesn't parse is skipped. One that isn't UTF-8 is read as the mod reads
        /// it, with the bytes that aren't replaced.
        private static func object(in line: Data) -> [String: Any]? {
            if let object = try? JSONSerialization.jsonObject(with: line) { return object as? [String: Any] }
            guard String(data: line, encoding: .utf8) == nil else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(String(decoding: line, as: UTF8.self).utf8))) as? [String: Any]
        }

        /// JSON's `true` and a number both arrive as an NSNumber.
        private static func isBoolean(_ number: NSNumber) -> Bool {
            CFGetTypeID(number) == CFBooleanGetTypeID()
        }

        private static func isTrue(_ value: Any?) -> Bool {
            (value as? NSNumber).map { isBoolean($0) && $0.boolValue } ?? false
        }
    }

    /// A session's transcript: `<session id>.jsonl` in the session's project folder under the
    /// Claude config folder's `projects`. The folder is named after the path the session ran in,
    /// each character that isn't a letter or a digit a hyphen; a path Claude Code wrote another
    /// way, a long one or one it resolved first, is found by looking in each project folder.
    static func transcript(session: String, cwd: String, config: URL = configFolder) -> URL? {
        guard !session.isEmpty, !session.contains("/"), session != ".." else { return nil }
        let projects = config.appending(path: "projects", directoryHint: .isDirectory)
        let file = "\(session).jsonl"
        let named = String(cwd.unicodeScalars.map { $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0) ? Character($0) : "-" })
        let first = projects.appending(path: named, directoryHint: .isDirectory).appending(path: file)
        if FileManager.default.fileExists(atPath: first.path) { return first }
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.lazy.map { $0.appending(path: file) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `~/.claude` unless CLAUDE_CONFIG_DIR moves it, which the engine leaves to Claude Code too.
    static var configFolder: URL {
        ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude", directoryHint: .isDirectory)
    }

    /// Reads what the file has gained since `tally` last read it. A file shorter than it was is
    /// another file, counted from its start.
    static func read(_ file: URL, into tally: inout Tally, by definition: Definition) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < tally.offset { tally = Tally() }
        try handle.seek(toOffset: tally.offset)
        while tally.offset < size {
            guard let bytes = try handle.read(upToCount: Int(min(chunkBytes, size - tally.offset))), !bytes.isEmpty else { break }
            tally.take(bytes, by: definition)
        }
    }

    /// A long session's transcript is hundreds of megabytes; it's never held whole.
    private static let chunkBytes: UInt64 = 4 * 1024 * 1024

    /// Every Claude Code session on this Mac, for today, this week, this month and the usual day. Each
    /// session is counted by the formula's own rule, its file and nothing under
    /// `<session id>/subagents/`, and its sidechain lines skipped, so a subagent's tokens count
    /// in no period as they count in no session. A message a resumed or forked session carried
    /// over is in two files with the same id and its first timestamp; it counts once, by its id
    /// across the files, as the formula counts a message once within one.
    ///
    /// The projects folder is gigabytes, so only transcripts written to since the earliest of
    /// the periods began, nearly always the usual day's 30, are read, each from where the last
    /// reading left it.
    struct Ledger: Sendable {
        /// A tally per transcript path.
        private(set) var tallies: [String: Tally] = [:]

        /// Reads what each session written to since `periods` began has gained. A transcript
        /// last written before then holds nothing they count, and is let go.
        mutating func read(config: URL, by definition: Definition, periods: Periods.Bounds) {
            let projects = config.appending(path: "projects", directoryHint: .isDirectory)
            let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
            let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            var kept: [String: Tally] = [:]
            for folder in folders {
                let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    guard let values = try? file.resourceValues(forKeys: keys), let written = values.contentModificationDate,
                          written >= periods.earliest
                    else { continue }
                    var tally = tallies[file.path] ?? Tally()
                    if UInt64(values.fileSize ?? 0) != tally.offset, (try? Water.read(file, into: &tally, by: definition)) == nil { continue }
                    kept[file.path] = tally
                }
            }
            tallies = kept
        }

        /// Each period's tokens: its messages, each once, in the period its time falls in.
        func tokens(in periods: Periods.Bounds) -> (today: Tokens, week: Tokens, month: Tokens, usual: Tokens) {
            var messages: [String: Message] = [:]
            for tally in tallies.values {
                for (id, message) in tally.messages { messages[id, default: message].merge(message) }
            }
            var sums = (today: Tokens(), week: Tokens(), month: Tokens(), usual: Tokens())
            for message in messages.values {
                guard let time = message.time else { continue }
                if periods.today.contains(time) { sums.today += message.tokens }
                if periods.week.contains(time) { sums.week += message.tokens }
                if periods.month.contains(time) { sums.month += message.tokens }
                if periods.usual.contains(time) { sums.usual += message.tokens }
            }
            return sums
        }
    }

    /// Today's, this week's and this month's water on this Mac, as the usage card words them, and
    /// today's against a usual day, which is how full the glass of water stands.
    struct Periods: Equatable, Sendable {
        /// The calendar's day, week and month around a moment, and the 30 days before the day, in
        /// the user's locale and time zone unless a test hands it another.
        struct Bounds: Sendable {
            let today: Range<Date>
            let week: Range<Date>
            let month: Range<Date>
            /// Calendar days, so one with a change of the clocks in it is a day too.
            let usual: Range<Date>

            static let usualDays = 30

            init(_ now: Date, calendar: Calendar = .autoupdatingCurrent) {
                func range(_ component: Calendar.Component) -> Range<Date> {
                    let interval = calendar.dateInterval(of: component, for: now) ?? DateInterval(start: now, duration: 0)
                    return interval.start..<interval.end
                }
                today = range(.day)
                week = range(.weekOfYear)
                month = range(.month)
                let before = calendar.date(byAdding: .day, value: -Self.usualDays, to: today.lowerBound) ?? today.lowerBound
                usual = before..<today.lowerBound
            }

            /// A week that began in the month before begins before the month, and the usual day's
            /// 30 begin before both, or with the month on its 31st.
            var earliest: Date { min(week.lowerBound, month.lowerBound, usual.lowerBound) }
        }

        let today: Reading
        let week: Reading
        let month: Reading
        /// The 30 days before today over 30, a day with no water a day of none. Nil when none of
        /// them had any: there's no usual day to tell, and none is made up.
        let usualDay: Reading?

        init(_ ledger: Ledger, in bounds: Bounds, by definition: Definition) {
            let tokens = ledger.tokens(in: bounds)
            today = Reading(tokens.today, by: definition)
            week = Reading(tokens.week, by: definition)
            month = Reading(tokens.month, by: definition)
            var day = tokens.usual
            for kind in Kind.allCases { day[kind] /= Double(Bounds.usualDays) }
            let usual = Reading(day, by: definition)
            usualDay = usual.ml > 0 ? usual : nil
        }

        /// How full the glass stands: today's water over a usual day's, full at a usual day and
        /// still full past it. With no usual day, today is measured against itself, so any water
        /// at all fills it.
        var level: Double {
            guard let usualDay else { return today.ml > 0 ? 1 : 0 }
            return min(today.ml / usualDay.ml, 1)
        }

        /// Today has gone past a usual day.
        var overflowing: Bool {
            usualDay.map { today.ml > $0.ml } ?? false
        }
    }

    /// What the window says of a session: the figure, and the words the usage card puts by it.
    struct Reading: Equatable, Sendable {
        let tokens: Tokens
        let ml: Double
        /// "0.0160 L", "1.1250 L".
        let volume: String
        let glasses: String
        /// Whether it is a glass's first decimal yet, which is when the mod names glasses.
        let hasGlasses: Bool
        let glassMl: String
        /// "112.5 ml per thousand output tokens", each kind that costs anything.
        let coefficient: String
        let source: String

        init(_ tokens: Tokens, by definition: Definition) {
            self.tokens = tokens
            ml = Water.millilitres(tokens, by: definition)
            volume = Water.volume(ml, by: definition)
            glasses = Water.glasses(ml, by: definition)
            hasGlasses = glasses != Water.glasses(0, by: definition)
            glassMl = "\(Water.plain(definition.glassMl)) \(Water.millilitre)"
            coefficient = Kind.allCases.filter { definition.mlPerThousandTokens[$0] != 0 }.map {
                "\(Water.plain(definition.mlPerThousandTokens[$0])) \(Water.millilitre) per thousand \($0.name) tokens"
            }.joined(separator: ", ")
            source = definition.source.name
        }

        /// Under the thread's latest turn.
        var footer: String { "≈ \(volume) of water so far, estimated" }
    }

    /// The unit glassMl and mlPerThousandTokens are in by their names. The file words the litre
    /// alone and leaves this one to its host, and the mod's `/water` says "ml" too.
    private static let millilitre = "ml"

    /// A number from the file as it's written there: 112.5, 250.
    private static func plain(_ x: Double) -> String {
        Int64(exactly: x).map(String.init) ?? String(x)
    }
}

extension Water.Tokens: Decodable {}

/// One thread's water, read from its session's transcript off the main thread when the thread
/// comes into view, a moment after its tools' results and when a turn of it ends, and at no
/// other time. Nothing is read while Settings › Conversation leaves water off.
@MainActor
@Observable
final class WaterMeter {
    /// Nil for a thread with no Claude Code transcript: a draft, another agent's, a file that's gone.
    private(set) var reading: Water.Reading?
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var tally = Water.Tally()
    @ObservationIgnored private var reads: Task<Void, Never>?
    @ObservationIgnored private var second: Task<Void, Never>?
    @ObservationIgnored private var coming: Task<Void, Never>?

    /// Claude Code writes a reply's last lines to the transcript a moment after the turn ends, up
    /// to about 100 ms on the mod's measure, so a turn's end is read again, as the mod reads it.
    static let writeWait = Duration.milliseconds(300)

    /// Reads what the session's transcript has gained. `again` takes the second reading a turn's
    /// end needs.
    func read(session: String?, cwd: String, again: Bool = false, definition: Water.Definition? = .bundled, config: URL = Water.configFolder) {
        guard let definition, let session else {
            forget()
            return
        }
        if session != self.session {
            forget()
            self.session = session
        }
        let earlier = reads
        reads = Task { [weak self] in
            await earlier?.value
            guard let self, self.session == session else { return }
            let (known, counted) = (file, tally)
            let read = await Task.detached(priority: .utility) { () -> (file: URL, tally: Water.Tally)? in
                guard let file = known ?? Water.transcript(session: session, cwd: cwd, config: config) else { return nil }
                var tally = counted
                guard (try? Water.read(file, into: &tally, by: definition)) != nil else { return nil }
                return (file, tally)
            }.value
            guard self.session == session else { return }
            if let read {
                file = read.file
                tally = read.tally
            } else {
                // Gone, or not written yet: looked for again at the next reading.
                file = nil
                tally = Water.Tally()
            }
            let now = read.map { Water.Reading($0.tally.tokens, by: definition) }
            if now != reading { reading = now }
        }
        second?.cancel()
        guard again else { return }
        second = Task { [weak self] in
            try? await Task.sleep(for: Self.writeWait)
            guard !Task.isCancelled else { return }
            self?.read(session: session, cwd: cwd, definition: definition, config: config)
        }
    }

    /// A reading a moment from now, for a tool's result in the middle of a turn, as the mod reads
    /// after each tool: the results that come in that moment share it, and by then Claude Code
    /// has written the call's lines. `reading` asks for it, so it reads the thread as it is then.
    func soon(_ reading: @escaping @MainActor () -> Void) {
        guard coming == nil else { return }
        coming = Task { [weak self] in
            try? await Task.sleep(for: Self.writeWait)
            guard !Task.isCancelled else { return }
            self?.coming = nil
            reading()
        }
    }

    /// The readings asked for so far, for a test to wait on.
    func settled() async {
        await coming?.value
        await second?.value
        await reads?.value
    }

    /// Nothing to show, now: a thread that left its session, to another agent or a new one.
    func forget() {
        coming?.cancel()
        coming = nil
        second?.cancel()
        session = nil
        file = nil
        tally = Water.Tally()
        if reading != nil { reading = nil }
    }
}

/// This Mac's water by the calendar, read off the main thread with the glass of water on: when a
/// glass of water comes into a composer, when its card opens, and a moment after a turn of a
/// Claude Code thread in view ends; at no other time, and never while the switch is off. The
/// first reading goes through the transcripts of the last 30 days and the month; each after it
/// reads only what they gained.
@MainActor
@Observable
final class WaterTotals {
    /// Nil until the first reading has come back.
    private(set) var periods: Water.Periods?
    @ObservationIgnored private var ledger = Water.Ledger()
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var again = false

    /// Asked while a reading is on its way, it reads once more when that one is back, since the
    /// transcripts may have grown past where it began; however many ask meanwhile share that one.
    /// `wait` lets a turn's last lines be written first.
    func read(after wait: Duration = .zero, definition: Water.Definition? = .bundled, config: URL = Water.configFolder, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) {
        guard let definition else { return }
        guard reading == nil else {
            again = true
            return
        }
        let counted = ledger
        reading = Task { [weak self] in
            try? await Task.sleep(for: wait)
            let read = await Task.detached(priority: .utility) { () -> (ledger: Water.Ledger, periods: Water.Periods) in
                var ledger = counted
                let bounds = Water.Periods.Bounds(now, calendar: calendar)
                ledger.read(config: config, by: definition, periods: bounds)
                return (ledger, Water.Periods(ledger, in: bounds, by: definition))
            }.value
            guard let self else { return }
            ledger = read.ledger
            if read.periods != periods { periods = read.periods }
            reading = nil
            if again {
                again = false
                self.read(definition: definition, config: config, now: now, calendar: calendar)
            }
        }
    }

    /// The readings asked for, for a test to wait on.
    func settled() async {
        while let reading { await reading.value }
    }
}

extension AppModel {
    /// Counts the thread's water again, when Settings asks for water and the thread is one whose
    /// session Claude Code keeps a transcript of. Every other agent's thread shows nothing:
    /// water.json counts a Claude Code transcript and says nothing of another agent's tokens.
    func readWater(for chat: Chat, turnEnded: Bool = false) {
        guard UserDefaults.standard.bool(forKey: TranscriptSettings.showWater), let conversation = conversations[chat.id] else { return }
        conversation.water.read(session: chat.providerID == ProviderInfo.claudeID ? chat.sessionId : nil, cwd: chat.cwd, again: turnEnded)
        // The glass of water stands at today's water, which the turn has just added to.
        if turnEnded, chat.providerID == ProviderInfo.claudeID {
            waterTotals.read(after: WaterMeter.writeWait)
        }
    }

    /// A tool's result in a thread in view: its figure moves within the turn, once for however
    /// many results come in the meter's moment, and never on the stream's deltas.
    func followWater(_ chat: Chat) {
        guard chat.providerID == ProviderInfo.claudeID, UserDefaults.standard.bool(forKey: TranscriptSettings.showWater),
              let conversation = conversations[chat.id] else { return }
        conversation.water.soon { [weak self] in
            // Gone from the glass in that moment: counted when it comes back.
            guard let self, self.inView(chat.id) else { return }
            self.readWater(for: chat)
        }
    }
}
