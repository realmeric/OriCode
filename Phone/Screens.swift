#if DEBUG
import Foundation
import Link
import UserNotifications

/// Made-up Macs for screenshots of the screens in the simulator, which has no iCloud account to
/// pair with: launched with `-Screens home`, `busy`, `asleep`, `empty`, `asks`, `thread`, `reply` or `compose`,
/// or `pairing` for the first launch with Scan, which the simulator has no camera for. `late` has
/// no threads yet, for a notification's tap to land before they've come. `simctl push` never starts
/// the notification extension, so launched with `-Post` and a Nudge's JSON as well, the app posts
/// what the extension would write, four seconds on or `-PostAfter` seconds, for a script to catch.
enum Screens {
    static let storeID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let waterID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    static let deployID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    static var posted: NudgeInfo? {
        let arguments = CommandLine.arguments
        guard let at = arguments.firstIndex(of: "-Post"), at + 1 < arguments.count else { return nil }
        return try? JSONDecoder().decode(NudgeInfo.self, from: Data(arguments[at + 1].utf8))
    }

    static func post(_ nudge: NudgeInfo) async {
        let content = UNMutableNotificationContent()
        content.sound = .default
        await NudgeContent.write(nudge, into: content)
        let shown = await NudgeContent.speaking(nudge, content)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(UserDefaults.standard.double(forKey: "PostAfter"), 4), repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: shown, trigger: trigger))
    }

    static func cache(_ name: String) -> PhoneClient.Cache? {
        let oricode = ProjectInfo(id: UUID(), name: "OriCode", initials: "OE", color: 1, starts: true, order: 0)
        let site = ProjectInfo(id: UUID(), name: "realmeric.com", initials: "RM", color: 3, starts: false, order: 1)
        let none = ProjectInfo(id: UUID(), name: "No folder", initials: "", color: nil, starts: false, order: 2)
        let now = Date.now
        let store = ThreadInfo(id: storeID, project: oricode.id, title: "Store tests fail after the schema bump", agent: "claude", status: .asking,
                               step: nil, rays: [:], reply: nil, pinned: false, updated: now)
        let review = ThreadInfo(id: UUID(), project: oricode.id, title: "Review the phone pairing", agent: "claude", status: .working,
                                step: "Running swift test --filter PairingTests", rays: [0: "claude", 1: "codex"], reply: nil, pinned: false, updated: now - 60)
        let water = ThreadInfo(id: waterID, project: oricode.id, title: "Water glass fills past one", agent: "codex", status: .idle,
                               step: nil, rays: [:], reply: "The glass brims past one now, and the card says the day's water.", pinned: false, updated: now - 3_600)
        let blog = ThreadInfo(id: UUID(), project: site.id, title: "Draft the 0.4 post", agent: "claude", status: .stopped,
                              step: nil, rays: [:], reply: nil, pinned: false, updated: now - 7_200)
        let deploy = ThreadInfo(id: deployID, project: site.id, title: "Fix the deploy", agent: "claude", status: .working,
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
        case "home", "compose":
            var quiet = threads
            quiet[0].status = .working
            quiet[4].status = .working
            return .init(mac: mac, projects: projects, threads: quiet, asks: [])
        case "busy":
            var quiet = threads
            for index in quiet.indices {
                quiet[index].status = .working
                quiet[index].rays = [0: "claude", 1: "codex", 2: "pi"]
            }
            return .init(mac: mac, projects: projects, threads: quiet, asks: [])
        case "asks":
            var asking = threads
            asking[4].status = .asking
            return .init(mac: mac, projects: projects, threads: asking, asks: [run, question])
        case "asleep":
            return .init(mac: MacInfo(name: mac.name, version: mac.version, state: .asleep), projects: projects, threads: threads, asks: [])
        case "empty", "late":
            return .init(mac: mac, projects: projects, threads: [], asks: [])
        case "thread":
            return .init(mac: mac, projects: projects, threads: threads, asks: [run])
        case "reply":
            return .init(mac: mac, projects: projects, threads: threads, asks: [])
        default:
            return nil
        }
    }
}
#endif
