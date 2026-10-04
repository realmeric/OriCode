import Foundation
import SwiftData

/// A Claude Code session started with `claude` in Terminal, as the engine lists it.
struct CLISession: Decodable, Equatable {
    let id: String
    let title: String
    /// Milliseconds since 1970.
    let modified: Double
    let branch: String?
}

extension AppModel {
    /// ⌘K's Open a Claude Code session: the project's folder's sessions from Terminal, latest
    /// first, each opening as a thread with its transcript that goes on from where it stopped.
    var sessionList: PaletteList {
        PaletteList(title: "Open a Claude Code session", placeholder: "Search this project's sessions from Terminal") { [weak self] in
            guard let self, let project else { return [] }
            let reply = try await engine.request("sessions.list", ["cwd": .string(project.path)])
            let sessions = try reply["sessions"]?.decode([CLISession].self) ?? []
            return sessions.map { session in
                let open = self.thread(of: session.id)
                let when = Date(timeIntervalSince1970: session.modified / 1000).formatted(.relative(presentation: .named))
                return PaletteItem(id: "session." + session.id, kind: .choice, title: session.title,
                                   subtitle: [open == nil ? nil : "Already a thread", when, session.branch].compactMap { $0 }.joined(separator: " · "),
                                   icon: "terminal",
                                   action: .task("Opening \(session.title)…") { [weak self] in try await self?.open(session, in: project) })
            }
        }
    }

    /// The thread a session already is, archived or not.
    private func thread(of sessionId: String) -> Chat? {
        projects.flatMap(\.chats).first { $0.sessionId == sessionId }
    }

    /// The session as a thread of the project's: its transcript stored as a thread's events are,
    /// and its session the one the thread's next message resumes. One that's a thread already is
    /// opened instead.
    @discardableResult
    func open(_ session: CLISession, in project: Project) async throws -> String? {
        if let existing = thread(of: session.id) {
            if existing.archived { restore(existing) } else { select(existing) }
            return nil
        }
        let reply = try await engine.request("sessions.read", ["cwd": .string(project.path), "sessionId": .string(session.id)])
        let chat = adopt(session, events: reply["events"]?.array ?? [], in: project)
        select(chat)
        composerFocus += 1
        return nil
    }

    func adopt(_ session: CLISession, events: [JSON], in project: Project) -> Chat {
        let chat = Chat(project: project, title: Chat.title(from: session.title), permissionMode: startingPermissionMode)
        chat.sessionId = session.id
        chat.started = true
        chat.titleIsCustom = true
        context.insert(chat)
        var turn = 0
        for (seq, body) in events.enumerated() {
            guard let kind = body["event"]?.string, let payload = try? body.data() else { continue }
            if kind == "user" { turn += 1 }
            let event = Event(turn: turn, seq: seq, kind: kind, payload: payload)
            context.insert(event)
            event.chat = chat
        }
        save()
        return chat
    }
}
