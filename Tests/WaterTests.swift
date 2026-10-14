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
}
