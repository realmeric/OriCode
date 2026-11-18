import Darwin
import Foundation
import SwiftData
import Testing
@testable import OriCode

@_silgen_name("proc_pid_rusage") private func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer) -> Int32

/// The real engine and the app's reader, with a stand-in Claude that streams at a set rate: what
/// the app is woken for while a reply streams (K-391). Each delta sent as its own line woke the
/// reader, decoded it and touched the main actor; the engine now sends one message a frame, so
/// the app's wakeups follow the display, not the model. Prints the numbers for the card's Notes.
@MainActor
struct WireFramesTests {
    /// CPU in ms, package idle wakeups and interrupt wakeups of a process, from proc_pid_rusage;
    /// times come in mach ticks, 125/3 ns each on Apple silicon.
    private struct Usage {
        var cpuMs: Double
        var idleWakeups: UInt64
        var interruptWakeups: UInt64
        var switches: UInt64

        static func of(_ pid: Int32, switches: UInt64 = 0) -> Usage {
            var info = rusage_info_v4()
            let got = withUnsafeMutablePointer(to: &info) { proc_pid_rusage(pid, 4, UnsafeMutableRawPointer($0)) }
            precondition(got == 0, "no rusage for \(pid)")
            var base = mach_timebase_info()
            mach_timebase_info(&base)
            let ns = Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom)
            return Usage(cpuMs: ns / 1_000_000, idleWakeups: info.ri_pkg_idle_wkups, interruptWakeups: info.ri_interrupt_wkups, switches: switches)
        }

        /// This process, with its context switches from task_info.
        static func ours() -> Usage {
            var events = task_events_info()
            var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &events) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count) }
            }
            return of(getpid(), switches: UInt64(events.csw))
        }

        func since(_ before: Usage) -> Usage {
            Usage(cpuMs: cpuMs - before.cpuMs, idleWakeups: idleWakeups - before.idleWakeups, interruptWakeups: interruptWakeups - before.interruptWakeups, switches: switches - before.switches)
        }
    }

    /// A Claude Code the Agent SDK can run that streams `count` deltas at `rate` a second, then the
    /// reply and the result, and says it's signed in.
    private static func standIn(rate: Int, count: Int) throws -> String {
        let folder = FileManager.default.temporaryDirectory.appending(path: "wire-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "stream.mjs")
        try """
        import { createInterface } from "node:readline";
        const argv = process.argv.slice(2);
        if (argv.includes("--version")) { process.stdout.write("9.9.9 (Claude Code)\\n"); process.exit(0); }
        if (argv[0] === "auth") { process.stdout.write('{"loggedIn": true}\\n'); process.exit(0); }
        const rate = \(rate), count = \(count), session = "stream";
        const send = (m) => process.stdout.write(JSON.stringify({ session_id: session, uuid: crypto.randomUUID(), ...m }) + "\\n");
        const usage = { input_tokens: 1, output_tokens: 1, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 };
        createInterface({ input: process.stdin }).on("line", (line) => {
          const message = JSON.parse(line);
          if (message.type === "control_request") { send({ type: "control_response", response: { subtype: "success", request_id: message.request_id, response: {} } }); return; }
          if (message.type !== "user") return;
          send({ type: "system", subtype: "init", cwd: process.cwd(), tools: [], model: "stand-in", permissionMode: "default", capabilities: [] });
          const id = crypto.randomUUID();
          send({ type: "stream_event", parent_tool_use_id: null, event: { type: "message_start", message: { id } } });
          let sent = 0, text = "";
          const start = performance.now();
          const tick = () => {
            const due = Math.min(count, Math.floor(((performance.now() - start) / 1000) * rate) + 1);
            while (sent < due) { const word = `w${sent} `; text += word; sent += 1; send({ type: "stream_event", parent_tool_use_id: null, event: { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: word } } }); }
            if (sent < count) { setTimeout(tick, Math.max(1, 1000 / rate)); return; }
            send({ type: "assistant", parent_tool_use_id: null, message: { id, type: "message", role: "assistant", model: "stand-in", content: [{ type: "text", text }], stop_reason: "end_turn", usage } });
            send({ type: "result", subtype: "success", is_error: false, num_turns: 1, duration_ms: 10, duration_api_ms: 10, total_cost_usd: 0, result: text, usage, modelUsage: {}, permission_denials: [] });
          };
          tick();
        });
        """.write(to: script, atomically: true, encoding: .utf8)
        let node = try FileManager.default.destinationOfSymbolicLink(atPath: "/opt/homebrew/bin/node")
        let cli = folder.appending(path: "claude")
        try "#!/bin/sh\nexec \"\(node.hasPrefix("/") ? node : "/opt/homebrew/bin/" + node)\" \"\(script.path)\" \"$@\"\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return cli.path
    }

    private struct Run {
        var rate: Int
        var messages: Int
        var seconds: Double
        var firstWordMs: Double
        var app: Usage
        var engine: Usage
        var text: String
    }

    /// One reply of `rate` deltas a second for `seconds`, through the engine into a Conversation on
    /// the main actor with a frame every 16 ms, as the app does, measured over the stream.
    private func stream(rate: Int, seconds: Int) async throws -> Run {
        let count = rate * seconds
        setenv("ORICODE_CLAUDE", try Self.standIn(rate: rate, count: count), 1)
        let container = try TestStore.memory()
        let project = Project(name: "alpha", path: NSTemporaryDirectory())
        container.mainContext.insert(project)
        let chat = Chat(project: project)
        chat.started = true
        container.mainContext.insert(chat)
        try container.mainContext.save()
        let conversation = Conversation(chat: chat, context: container.mainContext)
        let clock = StreamClock(manual: true)
        conversation.clock = clock
        conversation.userSent("Go")

        let engine = Engine()
        try await engine.start(nodeOverride: nil)
        let pid = await engine.processIdentifier!
        let threadId = chat.id.uuidString
        let sentAt = ContinuousClock.now
        var first: ContinuousClock.Instant?
        var last = sentAt
        var messages = 0
        var appBefore = Usage.ours(), engineBefore = Usage.of(pid)
        let frames = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                clock.tick()
            }
        }
        let listening = Task { @MainActor in
            for await output in engine.output {
                guard case .event(let event) = output, event.threadId == threadId else { continue }
                if event.name == "text" {
                    if first == nil {
                        first = .now
                        appBefore = .ours()
                        engineBefore = .of(pid)
                    }
                    messages += 1
                    last = .now
                }
                conversation.receive(event)
                if event.name == "turn.done" { return }
            }
        }
        _ = try await engine.request("send", ["threadId": .string(threadId), "cwd": .string(NSTemporaryDirectory()), "text": "Stream", "permissionMode": "default"])
        await listening.value
        let app = Usage.ours().since(appBefore), engineUsage = Usage.of(pid).since(engineBefore)
        frames.cancel()
        for _ in 0..<3 { clock.tick() }
        await engine.stop()
        let text = conversation.items.compactMap(\.text).last ?? ""
        return Run(rate: rate, messages: messages, seconds: (first ?? last).duration(to: last) / .seconds(1), firstWordMs: sentAt.duration(to: first ?? last) / .milliseconds(1), app: app, engine: engineUsage, text: text)
    }

    @Test func aStreamWakesTheAppAboutOnceAFrameWhateverItsRate() async throws {
        var lines = ["rate  msgs/s  first word  app cpu  app idle wkups/s  app intr wkups/s  app csw/s  engine cpu"]
        for rate in [200, 500, 1000] {
            let run = try await stream(rate: rate, seconds: 2)
            let expected = (0..<(rate * 2)).map { "w\($0) " }.joined()
            #expect(run.text == expected, "every word, in order, at \(rate)/s")
            let perSecond = Double(run.messages) / run.seconds
            #expect(perSecond <= 75, "\(perSecond) messages a second at \(rate) deltas a second")
            #expect(run.firstWordMs < 1500)
            lines.append(String(format: "%4.0f  %6.0f  %7.0f ms  %5.0f ms  %16.0f  %16.0f  %9.0f  %7.0f ms", Double(rate), perSecond, run.firstWordMs, run.app.cpuMs,
                                Double(run.app.idleWakeups) / run.seconds, Double(run.app.interruptWakeups) / run.seconds, Double(run.app.switches) / run.seconds, run.engine.cpuMs))
        }
        print("WIRE FRAMES, \(2) s of stream each:\n" + lines.joined(separator: "\n"))
    }
}
