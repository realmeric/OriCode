#if DEBUG
import Foundation
import Link
import UIKit

/// Conversations for the screenshots: a long thread with its earlier pages a moment away, a reply
/// streaming, a thread opened by another waiting on an app, a new thread with nothing yet, a message
/// waiting for the transcript and one refused.
extension Screens {
    static let talkID = UUID()

    /// Launched with `-ScrollUp <points>`, the thread is taken up that far as a hand would, the
    /// scroll view's offset and not `ScrollPosition`, and logged, row by row, for the frames: a
    /// simulator can't be swiped from a script.
    @MainActor
    static func scrollUp() async {
        guard let at = CommandLine.arguments.firstIndex(of: "-ScrollUp"), at + 1 < CommandLine.arguments.count,
              var left = Double(CommandLine.arguments[at + 1]) else { return }
        try? await Task.sleep(for: .seconds(1.5))
        func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.frame.height > 400 { return scroll }
            return view.subviews.lazy.compactMap(scrollView).first
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first, let scroll = scrollView(in: window) else { return }
        while left > 0 {
            for _ in 0..<50 where left > 0 {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: max(-scroll.adjustedContentInset.top, scroll.contentOffset.y - 40)), animated: false)
                left -= 40
                try? await Task.sleep(for: .milliseconds(16))
            }
            // A hand lifted while the pages asked for come in.
            try? await Task.sleep(for: .seconds(2.5))
        }
    }

    static let grant = AskInfo(id: "grant", thread: talkID, kind: "permission", title: "Let this thread see and use OriCode Molten?", detail: nil, code: false,
                               choices: [.init(id: "deny", name: "Deny", allows: false), .init(id: "allow", name: "Allow", allows: true)],
                               questions: [], worker: nil, asked: .now)

    static func talkThread(_ name: String, project: UUID) -> ThreadInfo {
        let working = name == "streaming" || name == "opened" || name == "new" || name == "waiting"
        return ThreadInfo(id: talkID, project: project, title: name == "opened" ? "Characters: Hans and friends in OriCode" : "The whole conversation on the phone", agent: "claude",
                          status: name == "opened" ? .asking : working ? .working : .idle,
                          step: name == "streaming" ? "Writing" : name == "new" ? "Thinking" : nil, rays: working ? [0: "claude"] : [:],
                          reply: nil, pinned: false, updated: .now)
    }

    @MainActor
    static func play(_ name: String, in store: PhoneClient) {
        switch name {
        case "long":
            let pages = Self.pages(count: 14)
            for page in pages.suffix(2) { store.showForScreenshots(page) }
            store.earlierForScreenshots = { from in
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2.5))
                    for page in pages where page.index >= from { store.showForScreenshots(page) }
                }
            }
        case "streaming":
            stream(in: store)
        case "opened":
            store.showForScreenshots(TalkPage(thread: talkID, index: 0, lines: [
                TalkLine(id: "task", kind: .task, text: "Build Characters in OriCode: Hans and the others get a folder of their own, their notes are imported, and a thread can start as one of them. Keep each voice distinct as they learn. Tell me when the first slice runs in Molten."),
                TalkLine(id: "reading", kind: .tools, text: "Read 14 files, searched 6 patterns", count: 20, calls: ["Read App/Models.swift", "Read engine/main.ts"]),
                TalkLine(id: "said", kind: .agent, text: "İlk dilimi yazıyorum: engine'de karakter klasörü, Hans'ın içe aktarımı ve thread'e gidecek brief, ardından uygulamada seçici ve simge."),
                TalkLine(id: "writing", kind: .tools, text: "Wrote engine/characters.ts, ran 3 commands", count: 4),
                TalkLine(id: "open", kind: .agent, text: "Molten açıldı, Hans içe aktarılmış. Yeni bir thread açıp Hans olarak deniyorum."),
                TalkLine(id: "asking", kind: .ask, text: "No longer waiting", ask: "grant"),
            ]))
        case "waiting":
            let question = "Which pages should open first?"
            store.showForScreenshots(TalkPage(thread: talkID, index: 0, lines: [
                TalkLine(id: "m", kind: .mine, text: question),
                TalkLine(id: "a", kind: .agent, text: "The newest two, so a long thread opens at once and scrolling up asks for more."),
            ]))
            store.send(.send(thread: talkID, text: "And the very start of the thread?"))
        case "failed":
            store.showForScreenshots(TalkPage(thread: talkID, index: 0, lines: [
                TalkLine(id: "m", kind: .mine, text: "Run the tests"),
                TalkLine(id: "t", kind: .tools, text: "Ran swift test --filter TalkTests", count: 1, failed: 1),
                TalkLine(id: "n", kind: .note, text: "Stopped by a limit"),
            ]))
            store.send(.send(thread: talkID, text: "Then wait for it and try again")).map(store.refuseForScreenshots)
        default:
            break
        }
    }

    /// A reply coming in as the Mac would send it, every two seconds.
    @MainActor
    private static func stream(in store: PhoneClient) {
        let earlier = [
            TalkLine(id: "m", kind: .mine, text: "How does the phone follow a reply while it's written?"),
            TalkLine(id: "t", kind: .tools, text: "Read 3 files", count: 3, calls: ["Read App/Phone/PhoneLink+Talk.swift", "Read Link/Sources/Link/Talk.swift", "Read Phone/ThreadView.swift"]),
        ]
        let words = reply.split(separator: " ", omittingEmptySubsequences: false)
        Task { @MainActor in
            var count = 40
            while true {
                let text = words.prefix(count).joined(separator: " ")
                store.showForScreenshots(TalkPage(thread: talkID, index: 0, lines: earlier + [TalkLine(id: "r", kind: .agent, text: text)]))
                try? await Task.sleep(for: .seconds(2))
                count = min(words.count, count + 18)
            }
        }
    }

    /// A thread of many pages. Every page is a couple of turns, each with its own marks, so a jump
    /// on screen shows in the frames.
    private static func pages(count: Int) -> [TalkPage] {
        (0..<count).map { index in
            let turn = "\(index + 1)"
            return TalkPage(thread: talkID, index: index, lines: [
                TalkLine(id: "\(turn)m", kind: .mine, text: index == 0 ? "This is the very start of the thread: make the phone show all of it." : "Next, part \(turn). Keep it small."),
                TalkLine(id: "\(turn)t", kind: .tools, text: "Read 4 files, searched 2 patterns", count: 6, calls: ["Read App/TranscriptView.swift", "Read App/Reply.swift", "Read Phone/ThreadView.swift", "Read Link/Sources/Link/Records.swift", "Grep waitingAsks", "Grep mainStep"]),
                TalkLine(id: "\(turn)a", kind: .agent, text: reply.replacingOccurrences(of: "Part", with: "Part \(turn):")),
                TalkLine(id: "\(turn)e", kind: .tools, text: "Ran swift test --filter TalkTests", count: 1),
                TalkLine(id: "\(turn)b", kind: .agent, text: "Done with part \(turn). `make test` passes, and the [board](https://example.com/board) says so."),
                TalkLine(id: "\(turn)p", kind: .mine, text: "Good. It's in the right place?"),
                TalkLine(id: "\(turn)q", kind: .agent, text: "Yes: it stands in order with both sides, and **nothing** piles up at the end."),
            ])
        }
    }

    private static let reply = """
    ## Part of the plan

    A page is written again only while it's the newest. Each finished page keeps its place, so a long thread opens at its end and *the start* is one scroll away.

    1. The phone says what it's watching, once a minute.
    2. The Mac folds only what's new.
       - Off the main thread.
       - Sealed like everything else.
    3. The phone merges pages by the line.

    > A lease that lapses takes its pages out of iCloud.

    ```swift
    func took(_ page: TalkPage) {
        guard let talk, talk.thread == page.thread else { return }
        talk.take(page)   // only a changed row draws, however long this line happens to run on a phone
    }
    ```

    | Step | Requests a minute |
    |---|---|
    | Idle, watched | 12 |
    | Streaming | 42 |

    That leaves `ThreadView` with what it should have: rows, and nothing else.
    """
}
#endif
