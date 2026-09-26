import Foundation
import Observation
import SwiftData

/// What was said in every thread, your messages and the replies, for ⌘K to search without going
/// to the store on each key. The store is read once, off the main thread, at the first search;
/// from launch on, conversations add what they write and keep a streaming reply's text current.
@MainActor
@Observable
final class MessageIndex {
    /// Unchecked because an NSString made from a String is never changed.
    struct Said: @unchecked Sendable {
        let id: UUID
        let chat: UUID
        let user: Bool
        let text: NSString
        /// The text as MessageSearch folds it, when that differs from the text.
        let folded: NSString?

        init(id: UUID, chat: UUID, user: Bool, text: String) {
            self.id = id
            self.chat = chat
            self.user = user
            self.text = text as NSString
            let folded = MessageSearch.fold(text)
            self.folded = folded == text ? nil : folded as NSString
        }
    }

    /// Whether the store has been read in; until then only this launch's messages are here.
    private(set) var ready = false
    /// Oldest first.
    @ObservationIgnored private var said: [Said] = []
    @ObservationIgnored private var at: [UUID: Int] = [:]
    @ObservationIgnored private var reading = false
    /// The last search's words and every message that held them, which the next search looks
    /// through alone when it only adds to what was typed.
    @ObservationIgnored private var last: (words: [String], hits: [Int])?

    func add(_ id: UUID, in chat: UUID, user: Bool, text: String) {
        at[id] = said.count
        said.append(Said(id: id, chat: chat, user: user, text: text))
        last = nil
    }

    func update(_ id: UUID, text: String) {
        guard let index = at[id] else { return }
        let old = said[index]
        said[index] = Said(id: id, chat: old.chat, user: old.user, text: text)
        last = nil
    }

    /// Reads the store's messages in, once. What this launch wrote is newer than the store's copy.
    func read(from container: ModelContainer) {
        guard !ready, !reading else { return }
        reading = true
        Task {
            let stored = await Task.detached(priority: .userInitiated) { Self.stored(in: ModelContext(container)) }.value
            let written = said
            let fresh = Set(written.map(\.id))
            said = stored.filter { !fresh.contains($0.id) } + written
            at = Dictionary(uniqueKeysWithValues: said.enumerated().map { ($1.id, $0) })
            last = nil
            reading = false
            ready = true
        }
    }

    private nonisolated static func stored(in context: ModelContext) -> [Said] {
        let descriptor = FetchDescriptor<Event>(predicate: #Predicate { $0.kind == "user" || $0.kind == "text" },
                                                sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.seq)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap { event in
            guard let chat = event.chat?.id, let body = try? JSONDecoder().decode(JSON.self, from: event.payload) else { return nil }
            let user = event.kind == "user"
            return Said(id: event.id, chat: chat, user: user, text: body[user ? "text" : "delta"]?.string ?? "")
        }
    }

    /// The messages in `threads` that hold every word, newest first, `each` a thread at most and
    /// `limit` in all.
    func search(_ words: [String], in threads: Set<UUID>, each: Int = 3, limit: Int = 20) -> [Said] {
        let folded = words.map(MessageSearch.fold)
        // Every message holding the new words holds the old ones when each old word is inside a new one.
        let narrows = last.map { last in
            last.words.allSatisfy { old in folded.contains { $0.range(of: old, options: [.caseInsensitive, .diacriticInsensitive]) != nil } }
        } ?? false
        let candidates = narrows ? last!.hits : Array(said.indices)
        let hits = Self.holding(folded, among: candidates, of: said)
        last = (folded, hits)
        var found: [Said] = []
        var perThread: [UUID: Int] = [:]
        for index in hits.reversed() {
            let message = said[index]
            guard threads.contains(message.chat), perThread[message.chat, default: 0] < each else { continue }
            perThread[message.chat, default: 0] += 1
            found.append(message)
            if found.count == limit { break }
        }
        return found
    }

    /// The candidates that hold the words, in order. Past a few thousand messages they're looked
    /// through on every core, which took the first key at 10,000 from 49ms to 30.
    private nonisolated static func holding(_ folded: [String], among candidates: [Int], of said: [Said]) -> [Int] {
        let chunk = 2_000
        guard candidates.count > chunk else {
            return candidates.filter { MessageSearch.holds(folded, in: said[$0].folded ?? said[$0].text) }
        }
        var parts = [[Int]](repeating: [], count: (candidates.count + chunk - 1) / chunk)
        parts.withUnsafeMutableBufferPointer { parts in
            DispatchQueue.concurrentPerform(iterations: parts.count) { part in
                parts[part] = candidates[(part * chunk)..<min(candidates.count, (part + 1) * chunk)]
                    .filter { MessageSearch.holds(folded, in: said[$0].folded ?? said[$0].text) }
            }
        }
        return parts.flatMap { $0 }
    }
}
