import CryptoKit
import Foundation
import Testing
@testable import OriCode

/// A thread's estimated water (K-264): App/Water.swift held to water.json's own examples and to
/// the figures the ori-water mod's test expects of the same tokens.
@MainActor
struct WaterTests {
    /// The mod's test's definition (hooks/register.test.ts), which isn't water.json's numbers: the
    /// figure has to come from the file that's read, never from a number written in the code.
    private static let madeUp = Data("""
    {
      "version": 7,
      "source": { "name": "A made-up source", "url": "https://example.test/water", "quote": "Two per token." },
      "mlPerThousandTokens": { "input": 0, "output": 2000, "cacheRead": 0, "cacheWrite": 0 },
      "usageFields": {
        "input": "input_tokens", "output": "output_tokens",
        "cacheRead": "cache_read_input_tokens", "cacheWrite": "cache_creation_input_tokens"
      },
      "glassMl": 500,
      "display": {
        "mlPerLitre": 100, "litreUnit": "L",
        "litreDecimals": 2, "glassDecimals": 1, "decimalSeparator": ","
      }
    }
    """.utf8)

    private static func reply(_ id: String, _ output: Int) -> String {
        #"{"type":"assistant","message":{"id":"\#(id)","usage":{"output_tokens":\#(output)}}}"# + "\n"
    }

    private static func bundledFile() throws -> Data {
        try Data(contentsOf: #require(Bundle.main.url(forResource: "water", withExtension: "json")))
    }

    private static func tokens(_ json: [String: Any]) -> Water.Tokens {
        var tokens = Water.Tokens()
        for kind in Water.Kind.allCases { tokens[kind] = (json[kind.rawValue] as? NSNumber)?.doubleValue ?? -1 }
        return tokens
    }

    /// The copy is the mod's file, byte for byte. A change to a coefficient or a rule is made in
    /// ~/Developer/ori-water/water.json, raises its version, and is copied here with its hash.
    @Test func theCopyIsTheModsFile() throws {
        let hash = SHA256.hash(data: try Self.bundledFile()).map { String(format: "%02x", $0) }.joined()
        #expect(hash == "674402d84f40f157a9ce574341503149b7c924c92ecd6deb9ac4e1fb4d7c6e9a")
        #expect(Water.Definition.bundled?.version == 2)
    }

    /// water.json's examples, which the mod's vectors.check.mts holds its own code to.
    @Test func theFilesExamplesHold() throws {
        let definition = try #require(Water.Definition.bundled)
        let file = try #require(JSONSerialization.jsonObject(with: Self.bundledFile()) as? [String: Any])
        let examples = try #require(file["examples"] as? [String: Any])
        let transcript = try #require(examples["transcript"] as? [String: Any])
        let lines = try #require(transcript["lines"] as? [String])
        #expect(lines.count == 7)

        var tally = Water.Tally()
        for line in lines { tally.count(line: Data(line.utf8), by: definition) }
        #expect(tally.tokens == Self.tokens(try #require(transcript["tokens"] as? [String: Any])))
        #expect(tally.tokens == Water.Tokens(input: 5, output: 100, cacheRead: 1000, cacheWrite: 200))

        let figures = try #require(examples["figures"] as? [[String: Any]])
        #expect(figures.count == 8)
        for figure in figures {
            let tokens = Self.tokens(try #require(figure["tokens"] as? [String: Any]))
            let ml = Water.millilitres(tokens, by: definition)
            #expect(ml == (figure["ml"] as? NSNumber)?.doubleValue)
            #expect(Water.volume(ml, by: definition) == figure["volume"] as? String)
            #expect(Water.glasses(ml, by: definition) == figure["glasses"] as? String)
        }
    }

    /// The same examples written out, so a reader sees the strings without opening the file.
    @Test func theFigureIsWrittenAsTheModWritesIt() throws {
        let definition = try #require(Water.Definition.bundled)
        let written = [(0.0, "0.0000 L", "0.0"), (1, "0.0001 L", "0.0"), (3, "0.0003 L", "0.0"), (100, "0.0113 L", "0.0"),
                       (1000, "0.1125 L", "0.5"), (8885, "0.9996 L", "4.0"), (10000, "1.1250 L", "4.5"),
                       (1_234_567, "138.8888 L", "555.6")]
        for (output, volume, glasses) in written {
            let reading = Water.Reading(Water.Tokens(input: 500_000, output: output, cacheRead: 9_000_000, cacheWrite: 100_000), by: definition)
            #expect(reading.volume == volume)
            #expect(reading.glasses == glasses)
        }
        let reading = Water.Reading(Water.Tokens(output: 142), by: definition)
        #expect(reading.footer == "≈ 0.0160 L of water so far, estimated")
        #expect(reading.hasGlasses)
        #expect(reading.glassMl == "250 ml")
        #expect(reading.coefficient == "112.5 ml per thousand output tokens")
        #expect(reading.source == "Mistral AI, life-cycle analysis of Mistral Large 2 (2025)")
        #expect(!Water.Reading(Water.Tokens(output: 100), by: definition).hasGlasses)
    }

    /// The mod's own test, step for step: a reply of one token, which moves the line, then one
    /// reply on two lines and the head of a line still being written, then the rest of it.
    @Test func theModsTestGivesTheModsStrings() throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        var tally = Water.Tally()
        #expect(Water.volume(Water.millilitres(tally.tokens, by: definition), by: definition) == "0,00 L")

        tally.take(Data(Self.reply("msg_0", 1).utf8), by: definition)
        var reading = Water.Reading(tally.tokens, by: definition)
        #expect(reading.volume == "0,02 L")

        let unfinished = Self.reply("msg_2", 40)
        tally.take(Data((Self.reply("msg_1", 10) + Self.reply("msg_1", 10) + unfinished.prefix(30)).utf8), by: definition)
        reading = Water.Reading(tally.tokens, by: definition)
        #expect(reading.volume == "0,22 L")
        #expect(!reading.hasGlasses)

        tally.take(Data(unfinished.dropFirst(30).utf8), by: definition)
        reading = Water.Reading(tally.tokens, by: definition)
        #expect(reading.volume == "1,02 L")
        #expect(reading.glasses == "0,2")
        #expect(reading.hasGlasses)
        #expect(reading.coefficient == "2000 ml per thousand output tokens")
        #expect(reading.source == "A made-up source")
        #expect(reading.glassMl == "500 ml")
    }

    /// What the formula says of a line, case by case.
    @Test func onlyAnAssistantsOwnLinesCount() throws {
        let definition = try #require(Water.Definition.bundled)
        func counted(_ line: String) -> Water.Tokens {
            var tally = Water.Tally()
            tally.count(line: Data(line.utf8), by: definition)
            return tally.tokens
        }
        let none = Water.Tokens()
        #expect(counted(#"{"type":"assistant","message":{"id":"a","usage":{"output_tokens":7}}}"#).output == 7)
        #expect(counted(#"{"type":"user","message":{"id":"a","usage":{"output_tokens":7}}}"#) == none)
        // Spelled in escapes, it's still an assistant's: lines are only left unparsed when they can't be.
        #expect(counted(#"{"t\u0079pe":"\u0061ssist\u0061nt","message":{"id":"a","usage":{"output_tokens":7}}}"#).output == 7)
        #expect(counted(#"{"type":"assistant","isSidechain":true,"message":{"id":"a","usage":{"output_tokens":7}}}"#) == none)
        // Only `true` is a sidechain, as in the mod.
        #expect(counted(#"{"type":"assistant","isSidechain":1,"message":{"id":"a","usage":{"output_tokens":7}}}"#).output == 7)
        #expect(counted(#"{"type":"assistant","message":{"id":"","usage":{"output_tokens":7}}}"#) == none)
        #expect(counted(#"{"type":"assistant","message":{"id":3,"usage":{"output_tokens":7}}}"#) == none)
        #expect(counted(#"{"type":"assistant","message":{"id":"a","usage":null}}"#) == none)
        #expect(counted(#"{"type":"assistant","message":{"id":"a","usage":{"output_tokens":true,"input_tokens":"9","cache_read_input_tokens":-4}}}"#) == none)
        #expect(counted(#"{"type":"assistant","message":{"id":"a","usage":{"output_tok"#) == none)
        #expect(counted("[1, 2]") == none)
        #expect(counted("") == none)
    }

    /// A transcript on disk: found by its session under the config folder, read to its end, and
    /// after that only what it has gained. A file shorter than it was is counted from its start.
    @Test func aTranscriptIsReadOnceAndThenOnlyWhatItGained() throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let config = FileManager.default.temporaryDirectory.appending(path: "water-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appending(path: "projects/-tmp-alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.appending(path: "projects/-tmp-other"), withIntermediateDirectories: true)
        let file = project.appending(path: "one.jsonl")

        #expect(Water.transcript(session: "one", cwd: "/tmp/alpha", config: config) == nil)
        try Data((Self.reply("msg_1", 10) + Self.reply("msg_1", 10)).utf8).write(to: file)
        #expect(Water.transcript(session: "one", cwd: "/tmp/alpha", config: config)?.path == file.path)
        // Named another way than the thread's folder, it's still found by its session.
        #expect(Water.transcript(session: "one", cwd: "/somewhere/else", config: config)?.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        #expect(Water.transcript(session: "../one", cwd: "/tmp/alpha", config: config) == nil)
        #expect(Water.transcript(session: "two", cwd: "/tmp/alpha", config: config) == nil)

        var tally = Water.Tally()
        try Water.read(file, into: &tally, by: definition)
        #expect(tally.tokens.output == 10)
        let read = tally.offset

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Self.reply("msg_2", 40).utf8))
        try handle.close()
        try Water.read(file, into: &tally, by: definition)
        #expect(tally.tokens.output == 50)
        #expect(tally.offset > read)

        try Data(Self.reply("msg_9", 3).utf8).write(to: file)
        try Water.read(file, into: &tally, by: definition)
        #expect(tally.tokens.output == 3)
    }

    /// The meter a thread holds: nothing for a thread with no session or no transcript, the
    /// figure once there is one, and nothing again when the thread has no session of Claude Code's.
    @Test func aThreadsMeterReadsItsSession() async throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let config = FileManager.default.temporaryDirectory.appending(path: "water-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let project = config.appending(path: "projects/-tmp-alpha")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let meter = WaterMeter()

        meter.read(session: "one", cwd: "/tmp/alpha", definition: definition, config: config)
        await meter.settled()
        #expect(meter.reading == nil)

        try Data(Self.reply("msg_1", 10).utf8).write(to: project.appending(path: "one.jsonl"))
        meter.read(session: "one", cwd: "/tmp/alpha", again: true, definition: definition, config: config)
        await meter.settled()
        #expect(meter.reading?.volume == "0,20 L")
        #expect(meter.reading?.footer == "≈ 0,20 L of water so far, estimated")

        // Another session is another transcript, counted from nothing.
        try Data(Self.reply("msg_1", 40).utf8).write(to: project.appending(path: "two.jsonl"))
        meter.read(session: "two", cwd: "/tmp/alpha", definition: definition, config: config)
        await meter.settled()
        #expect(meter.reading?.volume == "0,80 L")

        meter.read(session: nil, cwd: "/tmp/alpha", definition: definition, config: config)
        #expect(meter.reading == nil)
    }

    /// The footer says the thread's water only where it's handed it, and a turn with nothing else
    /// to say still gets the line.
    @Test func theLatestFooterIsTheOneThatSaysIt() throws {
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        container.mainContext.insert(chat)
        let conversation = Conversation(chat: chat, context: container.mainContext)
        #expect(conversation.lastFooter == nil)
        for _ in 0..<2 {
            conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: [
                "event": "turn.done", "stopReason": .string("end_turn"), "durationMs": .number(1000), "costUSD": .number(0),
            ]))
        }
        let footers = conversation.items.compactMap { item in if case .footer(let id, _) = item { id } else { nil } }
        #expect(footers.count == 2)
        #expect(conversation.lastFooter == footers.last)
    }

    /// A Claude thread whose figure stands, moved to another agent, shows nothing straight away,
    /// and a reading still on its way when it moves doesn't land after (K-265).
    @Test func aThreadMovedToAnotherAgentShowsNoWaterAtOnce() async throws {
        let restore = ModelMenuTests.keepingDefaults()
        defer { restore() }
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let config = FileManager.default.temporaryDirectory.appending(path: "water-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        let folder = config.appending(path: "projects/-tmp-alpha")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(Self.reply("msg_1", 10).utf8).write(to: folder.appending(path: "s1.jsonl"))

        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: "/tmp/alpha")
        container.mainContext.insert(project)
        let model = AppModel(container: container)
        model.models = ModelMenuTests.claudeModels
        model.modelsByAgent[ModelMenuTests.codex.id] = ModelMenuTests.codexModels
        model.providers = [.claude, ModelMenuTests.codex]
        model.selectedProjectID = project.id
        let chat = Chat(project: project)
        chat.started = true
        chat.model = "default"
        container.mainContext.insert(chat)
        let conversation = model.conversation(for: chat)
        conversation.userSent("hello")
        conversation.receive(EngineEvent(name: "turn.done", threadId: chat.id.uuidString, body: [
            "event": "turn.done", "sessionId": "s1", "stopReason": "end_turn", "durationMs": 1, "costUSD": 0,
        ]))
        #expect(chat.sessionId == "s1")

        conversation.water.read(session: chat.sessionId, cwd: chat.cwd, definition: definition, config: config)
        await conversation.water.settled()
        #expect(conversation.water.reading?.volume == "0,20 L")

        // On its way when the thread moves, and a tool's reading asked for too.
        conversation.water.read(session: chat.sessionId, cwd: chat.cwd, again: true, definition: definition, config: config)
        conversation.water.soon { Issue.record("a reading asked for before the move was taken after it") }
        model.setModel(ModelRef(provider: "codex", id: "gpt-6-luna"), for: chat)
        #expect(chat.providerID == "codex" && chat.sessionId == nil)
        #expect(conversation.water.reading == nil)
        await conversation.water.settled()
        try await Task.sleep(for: WaterMeter.writeWait * 2)
        #expect(conversation.water.reading == nil)
    }

    /// A Friday in a week that began in September, in a zone eight hours from UTC at its widest
    /// and with a summer time, where weeks begin on Sunday: Sunday 27 September to Saturday
    /// 3 October, and the month from 1 October.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }()
    private static let friday = ISO8601DateFormatter().date(from: "2026-10-02T16:00:00Z")!

    private static func reply(_ id: String, _ output: Int, at time: String, sidechain: Bool = false) -> String {
        #"{"type":"assistant","isSidechain":\#(sidechain),"timestamp":"\#(time)","message":{"id":"\#(id)","usage":{"output_tokens":\#(output)}}}"# + "\n"
    }

    private static func projects() throws -> (config: URL, alpha: URL, beta: URL) {
        let config = FileManager.default.temporaryDirectory.appending(path: "water-\(UUID().uuidString)")
        let alpha = config.appending(path: "projects/-tmp-alpha")
        let beta = config.appending(path: "projects/-tmp-beta")
        try FileManager.default.createDirectory(at: alpha.appending(path: "s1/subagents"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: beta, withIntermediateDirectories: true)
        return (config, alpha, beta)
    }

    private static func append(_ text: String, to file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return try Data(text.utf8).write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    /// Every session on this Mac by the calendar: each message once by its id, on its
    /// lines and in a session that carried it over, in the day, week and month its earliest line's
    /// time falls in, in the calendar's zone; no subagent's, by line or by file; and nothing from
    /// a transcript last written before the 30 days before today began.
    @Test func theCalendarCountsEachMessageOnceWhereItsTimeFalls() async throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let (config, alpha, beta) = try Self.projects()
        defer { try? FileManager.default.removeItem(at: config) }

        try Data([
            // Friday at midnight in New York, 04:00 in UTC: today. Its second line is later, and bigger.
            Self.reply("today", 1, at: "2026-10-02T04:00:00.000Z"),
            Self.reply("today", 3, at: "2026-10-02T04:00:01.000Z"),
            // Saturday in UTC and still Friday in New York.
            Self.reply("late", 10, at: "2026-10-03T02:00:00.000Z"),
            // A moment before Friday: this week and this month.
            Self.reply("thursday", 100, at: "2026-10-02T03:59:59.999Z"),
            // September, in this week.
            Self.reply("monday", 1000, at: "2026-09-28T12:00:00.000Z"),
            // Saturday before the week began.
            Self.reply("before", 7, at: "2026-09-27T03:59:59.999Z"),
            Self.reply("aside", 7, at: "2026-10-02T12:00:00.000Z", sidechain: true),
            #"{"type":"assistant","message":{"id":"timeless","usage":{"output_tokens":7}}}"# + "\n",
        ].joined().utf8).write(to: alpha.appending(path: "s1.jsonl"))
        // A fork of s1, which carried Thursday's message over with its time.
        try Data((Self.reply("thursday", 100, at: "2026-10-02T03:59:59.999Z") + Self.reply("fork", 20000, at: "2026-10-02T15:00:00.000Z")).utf8)
            .write(to: beta.appending(path: "s2.jsonl"))
        try Data(Self.reply("agent", 7, at: "2026-10-02T12:00:00.000Z").utf8).write(to: alpha.appending(path: "s1/subagents/agent-a.jsonl"))
        let old = beta.appending(path: "old.jsonl")
        try Data(Self.reply("old", 7, at: "2026-10-02T12:00:00.000Z").utf8).write(to: old)
        try FileManager.default.setAttributes([.modificationDate: Self.friday.addingTimeInterval(-31 * 86_400)], ofItemAtPath: old.path)

        let totals = WaterTotals()
        totals.read(definition: definition, config: config, now: Self.friday, calendar: Self.calendar)
        await totals.settled()
        let periods = try #require(totals.periods)
        #expect(periods.today.tokens == Water.Tokens(output: 20013))
        #expect(periods.week.tokens == Water.Tokens(output: 21113))
        #expect(periods.month.tokens == Water.Tokens(output: 20113))
        // Two millilitres a token and a hundred to the litre, in the made-up definition.
        #expect(periods.today.volume == "400,26 L")
        #expect(periods.week.volume == "422,26 L")
        #expect(periods.month.volume == "402,26 L")
        #expect(periods.month.source == "A made-up source")
        // Thursday's, Monday's and the Saturday before the week's, over 30.
        #expect(periods.usualDay?.tokens == Water.Tokens(output: 1107.0 / 30))
    }

    /// A ledger read as the transcripts grow, a line cut in two and a session started between
    /// readings included, comes to what one reading of the finished files does.
    @Test func readingAsTheyGrowCountsWhatOneReadingDoes() throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let (config, alpha, beta) = try Self.projects()
        defer { try? FileManager.default.removeItem(at: config) }
        let bounds = Water.Periods.Bounds(Self.friday, calendar: Self.calendar)
        let s1 = alpha.appending(path: "s1.jsonl")
        let s2 = beta.appending(path: "s2.jsonl")
        let cut = Self.reply("b", 40, at: "2026-10-02T13:00:00.000Z")
        let steps: [(URL, String)] = [
            (s1, Self.reply("a", 1, at: "2026-09-29T13:00:00.000Z") + Self.reply("a", 5, at: "2026-09-29T13:00:02.000Z")),
            (s1, String(cut.prefix(40))),
            (s2, Self.reply("a", 5, at: "2026-09-29T13:00:00.000Z") + Self.reply("c", 300, at: "2026-10-01T13:00:00.000Z")),
            (s1, String(cut.dropFirst(40)) + Self.reply("d", 2000, at: "2026-10-02T14:00:00.000Z")),
            (s2, Self.reply("c", 400, at: "2026-10-01T13:00:01.000Z")),
        ]
        var growing = Water.Ledger()
        for (file, text) in steps {
            try Self.append(text, to: file)
            growing.read(config: config, by: definition, periods: bounds)
        }
        var once = Water.Ledger()
        once.read(config: config, by: definition, periods: bounds)

        let grown = growing.tokens(in: bounds)
        let whole = once.tokens(in: bounds)
        #expect(grown.today == whole.today && grown.week == whole.week && grown.month == whole.month)
        #expect(whole.today == Water.Tokens(output: 2040))
        #expect(whole.week == Water.Tokens(output: 2445))
        #expect(whole.month == Water.Tokens(output: 2440))
        #expect(Water.Periods(growing, in: bounds, by: definition) == Water.Periods(once, in: bounds, by: definition))
        #expect(growing.tallies.values.map(\.offset).sorted() == once.tallies.values.map(\.offset).sorted())
    }

    /// The calendar's periods themselves, in the zone and the week it's handed.
    @Test func thePeriodsAreTheCalendarsOwn() {
        let bounds = Water.Periods.Bounds(Self.friday, calendar: Self.calendar)
        // Midnight in New York's summer time is 04:00 in UTC, 1 November's too: its clocks go back at two.
        let midnight = ISO8601DateFormatter()
        #expect(bounds.today == midnight.date(from: "2026-10-02T04:00:00Z")!..<midnight.date(from: "2026-10-03T04:00:00Z")!)
        #expect(bounds.week == midnight.date(from: "2026-09-27T04:00:00Z")!..<midnight.date(from: "2026-10-04T04:00:00Z")!)
        #expect(bounds.month == midnight.date(from: "2026-10-01T04:00:00Z")!..<midnight.date(from: "2026-11-01T04:00:00Z")!)
        #expect(bounds.usual == midnight.date(from: "2026-09-02T04:00:00Z")!..<bounds.today.lowerBound)
        #expect(bounds.earliest == bounds.usual.lowerBound)
        // Thirty calendar days, one of them 25 hours long: 21 October began at 04:00 in UTC.
        let late = Water.Periods.Bounds(midnight.date(from: "2026-11-20T17:00:00Z")!, calendar: Self.calendar)
        #expect(late.usual == midnight.date(from: "2026-10-21T04:00:00Z")!..<midnight.date(from: "2026-11-20T05:00:00Z")!)
    }

    /// The glass of water stands at today's water over a usual day's, the 30 days before today
    /// over 30: today isn't one of them, a day with none counts as a day of none, and a day
    /// past a usual one stays full.
    @Test func theGlassIsTodayAgainstAUsualDay() throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let (config, alpha, _) = try Self.projects()
        defer { try? FileManager.default.removeItem(at: config) }
        let bounds = Water.Periods.Bounds(Self.friday, calendar: Self.calendar)
        let s1 = alpha.appending(path: "s1.jsonl")
        try Data([
            // The first moment of the 30 days, and a moment before it.
            Self.reply("first", 600, at: "2026-09-02T04:00:00.000Z"),
            Self.reply("before", 7000, at: "2026-09-02T03:59:59.999Z"),
            // Thursday in New York, Friday in UTC.
            Self.reply("thursday", 300, at: "2026-10-02T03:00:00.000Z"),
            Self.reply("today", 15, at: "2026-10-02T12:00:00.000Z"),
        ].joined().utf8).write(to: s1)
        var ledger = Water.Ledger()
        ledger.read(config: config, by: definition, periods: bounds)
        var periods = Water.Periods(ledger, in: bounds, by: definition)
        // 900 over 30 days, two of which had any.
        #expect(periods.usualDay?.tokens == Water.Tokens(output: 30))
        #expect(periods.today.tokens == Water.Tokens(output: 15))
        #expect(periods.level == 0.5)
        #expect(!periods.overflowing)

        try Self.append(Self.reply("more", 45, at: "2026-10-02T13:00:00.000Z"), to: s1)
        ledger.read(config: config, by: definition, periods: bounds)
        periods = Water.Periods(ledger, in: bounds, by: definition)
        #expect(periods.today.tokens == Water.Tokens(output: 60))
        #expect(periods.level == 1)
        #expect(periods.overflowing)
    }

    /// With no water in the 30 days before today there's no usual day, and none is made up:
    /// today goes by itself, so any water fills the glass, and none leaves it empty.
    @Test func withNoUsualDayTodayFillsTheGlass() throws {
        let definition = try JSONDecoder().decode(Water.Definition.self, from: Self.madeUp)
        let (config, alpha, _) = try Self.projects()
        defer { try? FileManager.default.removeItem(at: config) }
        let bounds = Water.Periods.Bounds(Self.friday, calendar: Self.calendar)
        var ledger = Water.Ledger()
        ledger.read(config: config, by: definition, periods: bounds)
        var periods = Water.Periods(ledger, in: bounds, by: definition)
        #expect(periods.usualDay == nil)
        #expect(periods.level == 0)

        try Data(Self.reply("today", 1, at: "2026-10-02T12:00:00.000Z").utf8).write(to: alpha.appending(path: "s1.jsonl"))
        ledger.read(config: config, by: definition, periods: bounds)
        periods = Water.Periods(ledger, in: bounds, by: definition)
        #expect(periods.usualDay == nil)
        #expect(periods.level == 1)
        #expect(!periods.overflowing)
    }

    /// From a glass of water the card is the water alone, whatever else the thread has; without
    /// one it is the plan first, as before.
    @Test func theGlassOfWatersCardHasNothingOfThePlan() {
        for context in [false, true] {
            #expect(UsageCard.parts(ofWater: true, context: context) == [.waterByPeriod])
        }
        #expect(UsageCard.parts(ofWater: false, context: true) == [.plan, .context])
        #expect(UsageCard.parts(ofWater: false, context: false) == [.plan])
    }

    /// Mid-turn, the tools' results in one moment share one reading, a moment after the first.
    @Test func toolResultsInOneMomentShareOneReading() async throws {
        let meter = WaterMeter()
        var readings = 0
        for _ in 0..<5 { meter.soon { readings += 1 } }
        #expect(readings == 0)
        await meter.settled()
        #expect(readings == 1)
        meter.soon { readings += 1 }
        await meter.settled()
        #expect(readings == 2)
    }
}
