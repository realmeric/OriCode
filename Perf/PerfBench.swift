import AppKit
import MarkdownUI
import SwiftData
import SwiftUI

/// The measures behind `make perf`, compiled into OriCode Perf alone: each part stages a thread,
/// a review or ⌘K in a window on screen, drives it with the events a hand would send and writes
/// what the main thread spent, a frame at a time, and what the clock said inside a key or a
/// delta, to results.txt in PERF_OUT. scripts/perf runs the parts, each in a fresh process, and
/// judges the numbers against Perf/budgets.json. No part sends a turn: replies are engine events
/// made here, and the engine is up only where a review needs git read.
@MainActor
enum PerfBench {
    nonisolated static let folder = URL(filePath: ProcessInfo.processInfo.environment["PERF_OUT"] ?? NSHomeDirectory() + "/Library/Developer/OriCode/perf")
    static let shots = folder.appending(path: "shots")
    static var label = ""
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    /// The app's own model, for the seed and launch parts.
    static var appModel: AppModel?

    static func startIfAsked() {
        if env["PERF_LAUNCH"] != nil { watchLaunch() }
        if let after = env["PERF_HIDE"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { NSApp.hide(nil) }
        }
        guard let label = env["PERF_BENCH"] else { return }
        Self.label = label
        let parts = (env["PERF_PARTS"] ?? "").split(separator: " ").map(String.init)
        UserDefaults.standard.set(false, forKey: "notify")
        // The design is kept in the defaults, so a part that says nothing would draw what the last run chose.
        UserDefaults.standard.set((env["PERF_DESIGN"]?.hasPrefix("legacy") == true ? ReviewDesign.legacy : .witness).rawValue, forKey: ReviewDesign.key)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if !parts.contains("seed") { for window in NSApp.windows where window.identifier?.rawValue != "bench" { window.orderOut(nil) } }
            log(String(format: "start: refresh %.1f ms, parts %@, pair %@, book %@, design %@, footprint %.1f MB", refresh * 1000, parts.joined(separator: " "),
                       env["PERF_PAIR"] ?? "0", env["PERF_BOOK"] ?? "-", env["PERF_DESIGN"] ?? "-", footprint()))
            for part in parts {
                do {
                    switch part {
                    case "stream": try await stream()
                    case "codesettle": try await codeSettle()
                    case "keys": try await keys()
                    case "scroll": try await scroll()
                    case "edits": try await edits()
                    case "switch": try await switching()
                    case "review": try await review()
                    case "jwalk": try await jwalk()
                    case "palette": try await palette()
                    case "mem": try await memory()
                    case "seed": try await seedStore()
                    case "earlyj": try await earlyJ()
                    case "backstep": try await backStep()
                    default: log("unknown part \(part)")
                    }
                } catch {
                    log("\(part) failed: \(error)")
                }
            }
            exit(0)
        }
    }

    static var pair: Bool { env["PERF_PAIR"] == "1" }

    static func log(_ line: String) {
        let text = "[\(label)] \(line)\n"
        let file = folder.appending(path: "results.txt")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    static var refresh: Double { NSScreen.main?.minimumRefreshInterval ?? 1.0 / 60 }

    /// The main thread's CPU time so far, in milliseconds.
    static func cpu() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        return Double(info.user_time.seconds + info.system_time.seconds) * 1000
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1000
    }

    /// The clock, in milliseconds. A key that waits on the disk, a lock or the engine spends none
    /// of the main thread's CPU, so what is timed inside a key or a delta is timed by both.
    static func clock() -> Double { CACurrentMediaTime() * 1000 }

    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    struct Summary {
        let cpu: [Double]
        let gaps: [Double]
        var frame = 1000.0 / 60
        var dropped: Int { gaps.map { max(0, Int(($0 / frame).rounded()) - 1) }.reduce(0, +) }
        var worst: Double { cpu.max() ?? 0 }
        var text: String {
            let sorted = cpu.sorted()
            let p = { (q: Double) in sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            return String(format: "frames %d, main %.0f ms in all, median %.2f, p95 %.2f, worst %.1f, over 16.7ms %d, over 8.3ms %d; worst gap %.1f ms, frames dropped %d",
                          cpu.count, cpu.reduce(0, +), p(0.5), p(0.95), sorted.last ?? 0, cpu.count { $0 > 16.7 }, cpu.count { $0 > 8.3 },
                          gaps.max() ?? 0, dropped)
        }
        var heavy: String { cpu.filter { $0 > 1 }.map { String(format: "%.1f", $0) }.joined(separator: " ") }
        /// Which frames were long, each as its number and its milliseconds.
        var long: String { cpu.enumerated().filter { $1 > 12 }.map { String(format: "%d:%.1f", $0, $1) }.joined(separator: " ") }
    }

    static func settle(_ ms: Int = 400) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    static func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(seconds)
        while Date.now < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    /// The window as the screen has it: asked of a shell outside (scripts/perf/watch.sh), and skipped when none is watching.
    static func screenshot(_ window: NSWindow, _ name: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = shots.appending(path: name + ".png")
        try? FileManager.default.removeItem(at: file)
        let marker = folder.appending(path: "shoot-now")
        guard FileManager.default.fileExists(atPath: folder.appending(path: "watching").path) else { return }
        try? "\(window.windowNumber) \(file.path)".write(to: marker, atomically: true, encoding: .utf8)
        let limit = Date.now.addingTimeInterval(4)
        while Date.now < limit, FileManager.default.fileExists(atPath: marker.path) { Thread.sleep(forTimeInterval: 0.02) }
    }

    /// The app active and the window key, as a key press needs it.
    static func front(_ window: NSWindow) async {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        if !NSApp.isActive {
            // macOS refuses an app that asks to come forward by itself while another is in use; `open` on
            // the bundle already running is let through, as a click on its Dock icon is.
            let open = Process()
            open.executableURL = URL(filePath: "/usr/bin/open")
            open.arguments = [Bundle.main.bundlePath]
            try? open.run()
            for _ in 0..<30 where !NSApp.isActive { try? await Task.sleep(for: .milliseconds(100)) }
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
        }
        log("front: app active \(NSApp.isActive), window key \(window.isKeyWindow), on screen \(window.occlusionState.contains(.visible))")
    }

    @discardableResult
    static func sh(_ line: String, in folder: String) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", line]
        process.currentDirectoryURL = URL(filePath: folder)
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "Bench"
        environment["GIT_AUTHOR_EMAIL"] = "bench@example.com"
        environment["GIT_COMMITTER_NAME"] = "Bench"
        environment["GIT_COMMITTER_EMAIL"] = "bench@example.com"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: The model's own switches

    static func beside(_ model: AppModel, _ other: UUID) { model.besideChatID = other }
    static func alone(_ model: AppModel) { model.besideChatID = nil }

    /// The review drawn as Witness or as Legacy; legacyall is Legacy with every file open, as 0.3.3 opened it.
    static func use(_ design: String, _ model: AppModel) {
        let chosen: ReviewDesign = design == "witness" ? .witness : .legacy
        UserDefaults.standard.set(chosen.rawValue, forKey: ReviewDesign.key)
        model.review.design = chosen
    }

    static func arrange(_ design: String, _ model: AppModel) {
        let review = model.review
        review.selected = nil
        if design == "legacyall" {
            review.openFiles = Set(review.book.chapters.flatMap(\.files).map(\.id))
            review.placed = true
        } else {
            review.openFiles = []
            review.placed = false
        }
    }

    static func describe(_ model: AppModel) -> String { "design \(model.review.design.rawValue)" }

    /// What a quit leaves in the defaults for the next launch to open.
    static func kept() -> String {
        let kept = UserDefaults.standard
        return "selectedProject \(kept.string(forKey: "selectedProject") ?? "-") selectedChat \(kept.string(forKey: "selectedChat") ?? "-") besideChat \(kept.string(forKey: "besideChat") ?? "-")"
    }

    // MARK: Threads

    static let code = (0..<40).map { i in "    let value\(i) = items.filter { $0.id == \(i) }.map(\\.name).joined(separator: \", \") // step \(i)" }.joined(separator: "\n")
    static let para = "Here is what changed in `Conversation.swift` and why. The **transcript** keeps the last 200 items, and each *delta* replaces the open item.\n\n- First point about the `record` function and its flush\n- Second point with a [link](App/Foo.swift) and more words to wrap the line nicely\n- Third point\n\n"
    static let block = "### A heading\n\n" + para + "```swift\nfunc example() {\n" + code + "\n}\n```\n\n"
    /// K-164's bench reply.
    static func message(_ chars: Int) -> String {
        var s = ""
        while s.count < chars { s += block }
        return String(s.prefix(chars))
    }

    /// One realistic turn: a message, thinking, a Read, a Bash, an Edit with its patch, a reply with code, the footer.
    static func turn(_ n: Int, cwd: String) -> [(String, JSON)] {
        let file = "App/File\(n % 17).swift"
        let source = (0..<60).map { "\($0 + 1)\tfunc line\($0)() -> Int { return \($0) * 2 } // \(file)" }.joined(separator: "\n")
        let output = (0..<20).map { "✔ test \($0) passed (\($0 * 3)ms)" }.joined(separator: "\n")
        let old = "    let a = read(git)\n    let b = read(git)"
        let new = "    let both = readOnce(git)"
        let patch: JSON = [["oldStart": 40, "newStart": 40, "lines": [" func review() {", "-    let a = read(git)", "-    let b = read(git)", "+    let both = readOnce(git)", " }"]]]
        let reply = "Done. The review now reads git once in `\(file)`.\n\n" + para + "```swift\nfunc review() {\n    let both = readOnce(git)\n" + (0..<12).map { "    step\($0)(both)" }.joined(separator: "\n") + "\n}\n```\n\nTests pass."
        return [
            ("user", ["event": "user", "text": .string("Turn \(n): make the review read git once, and check \(file) for the old path.")]),
            ("thinking", ["event": "thinking", "delta": .string(String(repeating: "Looking at how the review reads git. ", count: 8))]),
            ("text", ["event": "text", "delta": .string("I'll read \(file) first.")]),
            ("tool.use", ["event": "tool.use", "toolUseId": .string("r\(n)"), "name": "Read", "input": ["file_path": .string(cwd + "/" + file)]]),
            ("tool.result", ["event": "tool.result", "toolUseId": .string("r\(n)"), "content": .string(source)]),
            ("tool.use", ["event": "tool.use", "toolUseId": .string("b\(n)"), "name": "Bash", "input": ["command": "swift test --filter Review", "description": "Run the review tests"]]),
            ("tool.result", ["event": "tool.result", "toolUseId": .string("b\(n)"), "content": .string(output)]),
            ("tool.use", ["event": "tool.use", "toolUseId": .string("e\(n)"), "name": "Edit", "input": ["file_path": .string(cwd + "/" + file), "old_string": .string(old), "new_string": .string(new)]]),
            ("tool.result", ["event": "tool.result", "toolUseId": .string("e\(n)"), "content": "The file has been updated.", "patch": patch]),
            ("text", ["event": "text", "delta": .string(reply)]),
            ("turn.done", ["event": "turn.done", "durationMs": 42000, "costUSD": .number(0.12), "stopReason": "end_turn"]),
        ]
    }

    static func seed(_ context: ModelContext, _ project: Project, title: String, turns: Int, reply: String? = nil, ask: Bool = true) throws -> Chat {
        let chat = Chat(project: project, title: title)
        chat.started = true
        context.insert(chat)
        var events: [(Int, String, JSON)] = []
        for n in 0..<turns { events += turn(n, cwd: project.path).map { (n + 1, $0.0, $0.1) } }
        if ask { events.append((turns + 1, "user", ["event": "user", "text": "Write it"])) }
        if let reply { events.append((turns + 1, "text", ["event": "text", "delta": .string(reply)])) }
        for (seq, (turnNumber, kind, body)) in events.enumerated() {
            let event = Event(turn: turnNumber, seq: seq, kind: kind, payload: try body.data())
            context.insert(event)
            event.chat = chat
        }
        return chat
    }

    /// Two threads in one project, the first open; with PERF_PAIR the second is beside it.
    static func two(_ a: Int, _ b: Int, replies: Bool = false) throws -> (Stage, UUID, UUID) {
        var second: Chat?
        let stage = try Stage { context, project in
            second = try seed(context, project, title: "Check the engine's idle timer", turns: b, reply: replies ? message(700) : nil)
            return try seed(context, project, title: "Make the review read git once", turns: a, reply: replies ? message(1100) : nil)
        }
        let other = second!.id
        if pair { beside(stage.model, other) }
        return (stage, stage.chat.id, other)
    }

    static var gap: Int { env["PERF_GAP"].flatMap(Int.init) ?? 100 }

    /// K-164's bench reply, 40 characters into each of the threads on every beat.
    /// A beat's cost is the main thread's CPU until the next; `waited` is the clock inside the delta's own delivery.
    static func play(_ stage: Stage, into ids: [UUID], every: Int, text: String) async throws -> (costs: [Double], waited: [Double]) {
        let chars = Array(text)
        var costs: [Double] = []
        var waited: [Double] = []
        var last = cpu()
        var i = 0
        while i < chars.count, !Task.isCancelled {
            let began = clock()
            for id in ids { stage.send("text", ["delta": .string(String(chars[i..<min(i + 40, chars.count)]))], to: id) }
            waited.append(clock() - began)
            try await Task.sleep(for: .milliseconds(every))
            let now = cpu()
            costs.append(now - last)
            last = now
            i += 40
        }
        return (costs, waited)
    }

    // MARK: A turn streaming

    /// K-164's bench reply into the open thread, with nothing behind it and with 100 turns, then
    /// the frame it settles in when a tool call follows. PERF_BOTH streams into both of a pair.
    static func stream() async throws {
        let both = env["PERF_BOTH"] == "1"
        for turns in [0, 100] {
            let (stage, a, b) = try two(turns, 25)
            defer { stage.window.close() }
            await front(stage.window)
            try await settle(1800)
            let ids = both ? [a, b] : [a]
            for id in ids { stage.send("turn.started", [:], to: id) }
            try await settle(100)
            let start = cpu()
            let frames = Frames(stage.window.contentView!)
            // PERF_END=para: the reply ends with a whole paragraph, as most do, and not inside a code block.
            let head = ("### A heading\n\n" + para).count
            let text = env["PERF_END"] == "para" ? message((12_000 - head) / block.count * block.count + head) : message(12_000)
            let (costs, waited) = try await play(stage, into: ids, every: 10, text: text)
            // PERF_GAP: how long nothing happens before the tool call, 100 ms unless said.
            try await settle(gap)
            let streamed = frames.stop()
            let name = pair ? (both ? "into both of a pair" : "into the open one of a pair") : "into one thread"
            log(String(format: "STREAM %@ (%d turns behind) 12000 chars in %d beats every 10ms: %.2f ms a beat, last 30 %.2f, worst %.1f; by the clock %.3f ms inside a delta (worst %.2f); %@; columns %@",
                       name, turns, costs.count, (cpu() - start) / Double(costs.count), costs.suffix(30).reduce(0, +) / 30, costs.max() ?? 0,
                       waited.reduce(0, +) / Double(waited.count), waited.max() ?? 0, streamed.text, stage.state()))
            log("LONGFRAMES \(name) (\(turns) turns behind), of \(streamed.cpu.count): \(streamed.long)")
            let settling = Frames(stage.window.contentView!)
            let before = cpu()
            for id in ids { stage.send("tool.use", ["toolUseId": "t1", "name": "Read", "input": ["file_path": "/tmp/a.swift"]], to: id) }
            try await settle(300)
            let settled = settling.stop()
            log(String(format: "SETTLE %@ (%d turns behind): %.1f ms in 300ms; worst frame %.1f; %@; frames %@", name, turns, cpu() - before, settled.worst, settled.text, settled.heavy))
            if env["PERF_SHOTS"] == "1" {
                for id in ids { stage.send("turn.done", ["durationMs": 1000, "costUSD": 0, "stopReason": "end_turn"], to: id) }
                try await settle(600)
                screenshot(stage.window, "\(label)-settled-\(turns)")
            }
            if turns == 100 { screenshot(stage.window, "\(label)-stream") }
        }
    }

    /// A reply that ends inside a long code block, 120 lines of it still open, and the frame the
    /// tool call after it costs: K-165's settle.
    static func codeSettle() async throws {
        let open = "Here is the whole function, as asked.\n\n" + para + "```swift\nfunc example() {\n" + (0..<3).map { _ in code }.joined(separator: "\n")
        for round in 0..<3 {
            // PERF_FRESH: code no round has had, so its colours are never in hand when it settles, as a reply's own aren't.
            let open = env["PERF_FRESH"] == "1" ? open.replacingOccurrences(of: "value", with: "round\(round)") : open
            let (stage, a, _) = try two(25, 25)
            defer { stage.window.close() }
            await front(stage.window)
            try await settle(1800)
            stage.send("turn.started", [:], to: a)
            try await settle(100)
            let start = cpu()
            let frames = Frames(stage.window.contentView!)
            let costs = try await play(stage, into: [a], every: 10, text: open).costs
            try await settle(gap)
            let streamed = frames.stop()
            log(String(format: "CODESTREAM %d, %d chars ending in an open block of 120 lines: %.2f ms a beat, worst %.1f; %@", round, open.count,
                       (cpu() - start) / Double(costs.count), costs.max() ?? 0, streamed.text))
            let settling = Frames(stage.window.contentView!)
            let before = cpu()
            stage.send("tool.use", ["toolUseId": "t1", "name": "Read", "input": ["file_path": "/tmp/a.swift"]], to: a)
            try await settle(300)
            let settled = settling.stop()
            log(String(format: "CODESETTLE %d: %.1f ms in 300ms; worst frame %.1f; %@; frames %@", round, cpu() - before, settled.worst, settled.text, settled.heavy))
            let ending = Frames(stage.window.contentView!)
            stage.send("turn.done", ["durationMs": 1000, "costUSD": 0, "stopReason": "end_turn"], to: a)
            try await settle(400)
            let ended = ending.stop()
            log(String(format: "CODEDONE %d, the turn ends: worst frame %.1f; %@; frames %@", round, ended.worst, ended.text, ended.heavy))
            // What the settled reply costs once nothing moves: two seconds of the main thread, after one to come to rest.
            try await settle(1000)
            let idle = cpu()
            try await settle(2000)
            log(String(format: "CODEIDLE %d, two seconds after the turn: main %.2f ms", round, cpu() - idle))
        }
    }

    // MARK: Typing

    /// A key every 50ms in the composer: with nothing streaming, then while a reply streams into
    /// the one thread there is, or with a pair into the thread beside the one written in.
    static func keys() async throws {
        let (stage, a, b) = try two(100, 25)
        defer { stage.window.close() }
        await front(stage.window)
        try await settle(1800)
        guard try await stage.focusComposer() else { return log("keys: the composer never took the keyboard") }
        let target = pair ? b : a
        for streaming in [false, true] {
            var player: Task<Void, Error>?
            if streaming {
                stage.send("turn.started", [:], to: target)
                try await settle(100)
                player = Task { _ = try await play(stage, into: [target], every: 10, text: message(16_000)) }
                try await settle(300)
            }
            var sync: [Double] = []
            var waited: [Double] = []
            var longest: [Double] = []
            let all = Frames(stage.window.contentView!)
            for character in "make the review grow out of it and keep going" {
                let frames = Frames(stage.window.contentView!)
                let before = cpu()
                let began = clock()
                stage.press(String(character))
                waited.append(clock() - began)
                sync.append(cpu() - before)
                try await Task.sleep(for: .milliseconds(50))
                longest.append(frames.stop().cpu.max() ?? 0)
            }
            let summary = all.stop()
            player?.cancel()
            let sorted = sync.sorted()
            log(String(format: "KEYS %@, %@: %d keys, %.2f ms inside the key (median %.2f, worst %.1f), by the clock %.2f (worst %.1f); longest frame after a key %.2f on average (worst %.1f); %@",
                       pair ? "a pair" : "one thread", streaming ? (pair ? "the other streaming" : "its own reply streaming") : "nothing streaming",
                       sync.count, sync.reduce(0, +) / Double(sync.count), sorted[sorted.count / 2], sorted.last ?? 0,
                       waited.reduce(0, +) / Double(waited.count), waited.max() ?? 0,
                       longest.reduce(0, +) / Double(longest.count), longest.max() ?? 0, summary.text))
            try await settle(300)
        }
        log("keys: the composer reads \(stage.typed().count) characters")
        screenshot(stage.window, "\(label)-keys")
    }

    // MARK: Scrolling

    static func wheel(_ stage: Stage, _ view: NSScrollView, _ step: Double, ticks: Int, decay: Double = 1, _ what: String) async throws {
        var speed = step
        let frames = Frames(stage.window.contentView!)
        let done = Ticker(stage.window.contentView!, ticks: ticks) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(speed), wheel2: 0, wheel3: 0),
                  let ns = NSEvent(cgEvent: event)
            else { return }
            view.scrollWheel(with: ns)
            speed *= decay
        }
        try await done.wait()
        let summary = frames.stop()
        try await settle(300)
        let pointer = stage.window.frame.contains(NSEvent.mouseLocation) ? "; pointer over the window" : ""
        log("\(what): y \(Int(view.contentView.bounds.origin.y)) of \(Int(view.documentView?.frame.height ?? 0)); \(summary.text)\(pointer)")
    }

    /// The open thread's column, 100 turns of it, by wheel and by flick; with a pair, a second
    /// column stands beside it.
    static func scroll() async throws {
        let (stage, _, _) = try two(100, 25)
        defer { stage.window.close() }
        await front(stage.window)
        try await settle(2500)
        guard let view = stage.transcripts().first else { return log("scroll: no transcript found") }
        let who = pair ? "a pair" : "one thread"
        for round in 1...2 {
            try await wheel(stage, view, 20, ticks: 180, "SCROLL \(who), round \(round), wheel 20pt a frame up for 3 s")
            try await wheel(stage, view, 90, ticks: 120, "SCROLL \(who), round \(round), wheel 90pt a frame up for 2 s")
            try await wheel(stage, view, -700, ticks: 90, decay: 0.95, "SCROLL \(who), round \(round), flick down, 700pt a frame dying away")
            try await wheel(stage, view, 700, ticks: 90, decay: 0.95, "SCROLL \(who), round \(round), flick up, 700pt a frame dying away")
            try await wheel(stage, view, -2000, ticks: 40, "SCROLL \(who), round \(round), back to the end")
        }
        screenshot(stage.window, "\(label)-scroll")
    }

    /// An edit's patch: one to three hunks, replaced lines, added lines and a removal (K-256's).
    static func patch(_ index: Int) -> JSON {
        var hunks: [JSON] = []
        for hunk in 0...(index % 3) {
            let start = 10 + hunk * 60 + index
            var lines: [String] = [" func step\(index)(_ items: [Item]) -> [String] {", "     let first = items.first"]
            lines.append("-    let kept = items.filter { $0.id > \(index) && !$0.name.isEmpty && $0.isShown }")
            lines.append("+    let kept = items.filter { $0.id > \(index) && !$0.name.isEmpty }")
            for extra in 0..<(2 + (index + hunk) % 9) { lines.append("+    let value\(extra) = kept.map(\\.name).sorted()[\(extra)] // added in edit \(index)") }
            if (index + hunk) % 4 == 0 { for gone in 0..<9 { lines.append("-    // an old line \(gone) of the function that went") } }
            lines += ["     return kept.map(\\.name)", " }"]
            hunks.append(["oldStart": .number(Double(start)), "newStart": .number(Double(start + hunk * 3)), "lines": .array(lines.map(JSON.string))])
        }
        return .array(hunks)
    }

    /// Ninety edits, each between two lines of the agent's, all of them rows (under the 200 the
    /// transcript shows): on main each is a diff card of its own.
    static func editsStage() throws -> Stage {
        try Stage { context, project in
            let chat = Chat(project: project, title: "Ninety edits", permissionMode: "bypassPermissions")
            chat.started = true
            context.insert(chat)
            var seq = 0
            let start = Date.now.addingTimeInterval(-7200)
            func add(_ kind: String, _ body: JSON) throws {
                let event = Event(turn: 1, seq: seq, kind: kind, payload: try body.data())
                event.createdAt = start.addingTimeInterval(Double(seq))
                seq += 1
                context.insert(event)
                event.chat = chat
            }
            try add("user", ["event": "user", "text": "Move the composer's draft into the store, a file at a time"])
            for index in 0..<90 {
                try add("text", ["event": "text", "delta": .string("Edit \(index + 1): `File\(index % 7).swift` keeps its draft by thread now.")])
                let id = "e\(index)"
                try add("tool.use", ["event": "tool.use", "toolUseId": .string(id), "name": "Edit", "input": ["file_path": .string(project.path + "/App/File\(index % 7).swift"), "old_string": "a", "new_string": "b"]])
                try add("tool.result", ["event": "tool.result", "toolUseId": .string(id), "content": "ok", "isError": false, "patch": patch(index)])
            }
            try add("turn.done", ["event": "turn.done", "durationMs": 1000, "costUSD": 0, "stopReason": "end_turn"])
            return chat
        }
    }

    static func edits() async throws {
        let stage = try editsStage()
        defer { stage.window.close() }
        if let design = env["PERF_DESIGN"] { use(design, stage.model) }
        await front(stage.window)
        try await settle(3000)
        guard let view = stage.transcripts().first else { return log("edits: no transcript found") }
        log("EDITS: \(stage.model.conversation(for: stage.chat).items.count) items, document \(Int(view.documentView?.frame.height ?? 0)) pt, footprint \(String(format: "%.1f", footprint())) MB")
        for round in 1...2 {
            try await wheel(stage, view, 40, ticks: 240, "EDITS round \(round), wheel 40pt a frame up for 4 s")
            try await wheel(stage, view, 160, ticks: 180, "EDITS round \(round), wheel 160pt a frame up for 3 s")
            try await wheel(stage, view, -700, ticks: 90, decay: 0.95, "EDITS round \(round), flick down, 700pt a frame dying away")
            try await wheel(stage, view, 700, ticks: 90, decay: 0.95, "EDITS round \(round), flick up, 700pt a frame dying away")
            if round == 1 { screenshot(stage.window, "\(label)-edits") }
            try await wheel(stage, view, -3000, ticks: 60, "EDITS round \(round), back to the end")
        }
        log("EDITS: footprint after \(String(format: "%.1f", footprint())) MB")
    }

    // MARK: Switching

    static func switching() async throws {
        var ids: [UUID] = []
        let stage = try Stage { context, project in
            let long = try seed(context, project, title: "Long", turns: 100)
            let mid = try seed(context, project, title: "Mid", turns: 25)
            let short = try seed(context, project, title: "Short", turns: 3)
            let other = try seed(context, project, title: "Other", turns: 1)
            ids = [long.id, mid.id, short.id, long.id, mid.id, other.id, short.id, long.id, short.id, long.id]
            return other
        }
        defer { stage.window.close() }
        await front(stage.window)
        try await settle(1500)
        var seen: Set<UUID> = []
        for (index, id) in ids.enumerated() {
            let frames = Frames(stage.window.contentView!)
            let before = cpu()
            stage.model.selectedChatID = id
            try await settle(700)
            let title = (try? stage.model.context.fetch(FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })).first?.title) ?? "?"
            let switched = frames.stop()
            log(String(format: "SWITCH %d to %@ (%@): %.1f ms main in 700ms; worst frame %.1f; %@; frames %@", index, title, seen.contains(id) ? "again" : "first open",
                       cpu() - before, switched.worst, switched.text, switched.heavy))
            seen.insert(id)
        }
    }

    // MARK: ⌘K

    static func palette() async throws {
        let stage = try Stage { context, project in
            for n in 0..<30 { _ = try seed(context, project, title: "Thread \(n) about the review's git read", turns: 6) }
            return try seed(context, project, title: "Long", turns: 100)
        }
        defer { stage.window.close() }
        await front(stage.window)
        try await settle(2000)
        let model = stage.model
        for round in 0..<4 {
            var frames = Frames(stage.window.contentView!)
            var before = cpu()
            model.toggleCommandCenter()
            try await settle(700)
            var summary = frames.stop()
            log(String(format: "PALETTE open %d: %.1f ms main in 700ms; worst frame %.1f; %@; frames %@", round, cpu() - before, summary.worst, summary.text, summary.heavy))
            var sync: [Double] = []
            var waited: [Double] = []
            var longest: [Double] = []
            frames = Frames(stage.window.contentView!)
            var typed = ""
            for character in "review git" {
                let one = Frames(stage.window.contentView!)
                before = cpu()
                let began = clock()
                typed.append(character)
                model.palette.level.query = typed
                waited.append(clock() - began)
                sync.append(cpu() - before)
                try await Task.sleep(for: .milliseconds(80))
                longest.append(one.stop().cpu.max() ?? 0)
            }
            summary = frames.stop()
            log(String(format: "PALETTE search %d, \"review git\" a letter every 80ms over 31 threads: %.2f ms inside a letter, by the clock %.2f; longest frame after a letter %.2f on average (worst %.1f); %@",
                       round, sync.reduce(0, +) / Double(sync.count), waited.reduce(0, +) / Double(waited.count),
                       longest.reduce(0, +) / Double(longest.count), longest.max() ?? 0, summary.text))
            log("PALETTE letters \(round): " + longest.map { String(format: "%.1f", $0) }.joined(separator: " "))
            if round == 0 { screenshot(stage.window, "\(label)-palette") }
            try await settle(600)
            frames = Frames(stage.window.contentView!)
            before = cpu()
            if model.commandCenterShown { model.toggleCommandCenter() }
            try await settle(600)
            summary = frames.stop()
            log(String(format: "PALETTE close %d: %.1f ms main; worst frame %.1f; %@", round, cpu() - before, summary.worst, summary.text))
        }
    }

    // MARK: The review

    static func swiftFile(_ name: String, lines: Int) -> [String] {
        var out = ["import Foundation", "", "struct \(name) {"]
        var index = 0
        while out.count < lines - 1 {
            out.append("    func step\(index)(_ items: [Item]) -> [String] {")
            out.append("        let kept = items.filter { $0.id > \(index) && !$0.name.isEmpty }")
            out.append("        guard kept.count > \(index % 7), let first = kept.first else { return [] }")
            out.append("        return kept.map(\\.name).sorted() + [first.name, \"step \(index)\"] // \(name) \(index)")
            out.append("    }")
            out.append("")
            index += 1
        }
        out.append("}")
        return out
    }

    /// K-252's repository: a commit and a working tree that differs from it.
    static func repository(files: Int, hunks: Int, each: Int, fresh: Int, freshLines: Int) throws -> (String, [String]) {
        let repo = NSTemporaryDirectory() + "oricode-perf-\(UUID().uuidString.prefix(6))"
        let manager = FileManager.default
        try manager.createDirectory(atPath: repo + "/App", withIntermediateDirectories: true)
        try manager.createDirectory(atPath: repo + "/Tests", withIntermediateDirectories: true)
        var texts: [String: [String]] = [:]
        for index in 0..<files {
            let name = "File\(index)"
            texts["App/\(name).swift"] = swiftFile(name, lines: max(120, hunks * 30))
        }
        texts["Tests/FileTests.swift"] = ["import Testing", "", "@Test func total() {", "    let price = 3", "    #expect(price * 4 == 12)", "    #expect(price > 0, \"a price\")", "}"]
        texts["Package.resolved"] = ["{", "  \"pins\" : [", "    { \"identity\" : \"swiftterm\", \"revision\" : \"aaaa\" }", "  ]", "}"]
        texts["Makefile"] = ["test:", "\t@echo \"ran 12 tests\"", ""]
        for (path, lines) in texts { try lines.joined(separator: "\n").appending("\n").write(toFile: repo + "/" + path, atomically: true, encoding: .utf8) }
        sh("git init -q -b main && git add -A && GIT_COMMITTER_DATE=@\(Int(Date.now.timeIntervalSince1970) - 3600) git commit -q -m start", in: repo)
        var changed: [String] = []
        for index in 0..<files {
            let path = "App/File\(index).swift"
            var lines = texts[path]!
            for hunk in 0..<hunks {
                let at = 4 + hunk * 30
                guard at + each < lines.count else { break }
                for offset in 0..<each {
                    let line = lines[at + offset]
                    if index == 0, hunk == 0, offset == 0 {
                        lines[at] = "        let kept = items.filter { $0.id > 0 }"
                    } else if offset % 3 == 2 {
                        lines[at + offset] = line + "\n        // added in hunk \(hunk)"
                    } else {
                        lines[at + offset] = line.replacingOccurrences(of: "kept", with: "held").replacingOccurrences(of: "step", with: "pace")
                    }
                }
            }
            try lines.joined(separator: "\n").appending("\n").write(toFile: repo + "/" + path, atomically: true, encoding: .utf8)
            changed.append(path)
        }
        try ["import Testing", "", "@Test func total() {", "    let price = 3", "    #expect(price * 4 == 12)", "}"].joined(separator: "\n").appending("\n")
            .write(toFile: repo + "/Tests/FileTests.swift", atomically: true, encoding: .utf8)
        try texts["Package.resolved"]!.joined(separator: "\n").replacingOccurrences(of: "aaaa", with: "bbbb").appending("\n")
            .write(toFile: repo + "/Package.resolved", atomically: true, encoding: .utf8)
        for index in 0..<fresh {
            let path = "App/Fresh\(index).swift"
            try swiftFile("Fresh\(index)", lines: freshLines).joined(separator: "\n").appending("\n").write(toFile: repo + "/" + path, atomically: true, encoding: .utf8)
            changed.append(path)
        }
        return (repo, changed + ["Tests/FileTests.swift", "Package.resolved"])
    }

    static func book(_ name: String) throws -> (String, [String]) {
        switch name {
        // 6 files of 45 changes and 4 new files of 650 lines: about 5,000 changed lines.
        case "big": try repository(files: 6, hunks: 45, each: 6, fresh: 4, freshLines: 650)
        // Seven changed files, a test and a lockfile: nine.
        default: try repository(files: 7, hunks: 3, each: 3, fresh: 0, freshLines: 0)
        }
    }

    /// A thread that edited the book's files, ran the tests through tail, and edited two more after.
    static func seedBook(_ context: ModelContext, _ project: Project, paths: [String], ranAt: Date) throws -> Chat {
        let chat = Chat(project: project, title: "A composer under each thread", permissionMode: "bypassPermissions")
        chat.started = true
        context.insert(chat)
        var events: [(String, JSON, Date)] = [("user", ["event": "user", "text": "Put a composer under each thread"], ranAt.addingTimeInterval(-600))]
        let late = Set(paths.prefix(2))
        func edit(_ path: String, _ id: String, at date: Date) {
            events.append(("tool.use", ["event": "tool.use", "toolUseId": .string(id), "name": "Edit", "input": ["file_path": .string(project.path + "/" + path), "old_string": "a", "new_string": "b"]], date))
            events.append(("tool.result", ["event": "tool.result", "toolUseId": .string(id), "content": "ok", "isError": false,
                                           "patch": [["oldStart": 1, "newStart": 1, "lines": ["-a", "+b"]]]], date))
        }
        for (index, path) in paths.enumerated() where !late.contains(path) { edit(path, "e\(index)", at: ranAt.addingTimeInterval(-300 + Double(index))) }
        events.append(("tool.use", ["event": "tool.use", "toolUseId": "run", "name": "Bash", "input": ["command": "make test 2>&1 | tail -40"]], ranAt))
        events.append(("tool.result", ["event": "tool.result", "toolUseId": "run", "content": "ran 12 tests", "isError": false], ranAt.addingTimeInterval(20)))
        for (index, path) in late.sorted().enumerated() { edit(path, "l\(index)", at: ranAt.addingTimeInterval(60 + Double(index))) }
        events.append(("turn.done", ["event": "turn.done", "durationMs": 1000, "costUSD": 0, "stopReason": "end_turn"], ranAt.addingTimeInterval(90)))
        for (seq, (kind, body, date)) in events.enumerated() {
            let event = Event(turn: 1, seq: seq, kind: kind, payload: try body.data())
            event.createdAt = date
            context.insert(event)
            event.chat = chat
        }
        return chat
    }

    /// A book on disk with its thread, in a window on screen, the engine up.
    static func staged(_ name: String) async throws -> (Stage, String, [String]) {
        let (repo, paths) = try book(name)
        usleep(1_100_000)
        let ranAt = Date.now
        usleep(1_100_000)
        for path in paths.prefix(2) {
            let url = URL(filePath: repo + "/" + path)
            try Data(contentsOf: url).write(to: url)
        }
        let stage = try Stage(cwd: repo) { context, project in try seedBook(context, project, paths: paths, ranAt: ranAt) }
        try await stage.boot()
        return (stage, repo, paths)
    }

    /// The review opened PERF_ROUNDS times on PERF_BOOK, drawn as PERF_DESIGN says (legacy,
    /// legacyall for every file open, witness), and scrolled after the last opening.
    static func review() async throws {
        let name = env["PERF_BOOK"] ?? "nine"
        let design = env["PERF_DESIGN"] ?? "legacy"
        let rounds = Int(env["PERF_ROUNDS"] ?? "") ?? 3
        let (stage, repo, _) = try await staged(name)
        defer {
            stage.window.close()
            try? FileManager.default.removeItem(atPath: repo)
        }
        let model = stage.model, window = stage.window
        guard model.engineState == .ready else { return log("review: the engine isn't up, \(model.engineState)") }
        await front(window)
        use(design, model)
        try await settle(1500)
        model.readReview()
        guard await until(20, { model.review.diff != nil && !model.review.loading }) else { return log("review: no diff read") }
        try await settle(500)
        let units = model.review.book.units
        let lines = units.reduce(0) { $0 + $1.lines.count }
        let changed = units.reduce(0) { $0 + $1.added + $1.deleted }
        log("\(name), \(design): \(model.review.diff?.files.count ?? 0) files, \(units.count) hunks, \(lines) lines drawn of \(changed) changed. \(describe(model))")
        let before = Set(stage.scrolls().map(ObjectIdentifier.init))
        var worst: [Double] = [], dropped: [Int] = [], total: [Double] = []
        for round in 0..<rounds {
            arrange(design, model)
            let wait = min(12_000, units.count * 2 * 17 + 1200)
            let frames = Frames(window.contentView!)
            model.openReview()
            try await settle(wait)
            let summary = frames.stop()
            worst.append(summary.worst)
            dropped.append(summary.dropped)
            total.append(summary.cpu.reduce(0, +))
            log("open \(round + 1), \(name), \(design): \(summary.text); frames \(summary.cpu.filter { $0 > 8.3 }.map { String(format: "%.1f", $0) }.joined(separator: " "))")
            if round == 0 { screenshot(window, "\(label)-open") }
            if round == rounds - 1 {
                guard let view = stage.scrolls().filter({ !before.contains(ObjectIdentifier($0)) }).max(by: { $0.frame.height < $1.frame.height }) else {
                    log("REVIEWSCROLL: the review's scroll view wasn't found")
                    continue
                }
                try await wheel(stage, view, -40, ticks: 240, "REVIEWSCROLL \(name), \(design), 40pt a frame down for 4 s")
                try await wheel(stage, view, -160, ticks: 180, "REVIEWSCROLL \(name), \(design), 160pt a frame down for 3 s")
                try await wheel(stage, view, 400, ticks: 120, "REVIEWSCROLL \(name), \(design), 400pt a frame up for 2 s")
                try await wheel(stage, view, -60, ticks: 180, "REVIEWSCROLL \(name), \(design), 60pt a frame down again, over what was made")
                try await wheel(stage, view, -900, ticks: 90, decay: 0.95, "REVIEWSCROLL \(name), \(design), flick down, 900pt a frame dying away")
                try await wheel(stage, view, 900, ticks: 90, decay: 0.95, "REVIEWSCROLL \(name), \(design), flick up, 900pt a frame dying away")
                screenshot(window, "\(label)-scrolled")
            }
            model.closeReview()
            try await settle(700)
        }
        let sorted = worst.sorted()
        log(String(format: "REVIEWOPEN %@, %@: worst frame of each of %d openings, ms: %@; median %.1f; frames dropped %@; main thread per opening, ms: %@",
                   name, design, rounds, worst.map { String(format: "%.1f", $0) }.joined(separator: " "), sorted[sorted.count / 2],
                   dropped.map(String.init).joined(separator: " "), total.map { String(format: "%.0f", $0) }.joined(separator: " ")))
    }

    /// J pressed sixty times down a book with the review open, a tenth of a second apart.
    static func jwalk() async throws {
        let name = env["PERF_BOOK"] ?? "big"
        let design = env["PERF_DESIGN"] ?? "legacy"
        let (stage, repo, _) = try await staged(name)
        defer {
            stage.window.close()
            try? FileManager.default.removeItem(atPath: repo)
        }
        let model = stage.model, window = stage.window, review = model.review
        guard model.engineState == .ready else { return log("jwalk: the engine isn't up") }
        await front(window)
        use(design, model)
        try await settle(1200)
        model.readReview()
        guard await until(20, { review.diff != nil && !review.loading }) else { return log("jwalk: no diff read") }
        arrange(design, model)
        model.openReview()
        // Legacy makes a row a frame, and a J before the last is made crashes it (made = .max, then made += 1), in 0.3.3 too.
        try await settle(min(14_000, review.book.units.count * 2 * 17 + 3000))
        for round in 1...3 {
            review.selected = nil
            try await settle(600)
            let presses = 60
            var tick = 0
            let frames = Frames(window.contentView!)
            let done = Ticker(window.contentView!, ticks: presses * 6) {
                if tick % 6 == 0 { stage.pressApp("j", code: 38) }
                tick += 1
            }
            try await done.wait()
            let summary = frames.stop()
            try await settle(500)
            let at = review.visibleUnits.firstIndex { $0.id == review.selected } ?? -1
            log("JWALK \(round), \(name), \(design): \(presses) presses of J, a tenth of a second apart, keyboard at change \(at + 1) of \(review.visibleUnits.count); \(summary.text); long \(summary.long)")
        }
        for round in 1...2 {
            let presses = 40
            var tick = 0
            let frames = Frames(window.contentView!)
            let done = Ticker(window.contentView!, ticks: presses * 6) {
                if tick % 6 == 0 { stage.pressApp("k", code: 40) }
                tick += 1
            }
            try await done.wait()
            let summary = frames.stop()
            try await settle(500)
            let at = review.visibleUnits.firstIndex { $0.id == review.selected } ?? -1
            log("KWALK \(round), \(name), \(design): \(presses) presses of K, keyboard at change \(at + 1) of \(review.visibleUnits.count); \(summary.text); long \(summary.long)")
        }
        screenshot(window, "\(label)-jwalk")
    }

    /// J pressed while the review is still making its rows, PERF_EARLY ms after it opens.
    static func earlyJ() async throws {
        let name = env["PERF_BOOK"] ?? "big"
        let design = env["PERF_DESIGN"] ?? "legacy"
        let (stage, repo, _) = try await staged(name)
        defer {
            stage.window.close()
            try? FileManager.default.removeItem(atPath: repo)
        }
        let model = stage.model, review = model.review
        await front(stage.window)
        use(design, model)
        try await settle(1200)
        model.readReview()
        guard await until(20, { review.diff != nil && !review.loading }) else { return log("earlyj: no diff read") }
        arrange(design, model)
        model.openReview()
        try await settle(Int(env["PERF_EARLY"] ?? "") ?? 150)
        log("EARLYJ \(name), \(design): pressing J \(env["PERF_EARLY"] ?? "150") ms after the review opened")
        for _ in 0..<3 {
            stage.pressApp("j", code: 38)
            try await settle(100)
        }
        try await settle(3000)
        log("EARLYJ \(name), \(design): still running, keyboard on \(review.selected ?? "nothing")")
    }

    /// Two keys inside one glide, in a window short enough that the glide to the next change
    /// takes the one before off the page: J then K and K then J, PERF_GAPS ms apart, Tab then
    /// ⇧Tab in Witness, and J held for three seconds and let go. Each ends with the keyboard on
    /// a change, and its line says whether the page came to rest with that change on it.
    static func backStep() async throws {
        let name = env["PERF_BOOK"] ?? "big"
        let design = env["PERF_DESIGN"] ?? "witness"
        let (stage, repo, _) = try await staged(name)
        defer {
            stage.window.close()
            try? FileManager.default.removeItem(atPath: repo)
        }
        let model = stage.model, window = stage.window, review = model.review
        let height = env["PERF_HEIGHT"].flatMap(Double.init) ?? 560
        window.setContentSize(NSSize(width: 1180, height: height))
        guard model.engineState == .ready else { return log("backstep: the engine isn't up") }
        await front(window)
        use(design, model)
        try await settle(1200)
        model.readReview()
        guard await until(20, { review.diff != nil && !review.loading }) else { return log("backstep: no diff read") }
        arrange(design, model)
        let before = Set(stage.scrolls().map(ObjectIdentifier.init))
        model.openReview()
        try await settle(min(14_000, review.book.units.count * 2 * 17 + 3000))
        guard let clip = stage.scrolls().filter({ !before.contains(ObjectIdentifier($0)) }).max(by: { $0.frame.height < $1.frame.height })?.contentView else {
            return log("backstep: no page")
        }
        // Longer than PageFollow.glide, so a pair's first key is pressed with no ask before it
        // still counted as inside a glide, the way a J after a pause is.
        let slow = 700
        let keys: [String: (String, UInt16, NSEvent.ModifierFlags)] = ["J": ("j", 38, []), "K": ("k", 40, []), "Tab": ("\t", 48, []), "⇧Tab": ("\u{19}", 48, .shift)]
        func press(_ key: String) {
            guard let (characters, code, flags) = keys[key] else { return }
            stage.pressApp(characters, code: code, flags: flags)
        }
        func offset() -> Double { clip.bounds.origin.y }
        func change() -> Int { (review.visibleUnits.firstIndex { $0.id == review.selected } ?? -1) + 1 }
        func put(_ unit: ReviewUnit) async throws {
            review.select(unit)
            try await settle(slow)
        }
        /// Whether the page rests with the selected change on it: asked for the change again,
        /// with nothing moving, a page that has it stays where it is.
        func judged() async throws -> (Bool, String) {
            let rest = offset(), at = change()
            guard let unit = review.selectedUnit else { return (false, "the keyboard on no change") }
            review.selected = nil
            try await settle(120)
            let cleared = offset()
            try await put(unit)
            let on = abs(offset() - rest) <= 1 && abs(cleared - rest) <= 1
            return (on, "\(at)@\(Int(rest)), and asked for again the page \(on ? "stays: on" : "goes to \(Int(offset())): OFF")")
        }
        for _ in 0..<5 {
            press("J")
            try await settle(slow)
        }
        guard let start = review.selectedUnit else { return log("backstep: the keyboard is on no change") }
        let h = Int(height)
        log("BACKSTEP \(name), \(design), \(h)pt, page \(Int(clip.bounds.height))pt tall: after 5 J at rest \(change())@\(Int(offset()))")
        var ends = 0
        var off: [String] = []
        let gaps = (env["PERF_GAPS"] ?? "0 20 50 100 200 300").split(separator: " ").compactMap { Int($0) }
        var pairs = [("J", "K"), ("K", "J")]
        // Tab's glide runs many screens, the lazy stack measures rows on the way and the page's
        // offsets shift under it, so its ends are judged from PERF_SHOTS' pictures, not counted.
        if env["PERF_TAB"] != nil { pairs.append(("Tab", "⇧Tab")) }
        for round in 1...(Int(env["PERF_ROUNDS"] ?? "") ?? 1) {
            for (first, second) in pairs {
                for gap in gaps {
                    // From where a slow J leaves the page, the change's last line at the page's.
                    try await put(start)
                    press("K")
                    try await settle(slow)
                    press("J")
                    try await settle(slow)
                    let from = "\(change())@\(Int(offset()))"
                    press(first)
                    if gap > 0 { try await settle(gap) }
                    let mid = Int(offset())
                    press(second)
                    var seen: [Int] = []
                    for _ in 0..<(env["PERF_TRACE"] == nil ? 0 : 24) {
                        try await settle(16)
                        seen.append(Int(offset()))
                    }
                    try await settle(1100)
                    if env["PERF_SHOTS"] != nil { screenshot(window, "\(label)-\(first)-\(second)-\(gap)-r\(round)") }
                    let (on, said) = try await judged()
                    if first != "Tab" {
                        ends += 1
                        if !on { off.append("\(first) \(second) \(gap) ms") }
                    }
                    log("BACKSTEP \(name), \(design), \(h)pt, round \(round): from \(from), \(first), \(gap) ms (page at \(mid)), \(second)\(seen.isEmpty ? "" : ", every 16 ms " + seen.map(String.init).joined(separator: " ")): rest \(said)\(first == "Tab" ? ", not counted" : "")")
                }
            }
            try await put(start)
            for _ in 0..<90 {
                press("J")
                try await settle(33)
            }
            let lifted = "\(change())@\(Int(offset()))"
            try await settle(1500)
            let (on, said) = try await judged()
            ends += 1
            if !on { off.append("J held") }
            log("BACKSTEP \(name), \(design), \(h)pt, round \(round): 90 J 33 ms apart, as the key lifts \(lifted): rest \(said)")
        }
        screenshot(window, "\(label)-backstep")
        log("BACKSTEP \(name), \(design), \(h)pt: \(ends) ends, the selected change off the page in \(off.count)\(off.isEmpty ? "" : ": " + off.joined(separator: "; "))")
    }

    // MARK: Memory

    /// The app's footprint as its day goes: a short thread, a long one, ten switches, the review
    /// opened and closed ten times.
    static func memory() async throws {
        log(String(format: "MEM before any window: %.1f MB", footprint()))
        var ids: [UUID] = []
        let (repo, paths) = try book("nine")
        defer { try? FileManager.default.removeItem(atPath: repo) }
        var long: Chat?
        let stage = try Stage(cwd: repo) { context, project in
            for n in 0..<10 { ids.append(try seed(context, project, title: "Thread \(n)", turns: 25).id) }
            long = try seed(context, project, title: "Long", turns: 100)
            return try seedBook(context, project, paths: paths, ranAt: Date.now.addingTimeInterval(-60))
        }
        defer { stage.window.close() }
        try await stage.boot()
        await front(stage.window)
        try await settle(4000)
        log(String(format: "MEM a short thread open, engine up: %.1f MB", footprint()))
        stage.model.selectedChatID = long!.id
        try await settle(4000)
        log(String(format: "MEM the long thread open (100 turns, 1101 events): %.1f MB", footprint()))
        for id in ids {
            stage.model.selectedChatID = id
            try await settle(900)
        }
        try await settle(3000)
        log(String(format: "MEM after ten more threads of 25 turns opened: %.1f MB, conversations kept %d", footprint(), stage.model.conversations.count))
        for id in ids {
            stage.model.selectedChatID = id
            try await settle(700)
        }
        try await settle(3000)
        log(String(format: "MEM after the same ten opened again: %.1f MB, conversations kept %d", footprint(), stage.model.conversations.count))
        stage.model.selectedChatID = stage.chat.id
        try await settle(2500)
        let design = env["PERF_DESIGN"] ?? "legacy"
        use(design, stage.model)
        stage.model.readReview()
        _ = await until(20, { stage.model.review.diff != nil && !stage.model.review.loading })
        let base = footprint()
        log(String(format: "MEM back on the short thread, before the review (%@): %.1f MB", design, base))
        for round in 1...10 {
            arrange(design, stage.model)
            stage.model.openReview()
            try await settle(1500)
            if round == 1 { log(String(format: "MEM review open, first time: %.1f MB", footprint())) }
            stage.model.closeReview()
            try await settle(800)
            if round == 1 { log(String(format: "MEM review closed, first time: %.1f MB", footprint())) }
        }
        try await settle(4000)
        log(String(format: "MEM after the review opened and closed ten times: %.1f MB (%+.1f on before)", footprint(), footprint() - base))
        try await settle(20_000)
        log(String(format: "MEM twenty seconds later: %.1f MB (%+.1f on before)", footprint(), footprint() - base))
    }

    // MARK: The app's own store

    /// Threads into the app's own store, the long one kept open; with PERF_PAIR a second beside it.
    static func seedStore() async throws {
        guard let model = appModel else { return log("seed: no app model") }
        let context = model.context
        let folder = Self.folder.appending(path: "proj").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let project = Project(name: "perf", path: folder)
        project.colorIndex = 2
        context.insert(project)
        var long: Chat?, second: Chat?
        for n in 0..<12 {
            let chat = try seed(context, project, title: n == 0 ? "Long" : "Thread \(n)", turns: n == 0 ? 100 : 25, reply: message(900), ask: false)
            if n == 0 { long = chat }
            if n == 1 { second = chat }
        }
        try context.save()
        model.touch()
        model.selectedProjectID = project.id
        model.selectedChatID = long?.id
        if pair, let second { beside(model, second.id) }
        try await settle(2500)
        model.save()
        log("seed: 12 threads, the long one open, pair \(pair): \(kept())")
    }

    // MARK: Launch

    nonisolated static func started() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        return Double(info.kp_proc.p_starttime.tv_sec) + Double(info.kp_proc.p_starttime.tv_usec) / 1_000_000
    }

    /// The launch's marks, in ms since the process started: the delegate's didFinishLaunching,
    /// the main window on screen (the run loop's first rest with it visible, so its first frame
    /// is drawn), the transcript laid out, the composer holding the keyboard, the engine ready.
    static func watchLaunch() {
        let started = started()
        let ms = { (Date.now.timeIntervalSince1970 - started) * 1000 }
        var marks = [String(format: "didFinishLaunching %.0f", ms())]
        var shown = false, ready = false, typed = false, drawn = false, logged = false
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { observer, _ in
            MainActor.assumeIsolated {
                let window = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
                if !shown, window != nil {
                    shown = true
                    marks.append(String(format: "window up %.0f", ms()))
                }
                if !drawn, let window, let content = window.contentView {
                    var tall = false
                    func walk(_ view: NSView) {
                        if let scroll = view as? NSScrollView, scroll.frame.height > 300, (scroll.documentView?.frame.height ?? 0) > 1000 { tall = true }
                        if !tall { view.subviews.forEach(walk) }
                    }
                    walk(content)
                    if tall {
                        drawn = true
                        marks.append(String(format: "transcript laid out %.0f", ms()))
                    }
                }
                if !typed, window?.firstResponder is NSTextView {
                    typed = true
                    marks.append(String(format: "composer has keys %.0f", ms()))
                }
                if !ready, appModel?.engineState == .ready {
                    ready = true
                    marks.append(String(format: "engine ready %.0f", ms()))
                }
                if !logged, shown, drawn, (ready && typed) || ms() > 8000 {
                    if !typed { marks.append("composer has keys never in 8 s") }
                    if !ready { marks.append("engine ready never in 8 s") }
                    logged = true
                    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                    Self.label = ProcessInfo.processInfo.environment["PERF_LAUNCH"] ?? "launch"
                    log(String(format: "LAUNCH %@ (ms since the process started; epoch %.3f); footprint %.1f MB; %@", marks.joined(separator: ", "), started, footprint(), kept()))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// Main-thread CPU between one display-link tick and the next, and the wall time between them.
@MainActor
final class Frames: NSObject {
    private var link: CADisplayLink?
    private var last = 0.0
    private var lastWall = 0.0
    private var cpu: [Double] = []
    private var gaps: [Double] = []

    init(_ view: NSView) {
        super.init()
        last = PerfBench.cpu()
        lastWall = CACurrentMediaTime()
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = PerfBench.cpu()
        let wall = CACurrentMediaTime()
        cpu.append(now - last)
        gaps.append((wall - lastWall) * 1000)
        last = now
        lastWall = wall
    }

    func stop() -> PerfBench.Summary {
        tick(link!)
        link?.invalidate()
        return PerfBench.Summary(cpu: cpu, gaps: gaps, frame: PerfBench.refresh * 1000)
    }
}

/// Runs a step on each display-link tick, a given number of times.
@MainActor
final class Ticker: NSObject {
    private var link: CADisplayLink?
    private var left: Int
    private let step: () -> Void
    private var finished: CheckedContinuation<Void, Never>?
    private var over = false

    init(_ view: NSView, ticks: Int, step: @escaping () -> Void) {
        left = ticks
        self.step = step
        super.init()
        link = view.displayLink(target: self, selector: #selector(tick))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard left > 0 else {
            link.invalidate()
            over = true
            finished?.resume()
            finished = nil
            return
        }
        left -= 1
        step()
    }

    func wait() async throws {
        if over { return }
        await withCheckedContinuation { finished = $0 }
    }
}

/// RootView in a window on screen, on a model with its own in-memory store.
@MainActor
final class Stage {
    let model: AppModel
    let window: NSWindow
    let chat: Chat
    let container: ModelContainer
    private let host: NSHostingController<AnyView>

    init(cwd: String = NSTemporaryDirectory(), seed: (ModelContext, Project) throws -> Chat) throws {
        container = try ModelContainer(for: Project.self, Chat.self, Event.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let project = Project(name: "alpha", path: cwd)
        project.colorIndex = 2
        container.mainContext.insert(project)
        chat = try seed(container.mainContext, project)
        try container.mainContext.save()
        model = AppModel(container: container)
        model.review.marks = ReviewMarks(file: FileManager.default.temporaryDirectory.appending(path: "oricode-perf-marks-\(UUID().uuidString).json"))
        model.selectedProjectID = chat.project?.id
        model.selectedChatID = chat.id
        PerfBench.alone(model)
        model.drawerPinned = false
        model.drawerShown = false
        let root = RootView()
            .environment(model)
            .environment(Updates())
            .modelContainer(container)
            .frame(minWidth: 720, minHeight: 480)
        host = NSHostingController(rootView: AnyView(root.background { BehindWindowGlass().ignoresSafeArea() }.preferredColorScheme(.dark)))
        host.sceneBridgingOptions = [.toolbars]
        window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // AppKit titles a plain window Untitled and the toolbar's row draws it; the app's Window hides its title.
        window.title = ""
        window.toolbarStyle = .unified
        window.identifier = NSUserInterfaceItemIdentifier("bench")
        if PerfBench.env["PERF_DEPTH"] == "24" { window.depthLimit = .twentyfourBitRGB }
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.isOpaque = false
        window.backgroundColor = .clear
        let screen = NSScreen.main?.visibleFrame ?? .zero
        window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.maxY - window.frame.height - 10))
        // The pointer is wherever its owner left it, and a transcript scrolled under it is another measure from one
        // scrolled beside it: PERF_POINTER puts the window under the pointer, or clear of it.
        let pointer = NSEvent.mouseLocation
        let size = window.frame.size
        if PerfBench.env["PERF_POINTER"] == "over" {
            let x = min(max(pointer.x - size.width / 2, screen.minX), screen.maxX - size.width)
            let y = min(max(pointer.y - size.height * 0.55, screen.minY), screen.maxY - size.height)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else if PerfBench.env["PERF_POINTER"] == "away" {
            let x = pointer.x - screen.minX > screen.width / 2 ? screen.minX : screen.maxX - size.width
            let y = pointer.y - screen.minY > screen.height / 2 ? screen.minY : screen.maxY - size.height
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
        window.orderFrontRegardless()
    }

    func boot() async throws {
        await model.boot()
        for _ in 0..<100 where model.engineState != .ready { try await Task.sleep(for: .milliseconds(100)) }
        PerfBench.log("engine: \(model.engineState)")
    }

    func send(_ name: String, _ body: [String: JSON], to id: UUID? = nil) {
        var body = body
        body["event"] = .string(name)
        model.route(EngineEvent(name: name, threadId: (id ?? chat.id).uuidString, body: .object(body)))
    }

    func focusComposer() async throws -> Bool {
        for _ in 0..<20 where !(window.firstResponder is NSTextView) {
            model.composerFocus += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        return window.firstResponder is NSTextView
    }

    func typed() -> String { (window.firstResponder as? NSTextView)?.string ?? "" }

    /// Every scroll view of some size in the window.
    func scrolls() -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView, scroll.frame.width > 300, scroll.frame.height > 200 { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window.contentView!)
        return found
    }

    /// The transcripts' scroll views, left to right.
    func transcripts() -> [NSScrollView] {
        scrolls().filter { $0.frame.height > 300 }.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    /// A key to the window, as typing sends it.
    func press(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(event)
        }
    }

    /// A key to the app, so its key monitors hear it.
    func pressApp(_ characters: String, code: UInt16 = 0, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { continue }
            NSApp.sendEvent(event)
        }
    }

    func state() -> String {
        transcripts().map { scroll in
            let frame = scroll.convert(scroll.bounds, to: nil)
            return String(format: "[x %.0f w %.0f y %.0f of %.0f]", frame.minX, frame.width, scroll.contentView.bounds.origin.y, scroll.documentView?.frame.height ?? 0)
        }.joined(separator: " ")
    }
}
