import Foundation
import Observation
import SwiftData

struct Hunk: Hashable {
    let oldStart: Int
    let newStart: Int
    let lines: [String]
}

struct ToolCall: Hashable {
    let toolUseId: String
    let name: String
    let input: JSON
    var result: String?
    var isError = false
    var patch: [Hunk]?

    static let edits: Set<String> = ["Edit", "MultiEdit", "Write"]

    var isEdit: Bool { Self.edits.contains(name) }
}

struct PendingAsk: Hashable {
    enum State: Hashable {
        case waiting
        case allowed
        case denied
        case cancelled
    }

    let requestId: String
    let kind: String
    let tool: String
    let input: JSON
    let options: JSON?
    var state: State = .waiting
}

struct TurnFooter: Hashable {
    let durationMs: Double
    let costUSD: Double
    let stopReason: String
    var files = 0
    var added = 0
    var deleted = 0
}

enum Item: Identifiable, Hashable {
    case user(id: UUID, text: String)
    case text(id: UUID, text: String)
    case thinking(id: UUID, text: String)
    case tool(id: UUID, call: ToolCall)
    case ask(id: UUID, ask: PendingAsk)
    case footer(id: UUID, footer: TurnFooter)
    case note(id: UUID, text: String)

    var id: UUID {
        switch self {
        case .user(let id, _), .text(let id, _), .thinking(let id, _), .tool(let id, _), .ask(let id, _),
             .footer(let id, _), .note(let id, _):
            id
        }
    }
}

/// One thread's transcript: the stored events replayed into items, then kept current
/// from the engine's live events. Streaming text lands in one event per assistant
/// message, updated in place.
@MainActor
@Observable
final class Conversation {
    private(set) var items: [Item] = []
    private(set) var running = false
    /// "Can't reach Claude…" while the CLI retries; a live line, never stored.
    private(set) var retrying: String?
    private(set) var turn = 0
    private let chat: Chat
    private let context: ModelContext
    private var seq = 0
    private var open: (item: Int, event: Event, kind: String)?
    private var unsaved = false

    init(chat: Chat, context: ModelContext) {
        self.chat = chat
        self.context = context
        for event in chat.events.sorted(by: { $0.seq < $1.seq }) {
            seq = max(seq, event.seq + 1)
            turn = max(turn, event.turn)
            guard let body = try? JSONDecoder().decode(JSON.self, from: event.payload) else { continue }
            apply(event.kind, body, id: event.id)
        }
        open = nil
        // Asks and tool calls from an earlier launch will never finish; the engine that ran them is gone.
        for index in items.indices {
            if case .ask(let id, var ask) = items[index], ask.state == .waiting {
                ask.state = .cancelled
                items[index] = .ask(id: id, ask: ask)
            }
        }
        finishOpenTools()
    }

    /// The oldest ask still waiting, which is the one Return and Esc answer.
    var waitingAsk: PendingAsk? {
        for item in items {
            if case .ask(_, let ask) = item, ask.state == .waiting { return ask }
        }
        return nil
    }

    func userSent(_ text: String) {
        turn += 1
        running = true
        if !chat.titleIsCustom, turn == 1 || chat.title == Chat.untitled {
            chat.title = Chat.title(from: text)
        }
        record("user", ["event": "user", "text": .string(text)])
    }

    func sendFailed(_ message: String) {
        running = false
        record("note", ["event": "note", "text": .string(message)])
    }

    func note(_ message: String) {
        record("note", ["event": "note", "text": .string(message)])
    }

    func receive(_ event: EngineEvent) {
        if event.name != "retrying" { retrying = nil }
        switch event.name {
        case "retrying":
            let attempt = event.body["attempt"]?.int ?? 0
            let max = event.body["max"]?.int ?? 0
            retrying = "Can't reach Claude. Trying again, \(attempt) of \(max)…"
        case "turn.started":
            running = true
            if let sessionId = event.body["sessionId"]?.string, chat.sessionId != sessionId {
                chat.sessionId = sessionId
                unsaved = true
            }
        case "text", "thinking":
            let delta = event.body["delta"]?.string ?? ""
            if let open, open.kind == event.name {
                let current = items[open.item]
                let text = (current.text ?? "") + delta
                items[open.item] = event.name == "text" ? .text(id: current.id, text: text) : .thinking(id: current.id, text: text)
                open.event.payload = (try? JSON.object(["event": .string(event.name), "delta": .string(text)]).data()) ?? Data()
                unsaved = true
            } else {
                record(event.name, ["event": .string(event.name), "delta": .string(delta)], keepOpen: true)
            }
        case "session.lost":
            chat.sessionId = nil
            record("note", ["event": "note", "text": "The earlier session is gone, so this thread carries on in a new one."])
        case "compacted":
            chat.contextUsed = event.body["after"]?.int ?? 0
            record(event.name, event.body)
        case "tool.use", "tool.result", "ask", "ask.cancelled", "error":
            record(event.name, event.body)
        case "turn.done":
            running = false
            if let sessionId = event.body["sessionId"]?.string { chat.sessionId = sessionId }
            chat.costUSD += event.body["costUSD"]?.double ?? 0
            if let used = event.body["context"]?["used"]?.int, used > 0 {
                chat.contextUsed = used
                chat.contextWindow = event.body["context"]?["window"]?.int ?? chat.contextWindow
            }
            record(event.name, event.body)
            flush()
        default:
            break
        }
    }

    func answered(_ requestId: String, allow: Bool) {
        record("answer", ["event": "answer", "requestId": .string(requestId), "allow": .bool(allow)])
    }

    /// Streaming deltas only touch objects in memory; the store is written here.
    func flush() {
        guard unsaved || context.hasChanges else { return }
        unsaved = false
        chat.updatedAt = .now
        try? context.save()
    }

    func stopped() {
        guard running else { return }
        running = false
        retrying = nil
        finishOpenTools()
        flush()
    }

    private func finishOpenTools() {
        for index in items.indices {
            if case .tool(let id, var call) = items[index], call.result == nil {
                call.result = ""
                items[index] = .tool(id: id, call: call)
            }
        }
    }

    private func record(_ kind: String, _ body: JSON, keepOpen: Bool = false) {
        let event = Event(chat: chat, turn: turn, seq: seq, kind: kind, payload: (try? body.data()) ?? Data())
        seq += 1
        context.insert(event)
        unsaved = true
        open = nil
        apply(kind, body, id: event.id)
        if keepOpen, let last = items.indices.last { open = (last, event, kind) }
        if !keepOpen { flush() }
    }

    private func apply(_ kind: String, _ body: JSON, id: UUID) {
        switch kind {
        case "user":
            items.append(.user(id: id, text: body["text"]?.string ?? ""))
        case "text":
            items.append(.text(id: id, text: body["delta"]?.string ?? ""))
        case "thinking":
            items.append(.thinking(id: id, text: body["delta"]?.string ?? ""))
        case "tool.use":
            let call = ToolCall(toolUseId: body["toolUseId"]?.string ?? "", name: body["name"]?.string ?? "", input: body["input"] ?? .null)
            items.append(.tool(id: id, call: call))
        case "tool.result":
            let toolUseId = body["toolUseId"]?.string
            if let index = items.lastIndex(where: { if case .tool(_, let call) = $0 { call.toolUseId == toolUseId } else { false } }),
               case .tool(let itemId, var call) = items[index]
            {
                call.result = body["content"]?.string ?? ""
                call.isError = body["isError"]?.bool ?? false
                call.patch = body["patch"]?.array?.map { hunk in
                    Hunk(
                        oldStart: hunk["oldStart"]?.int ?? 0,
                        newStart: hunk["newStart"]?.int ?? 0,
                        lines: hunk["lines"]?.array?.compactMap(\.string) ?? [])
                }
                items[index] = .tool(id: itemId, call: call)
            }
        case "ask":
            let ask = PendingAsk(
                requestId: body["requestId"]?.string ?? "",
                kind: body["kind"]?.string ?? "permission",
                tool: body["tool"]?.string ?? "",
                input: body["input"] ?? .null,
                options: body["options"])
            items.append(.ask(id: id, ask: ask))
        case "answer", "ask.cancelled":
            let requestId = body["requestId"]?.string
            let state: PendingAsk.State = kind == "ask.cancelled" ? .cancelled : (body["allow"]?.bool == true ? .allowed : .denied)
            if let index = items.lastIndex(where: { if case .ask(_, let ask) = $0 { ask.requestId == requestId } else { false } }),
               case .ask(let itemId, var ask) = items[index], ask.state == .waiting
            {
                ask.state = state
                items[index] = .ask(id: itemId, ask: ask)
            }
        case "turn.done":
            var footer = TurnFooter(
                durationMs: body["durationMs"]?.double ?? 0,
                costUSD: body["costUSD"]?.double ?? 0,
                stopReason: body["stopReason"]?.string ?? "")
            var paths = Set<String>()
            for item in items.reversed() {
                if case .user = item { break }
                guard case .tool(_, let call) = item, call.isEdit, call.result != nil, !call.isError,
                      let diff = Diff.of(call, cwd: chat.cwd)
                else { continue }
                paths.insert(diff.path)
                footer.added += diff.added
                footer.deleted += diff.deleted
            }
            footer.files = paths.count
            items.append(.footer(id: id, footer: footer))
        case "error", "note":
            items.append(.note(id: id, text: body["message"]?.string ?? body["text"]?.string ?? ""))
        case "compacted":
            let before = body["before"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            let after = body["after"]?.int.map { $0.formatted(.number.notation(.compactName)) }
            items.append(.note(id: id, text: before.map { "Compacted from \($0) tokens to \(after ?? "less")." } ?? "Claude compacted the conversation."))
        default:
            break
        }
    }
}

extension Item {
    var text: String? {
        switch self {
        case .text(_, let text), .thinking(_, let text), .user(_, let text), .note(_, let text): text
        default: nil
        }
    }
}
