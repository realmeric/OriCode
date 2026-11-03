#if DEBUG
import Foundation
import notify

extension PhoneLink {
    /// Bridge launched with `-PhoneTestPair` turns the phone on and puts a code up with no sheet,
    /// writing it to /tmp/oricode-phone-code.txt, so the phone's client on this Mac (OriCode Probe)
    /// can pair with it from a script, as the end-to-end checks of KANBAN-phone.md do. Then
    /// `notifyutil -p com.realmeric.oricode.bridge.pair` puts up a new code and
    /// `notifyutil -p com.realmeric.oricode.bridge.unpair` unpairs every phone, as the Settings
    /// buttons would, and `com.realmeric.oricode.bridge.fetch` reads what the phone wrote.
    func pairForTestIfAsked() {
        guard CommandLine.arguments.contains("-PhoneTestPair") else { return }
        if !on { turn(on: true) }
        showTestCode()
        var token: Int32 = 0
        notify_register_dispatch("com.realmeric.oricode.bridge.pair", &token, .main) { _ in
            MainActor.assumeIsolated { self.showTestCode() }
        }
        // What coming back to the Mac does, for a script that can't bring Bridge to the front.
        notify_register_dispatch("com.realmeric.oricode.bridge.fetch", &token, .main) { _ in
            MainActor.assumeIsolated { self.fetchNow() }
        }
        // A thread started in /tmp/oricode-phone-test with what /tmp/oricode-bridge-start.txt
        // says, as typing it into a new thread there would.
        notify_register_dispatch("com.realmeric.oricode.bridge.start", &token, .main) { _ in
            MainActor.assumeIsolated {
                guard let model = self.model, let text = try? String(contentsOfFile: "/tmp/oricode-bridge-start.txt", encoding: .utf8) else { return }
                let folder = URL(filePath: "/tmp/oricode-phone-test", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                model.addProject(at: folder)
                guard let project = model.projects.first(where: { $0.path == folder.standardizedFileURL.path }) else { return }
                _ = model.send(text, images: [], in: model.makeChat(in: project))
            }
        }
        // A long thread that's stored and not in memory, for the phone to page through.
        notify_register_dispatch("com.realmeric.oricode.bridge.long", &token, .main) { _ in
            MainActor.assumeIsolated { self.makeLongThread() }
        }
        notify_register_dispatch("com.realmeric.oricode.bridge.unpair", &token, .main) { _ in
            MainActor.assumeIsolated {
                for phone in self.phones { self.unpair(phone) }
            }
        }
    }

    private func makeLongThread() {
        guard let model else { return }
        let folder = URL(filePath: "/tmp/oricode-phone-test", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.addProject(at: folder)
        guard let project = model.projects.first(where: { $0.path == folder.standardizedFileURL.path }) else { return }
        let chat = model.makeChat(in: project)
        chat.title = "A long thread"
        chat.started = true
        var seq = 0
        func add(_ kind: String, _ body: JSON) {
            let event = Event(turn: seq / 2, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
            seq += 1
            model.context.insert(event)
            event.chat = chat
        }
        for turn in 0..<300 {
            add("user", ["event": "user", "text": .string("Question \(turn)")])
            add("text", ["event": "text", "delta": .string("Answer \(turn). " + String(repeating: "Some words of a reply. ", count: 100))])
        }
        model.save()
        model.dropConversation(chat.id)
    }

    private func showTestCode() {
        startPairing()
        // Up at once, or once a zone that was going has gone.
        Task {
            for _ in 0..<100 {
                await making?.value
                if let code {
                    try? code.string.write(toFile: "/tmp/oricode-phone-code.txt", atomically: true, encoding: .utf8)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
#endif
