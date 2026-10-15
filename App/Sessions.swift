import Foundation
import SwiftData

/// A session the user had in another tool, as the engine lists it: Claude Code's from Terminal,
/// Codex's, a T3 Code thread, a Cursor chat.
struct OutsideSession: Decodable, Equatable {
    /// Where it was found, "t3code", and what the list calls that, "T3 Code".
    let source: String
    let sourceName: String
    /// Its id where it was found.
    let id: String
    /// The agent that ran it, whose mark it shows.
    let agent: String?
    /// That agent's id for the session, which the thread's next message resumes; nil when it can
    /// only come in with its transcript.
    let sessionId: String?
    let title: String
    /// Milliseconds since 1970.
    let modified: Double
    let branch: String?

    /// What the thread it becomes keeps of it.
    var key: String { "\(source)/\(id)" }
}

extension AppModel {
    /// ⌘K's Import sessions: the project's folder's sessions in every other tool the engine finds,
    /// latest first, each with its tool's name and its agent's mark, and one row that imports every
    /// one not yet a thread. Each comes in as a thread with its transcript that goes on from where
    /// it stopped.
    var sessionList: PaletteList {
        PaletteList(title: "Import sessions", placeholder: "Search this project's sessions in other tools") { [weak self] in
            guard let self, let project else { return [] }
            let reply = try await engine.request("sessions.list", ["cwd": .string(project.path)])
            let sessions = try reply["sessions"]?.decode([OutsideSession].self) ?? []
            let new = sessions.filter { self.thread(of: $0) == nil }
            let all = new.isEmpty ? [] : [
                PaletteItem(id: "session.all", kind: .command, title: "Import all \(new.count) new session\(new.count == 1 ? "" : "s")",
                            icon: "square.and.arrow.down.on.square",
                            action: .task("Importing \(new.count) session\(new.count == 1 ? "" : "s")…") { [weak self] in
                                await self?.importAll(new, into: project)
                            }),
            ]
            return all + sessions.map { session in
                let when = Date(timeIntervalSince1970: session.modified / 1000).formatted(.relative(presentation: .named))
                let carriedOn = self.resumes(session) ? nil : "Goes on in \(self.providerInfo(self.startingProvider).agent)"
                let line = [session.sourceName, self.thread(of: session) == nil ? carriedOn : "Already a thread", when, session.branch]
                return PaletteItem(id: "session." + session.key, kind: .choice, title: session.title,
                                   subtitle: line.compactMap { $0 }.joined(separator: " · "),
                                   icon: "terminal", agent: session.agent,
                                   action: .task("Opening \(session.title)…") { [weak self] in try await self?.open(session, in: project) })
            }
        }
    }

    /// The thread a session already is, archived or not: one imported from it, or one on its session.
    private func thread(of session: OutsideSession) -> Chat? {
        projects.flatMap(\.chats).first { $0.importedFrom == session.key || session.sessionId != nil && $0.sessionId == session.sessionId }
    }

    /// Whether a session comes in on its own agent, picking it up: the agent is turned on here and
    /// can be given a session by its id.
    func resumes(_ session: OutsideSession) -> Bool {
        guard let agent = session.agent, session.sessionId != nil else { return false }
        return providers.contains { $0.id == agent && $0.capabilities.resume }
    }

    /// The session as a thread of the project's, opened. One that's a thread already is opened instead.
    @discardableResult
    func open(_ session: OutsideSession, in project: Project) async throws -> String? {
        if let existing = thread(of: session) {
            if existing.archived { restore(existing) } else { select(existing) }
            return nil
        }
        select(try await bringIn(session, to: project))
        composerFocus += 1
        return nil
    }

    /// Every session given, each a thread of the project's. One that can't be read leaves the rest
    /// to come in, and the engine's log says why.
    func importAll(_ sessions: [OutsideSession], into project: Project) async -> String? {
        var imported = 0
        for session in sessions where thread(of: session) == nil {
            if (try? await bringIn(session, to: project)) != nil { imported += 1 }
        }
        let noun = "session\(sessions.count == 1 ? "" : "s")"
        return imported == sessions.count ? "Imported \(imported) \(noun)." : "Imported \(imported) of \(sessions.count) \(noun). The rest couldn't be read."
    }

    private func bringIn(_ session: OutsideSession, to project: Project) async throws -> Chat {
        let reply = try await engine.request("sessions.read", ["source": .string(session.source), "id": .string(session.id)])
        return adopt(session, events: reply["events"]?.array ?? [], in: project)
    }

    /// The session as a thread: its transcript stored as a thread's events are, on its own agent
    /// with its session the one the next message resumes, or, where that can't be, on the agent a
    /// new thread starts on, which the next message hands the transcript over to.
    func adopt(_ session: OutsideSession, events: [JSON], in project: Project) -> Chat {
        let chat = Chat(project: project, title: Chat.title(from: session.title), permissionMode: startingPermissionMode)
        if resumes(session), let agent = session.agent {
            chat.provider = agent
            chat.sessionId = session.sessionId
        } else {
            chat.provider = startingProvider
            chat.model = startingModel
            chat.handover = events.contains { $0["event"]?.string == "user" }
        }
        fitPermissionMode(of: chat)
        chat.importedFrom = session.key
        chat.started = true
        chat.titleIsCustom = true
        context.insert(chat)
        var turn = 0
        for (seq, body) in events.enumerated() {
            guard let kind = body["event"]?.string else { continue }
            // A transcript doesn't say when, and the event's own date is this moment: its calls
            // are marked as having no time, so the review reads nothing off when they ran.
            var body = body
            if kind == "tool.use", case .object(var fields) = body {
                fields["untimed"] = true
                body = .object(fields)
            }
            guard let payload = try? body.data() else { continue }
            if kind == "user" { turn += 1 }
            let event = Event(turn: turn, seq: seq, kind: kind, payload: payload)
            context.insert(event)
            event.chat = chat
        }
        save()
        return chat
    }
}
