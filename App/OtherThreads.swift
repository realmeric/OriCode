import Foundation
import SwiftData

/// What a thread may know of the others, through list_threads and read_thread (engine/threads.ts):
/// which there are, what each last edited and what was said in one. All of it is read from the
/// events OriCode stored, when a tool asks and on a context of its own, off the main thread.
/// Nothing is kept between calls, and nothing here writes to a thread or sends it anything.
enum OtherThreads {
    /// Threads one listing names, the latest worked on first.
    static let mostThreads = 40
    /// Files a thread is listed with.
    static let mostFiles = 20
    /// Tool events a listing looks back through for a thread's latest edits. A listing asked for
    /// one file reads them all.
    static let recentEvents = 1_500
    /// Characters of transcript one read returns, about three thousand tokens.
    static let page = 12_000
    /// What one message or reply keeps of itself.
    static let part = 3_000
    /// Events one read looks back through to fill its page.
    static let pageEvents = 600

    /// A thread as the main actor knows it, for the reading done off it.
    struct Listed: Sendable {
        let id: UUID
        let title: String
        let agent: String
        let state: String
        let active: Date
        let cwd: String
        var branch: String?
        var archived = false
        /// The thread that asked, and one it opened itself.
        var asking = false
        var openedByAsker = false
    }

    struct Edit: Hashable, Sendable {
        let path: String
        let at: Date
    }

    private struct Use: Decodable {
        struct Arguments: Decodable {
            let path: String?
            let file_path: String?
            let notebook_path: String?
            let movePath: String?
        }

        let toolUseId: String?
        let name: String?
        let kind: String?
        let input: Arguments?
        let view: Arguments?

        /// The files an edit is on, the first as ToolCall.file reads it, or none for a call that
        /// edits none. A move is on the name it left and the one it made (Codex's movePath).
        var edited: [String] {
            let file: String? = switch kind.flatMap(ToolKind.init(rawValue:)) ?? ToolKind(claude: name ?? "") {
            case .edit, .write, .delete, .move: view?.path ?? input?.file_path ?? input?.path
            case .notebook: view?.path ?? input?.notebook_path
            default: nil
            }
            return [input?.movePath, file].compactMap { $0 }
        }
    }

    private struct Outcome: Decodable {
        let toolUseId: String?
        let isError: Bool?
    }

    private struct WorkerFiles: Decodable {
        struct File: Decodable { let path: String }
        let files: [File]?
    }

    /// Whether an edited file is the one asked about: by its full path, its path in the thread's
    /// folder, or the end of either from a folder's edge, whatever the case.
    static func names(_ asked: String, file: String, cwd: String) -> Bool {
        let asked = (asked as NSString).standardizingPath.lowercased()
        let full = (file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file)).lowercased()
        let standard = (full as NSString).standardizingPath
        return standard == asked || standard.hasSuffix(asked.hasPrefix("/") ? asked : "/" + asked)
    }

    /// The files a thread's own edits touched, the latest first and each once: an edit, write,
    /// delete, move or notebook call that came back without an error, and what a worker brought.
    /// A call still waiting on its result has changed nothing yet. With `asked`, only that file,
    /// from every event the thread has; without, from its latest.
    static func edits(of chat: UUID, cwd: String, asked: String? = nil, in context: ModelContext) -> [Edit] {
        var descriptor = FetchDescriptor<Event>(
            predicate: #Predicate { $0.chat?.id == chat && ($0.kind == "tool.use" || $0.kind == "tool.result" || $0.kind == "worker") },
            sortBy: [SortDescriptor(\.seq, order: .reverse)])
        if asked == nil { descriptor.fetchLimit = recentEvents }
        let decoder = JSONDecoder()
        var outcomes: [String: Bool] = [:]
        var seen: Set<String> = []
        var edits: [Edit] = []
        func add(_ file: String, at: Date) {
            if let asked, !names(asked, file: file, cwd: cwd) { return }
            let path = ToolSummary.relative(file.hasPrefix("/") ? file : (cwd as NSString).appendingPathComponent(file), to: cwd)
            if seen.insert(path).inserted { edits.append(Edit(path: path, at: at)) }
        }
        // Newest first, so a call's result is met before the call.
        for event in (try? context.fetch(descriptor)) ?? [] {
            if asked == nil, edits.count == mostFiles { break }
            switch event.kind {
            case "tool.result":
                if let outcome = try? decoder.decode(Outcome.self, from: event.payload), let id = outcome.toolUseId {
                    outcomes[id] = outcome.isError ?? false
                }
            case "worker":
                for file in (try? decoder.decode(WorkerFiles.self, from: event.payload))?.files ?? [] { add(file.path, at: event.createdAt) }
            default:
                guard let use = try? decoder.decode(Use.self, from: event.payload), let id = use.toolUseId, outcomes[id] == false else { continue }
                for file in use.edited { add(file, at: event.createdAt) }
            }
        }
        return edits
    }

    /// The listing list_threads answers with. With `asked`, only the threads that edited it.
    static func listing(_ threads: [Listed], project: String, folder: String, asked: String?, in context: ModelContext) -> JSON {
        let stamp = ISO8601DateFormatter()
        var rows: [JSON] = []
        var left = 0
        for thread in threads.sorted(by: { $0.active > $1.active }) {
            // Past the fortieth a thread is only counted, and one not asked about a file isn't read.
            let listed = rows.count < mostThreads
            if !listed, asked == nil {
                left += 1
                continue
            }
            let edits = edits(of: thread.id, cwd: thread.cwd, asked: asked, in: context)
            if asked != nil, edits.isEmpty { continue }
            guard listed else {
                left += 1
                continue
            }
            var row: [String: JSON] = [
                "id": .string(thread.id.uuidString), "title": .string(thread.title), "agent": .string(thread.agent),
                "state": .string(thread.state), "active": .string(stamp.string(from: thread.active)),
                "edited": .array(edits.prefix(asked == nil ? mostFiles : .max).map { ["path": .string($0.path), "at": .string(stamp.string(from: $0.at))] }),
            ]
            if thread.asking { row["this"] = true }
            if thread.openedByAsker { row["openedByYou"] = true }
            if thread.archived { row["archived"] = true }
            if thread.cwd != folder { row["folder"] = .string(thread.cwd) }
            if let branch = thread.branch { row["branch"] = .string(branch) }
            rows.append(.object(row))
        }
        var listing: [String: JSON] = ["project": .string(project), "threads": .array(rows)]
        if left > 0 { listing["more"] = .number(Double(left)) }
        if let asked, rows.isEmpty { listing["note"] = .string("No thread's own edits touched \(asked). A shell command, the user or something outside OriCode may have changed it.") }
        return .object(listing)
    }

    /// One part of a thread's transcript: its lines oldest first, and where the part before it
    /// ends when there is one.
    struct Part: Equatable, Sendable {
        var text = ""
        var before: Int?
    }

    /// The latest part of a thread's transcript, or the part before `before`: your messages, the
    /// replies and each tool call as a line, as a handover tells a thread (Handover), gathered
    /// from the end until the page is full.
    static func transcript(of chat: UUID, cwd: String, before: Int? = nil, page: Int = OtherThreads.page, in context: ModelContext) -> Part {
        let end = before ?? .max
        var descriptor = FetchDescriptor<Event>(
            predicate: #Predicate {
                $0.chat?.id == chat && $0.seq < end
                    && ($0.kind == "user" || $0.kind == "text" || $0.kind == "tool.use" || $0.kind == "tool.result" || $0.kind == "shell")
            },
            sortBy: [SortDescriptor(\.seq, order: .reverse)])
        descriptor.fetchLimit = pageEvents
        let events = (try? context.fetch(descriptor)) ?? []
        let decoder = JSONDecoder()
        var failed: Set<String> = []
        var lines: [String] = []
        var used = 0
        var oldest: Int?
        var full = false
        for event in events {
            var line: String
            switch event.kind {
            case "tool.result":
                if let outcome = try? decoder.decode(Outcome.self, from: event.payload), outcome.isError == true, let id = outcome.toolUseId { failed.insert(id) }
                continue
            case "user", "text":
                guard let body = try? decoder.decode(JSON.self, from: event.payload),
                      let text = body[event.kind == "user" ? "text" : "delta"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
                else { continue }
                line = (event.kind == "user" ? "User: " : "Assistant: ") + (text.count > part ? String(text.prefix(part)) + "…" : text)
            case "shell":
                guard let body = try? decoder.decode(JSON.self, from: event.payload) else { continue }
                line = "User ran: " + ToolSummary.firstLine(body["command"]?.string ?? "")
            default:
                guard let body = try? decoder.decode(JSON.self, from: event.payload) else { continue }
                let name = body["name"]?.string ?? ""
                let call = ToolCall(
                    toolUseId: body["toolUseId"]?.string ?? "", name: name, input: body["input"] ?? .null,
                    declared: ToolKind(body["kind"], tool: name), view: body["view"] ?? .null)
                line = ToolSummary.line(for: call, cwd: cwd).replacingOccurrences(of: "\n", with: " ")
                if line.count > Handover.line { line = String(line.prefix(Handover.line)) + "…" }
                line = "Tool: " + line + (failed.contains(call.toolUseId) ? " (failed)" : "")
            }
            // The latest line is always there, however long.
            if !lines.isEmpty, used + line.count + 1 > page {
                full = true
                break
            }
            lines.append(line)
            used += line.count + 1
            oldest = event.seq
        }
        let more = full || events.count == pageEvents
        return Part(text: lines.reversed().joined(separator: "\n"), before: more ? oldest : nil)
    }
}

extension AppModel {
    /// The words list_threads gives for what a thread is doing.
    func state(of chat: Chat) -> String {
        let conversation = conversations[chat.id]
        if conversation?.waitingAsk != nil { return "waiting on the user" }
        if conversation?.working == true { return "working" }
        if chat.resumeAt != nil { return "waiting for a limit to reset" }
        return "idle"
    }

    /// The threads a thread may list and read: its project's, once they've had a first message,
    /// archived ones too, and any it opened in another project.
    func threads(around asking: Chat) -> [Chat] {
        guard let project = asking.project else { return [] }
        let opened = projects.filter { $0.id != project.id }.flatMap(\.chats).filter { $0.openedBy == asking.id }
        return (project.chats + opened).filter(\.started)
    }

    func listThreads(for asking: UUID, edited: String?) async throws -> JSON {
        guard let chat = chat(withID: asking), let project = chat.project else { throw Refused(why: "The thread that asked is gone.") }
        let threads = threads(around: chat).map { thread in
            OtherThreads.Listed(
                id: thread.id, title: thread.title, agent: thread.providerID, state: state(of: thread), active: thread.updatedAt, cwd: thread.cwd,
                branch: thread.worktreeBranch, archived: thread.archived, asking: thread.id == chat.id, openedByAsker: thread.openedBy == chat.id)
        }
        let (name, folder, container) = (project.name, project.path, context.container)
        return await Task.detached(priority: .userInitiated) {
            OtherThreads.listing(threads, project: name, folder: folder, asked: edited, in: ModelContext(container))
        }.value
    }

    func readThread(_ named: String, before: Int?, for asking: UUID) async throws -> JSON {
        guard let chat = chat(withID: asking) else { throw Refused(why: "The thread that asked is gone.") }
        guard let thread = threads(around: chat).first(where: { $0.id.uuidString.caseInsensitiveCompare(named) == .orderedSame }) else {
            throw Refused(why: "No thread of this project has the id \(named). list_threads gives the ones there are.")
        }
        // A reply still streaming is in memory until its next save.
        conversations[thread.id]?.saveHeld()
        // Taken now: the thread may be deleted while its events are read.
        let (id, title, state, cwd, container) = (thread.id, thread.title, state(of: thread), thread.cwd, context.container)
        let part = await Task.detached(priority: .userInitiated) {
            OtherThreads.transcript(of: id, cwd: cwd, before: before, in: ModelContext(container))
        }.value
        guard self.chat(withID: id) != nil else { throw Refused(why: "That thread was deleted while it was being read.") }
        var read: [String: JSON] = [
            "id": .string(id.uuidString), "title": .string(title), "state": .string(state), "transcript": .string(part.text),
        ]
        if let before = part.before { read["before"] = .number(Double(before)) }
        return .object(read)
    }
}
