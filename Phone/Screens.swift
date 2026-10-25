#if DEBUG
import Foundation
import Link

/// Made-up Macs for screenshots of the screens in the simulator, which has no iCloud account to
/// pair with: launched with `-Screens home`, `asleep`, `empty`, `asks` or `thread`.
enum Screens {
    static func cache(_ name: String) -> PhoneClient.Cache? {
        let oricode = ProjectInfo(id: UUID(), name: "OriCode", initials: "OE", color: 1, starts: true, order: 0)
        let site = ProjectInfo(id: UUID(), name: "realmeric.com", initials: "RM", color: 3, starts: false, order: 1)
        let none = ProjectInfo(id: UUID(), name: "No folder", initials: "", color: nil, starts: false, order: 2)
        let now = Date.now
        let store = ThreadInfo(id: UUID(), project: oricode.id, title: "Store tests fail after the schema bump", agent: "claude", status: .asking,
                               step: nil, rays: [:], reply: nil, pinned: false, updated: now)
        let review = ThreadInfo(id: UUID(), project: oricode.id, title: "Review the phone pairing", agent: "claude", status: .working,
                                step: "Running swift test --filter PairingTests", rays: [0: "claude", 1: "codex"], reply: nil, pinned: false, updated: now - 60)
        let water = ThreadInfo(id: UUID(), project: oricode.id, title: "Water glass fills past one", agent: "codex", status: .idle,
                               step: nil, rays: [:], reply: "The glass brims past one now, and the card says the day's water.", pinned: false, updated: now - 3_600)
        let blog = ThreadInfo(id: UUID(), project: site.id, title: "Draft the 0.4 post", agent: "claude", status: .stopped,
                              step: nil, rays: [:], reply: nil, pinned: false, updated: now - 7_200)
        let deploy = ThreadInfo(id: UUID(), project: site.id, title: "Fix the deploy", agent: "claude", status: .working,
                                step: "Writing", rays: [:], reply: nil, pinned: false, updated: now - 30)
        let notes = ThreadInfo(id: UUID(), project: none.id, title: "Clean up Downloads", agent: "claude", status: .failed,
                               step: nil, rays: [:], reply: nil, pinned: false, updated: now - 9_000)
        let run = AskInfo(id: "ask-1", thread: store.id, kind: "permission", title: "Run a command?", detail: "swift test --filter StoreTests",
                          code: true, choices: [], questions: [], worker: nil, asked: now - 40)
        let question = AskInfo(id: "ask-2", thread: deploy.id, kind: "question", title: "Which host should the deploy go to?", detail: nil, code: false,
                               choices: [], questions: [AskInfo.Question(text: "Which host should the deploy go to?", multiple: false, options: [
                                   AskInfo.Option(label: "Cloudflare Pages", detail: "Where the site is now"),
                                   AskInfo.Option(label: "Vercel", detail: nil),
                               ])], worker: nil, asked: now - 10)
        let mac = MacInfo(name: "Meriç MacBook Air", version: "0.4.3", state: .awake)
        let projects = [oricode, site, none]
        let threads = [store, review, water, blog, deploy, notes]
        switch name {
        case "home":
            var quiet = threads
            quiet[0].status = .working
            quiet[4].status = .working
            return .init(mac: mac, projects: projects, threads: quiet, asks: [])
        case "asks":
            var asking = threads
            asking[4].status = .asking
            return .init(mac: mac, projects: projects, threads: asking, asks: [run, question])
        case "asleep":
            return .init(mac: MacInfo(name: mac.name, version: mac.version, state: .asleep), projects: projects, threads: threads, asks: [])
        case "empty":
            return .init(mac: mac, projects: projects, threads: [], asks: [])
        case "thread":
            return .init(mac: mac, projects: projects, threads: threads, asks: [run])
        default:
            return nil
        }
    }
}
#endif
