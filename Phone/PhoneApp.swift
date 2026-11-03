import Link
import os
import SwiftUI
import UIKit
import UserNotifications

/// Launch to the list on screen, for Instruments: the interval starts as the app does and ends at
/// home's first appearance, the cached list in it.
@MainActor
enum Launch {
    static let signposter = OSSignposter(subsystem: "com.realmeric.oricode.phone", category: .pointsOfInterest)
    static let state = signposter.beginInterval("launch")
    static var shown = false

    static func listShown() {
        guard !shown else { return }
        shown = true
        signposter.endInterval("launch", state)
    }
}

@main
struct PhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: PhoneDelegate
    @Environment(\.scenePhase) private var phase

    init() {
        _ = Launch.state
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if delegate.store.paired == nil {
                    PairingView()
                } else {
                    HomeView()
                }
            }
            .environment(delegate.store)
            .environment(delegate.router)
            .preferredColorScheme(.dark)
            // The brief has no accent colour: the system's blue stays out of the cursor and links.
            .tint(Ink.primary)
            .onChange(of: phase, initial: true) { _, phase in
                delegate.store.inFront(phase == .active)
                if phase == .active { Task { await delegate.store.fetch() } }
                Task { await delegate.showIsland(front: phase != .background) }
            }
            .onChange(of: delegate.store.island) {
                Task { await delegate.showIsland(front: phase != .background) }
            }
            .onOpenURL { delegate.opened($0) }
            .onChange(of: delegate.store.paired != nil) { _, paired in
                if paired { delegate.askToNotify() }
            }
            .task { pairForTestIfAsked() }
        }
    }

    /// A script's pairing, for a phone build with no camera to scan with (PhoneLink+Test.swift),
    /// or a made-up Mac for screenshots (Screens.swift).
    private func pairForTestIfAsked() {
#if DEBUG
        let arguments = CommandLine.arguments
        // A default too, so a launch from a tap on a notification, which takes no arguments, has it.
        if let screen = UserDefaults.standard.string(forKey: "Screens"), let cache = Screens.cache(screen) {
            delegate.store.showForScreenshots(cache)
            if let fresh = arguments.firstIndex(of: "-IslandFresh").flatMap({ Double(arguments[$0 + 1]) }) { delegate.island.fresh = fresh }
            // The thread screen: the asking thread, pushed.
            if screen == "thread", let asking = cache.threads.first(where: { $0.status == .asking }) { delegate.router.path = [asking.id] }
            if screen == "compose" { delegate.router.composing = true }
            if screen == "reply", let done = cache.threads.first(where: { $0.reply != nil }) { delegate.router.path = [done.id] }
            if let nudge = Screens.posted { Task { await Screens.post(nudge) } }
            // What iCloud would bring a moment after a tap landed.
            if screen == "late", let full = Screens.cache("thread") {
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    delegate.store.showForScreenshots(full)
                }
            }
            if let shown = cache.threads.first(where: { $0.id == Screens.talkID }) {
                Screens.play(screen, in: delegate.store)
                delegate.router.path = [shown.id]
            }
            return
        }
        guard delegate.store.paired == nil, let at = arguments.firstIndex(of: "-PairCode"), at + 1 < arguments.count,
              let code = PairingCode(string: arguments[at + 1])
        else { return }
        Task { await delegate.store.pair(with: code) }
#endif
    }
}

/// Holds the store, takes CloudKit's pushes to it, in the background too, and the notifications'
/// buttons.
@MainActor
final class PhoneDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Where home is: a notification's tap pushes its thread.
    let router = Router()
    var island = Island()
    private var showing: Task<Void, Never>?
    let store = PhoneClient(keychain: PhoneDelegate.keychain, deviceName: UIDevice.current.model, folder: .applicationSupportDirectory) {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The keychain group the app shares with its notification extension.
    nonisolated static var keychain: PhoneKeychain {
        PhoneKeychain(group: (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String).map { $0 + "com.realmeric.oricode.phone" })
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotifyCategory.all)
        if store.paired != nil { askToNotify() }
        return true
    }

    /// Once paired. Home works without notifications, and says everything they would.
    func askToNotify() {
        guard store.paired?.phone != "phone-screenshots" || UserDefaults.standard.bool(forKey: "ScreensNotify") else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// A button on a notification: Allow, Deny or a question's option, sealed and in iCloud before
    /// the system takes the app back. Allow and an option have had Face ID already. A tap on the
    /// notification itself opens its thread. UIKit takes the end of it on the main thread only: the
    /// async form ended it from a background one, and a tap on a notification crashed the app
    /// (2026-10-27).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        var strings: [String: String] = [:]
        for (key, value) in info { if let key = key as? String, let value = value as? String { strings[key] = value } }
        nonisolated(unsafe) let done = completionHandler
        nonisolated(unsafe) let push = info
        Task { @MainActor in
            if action == UNNotificationDefaultActionIdentifier {
                await open(strings["nudge"], push: push)
            } else {
                await answered(action: action, info: strings, typed: typed)
            }
            done()
        }
    }

    /// A tap lands on exactly its thread, from a cold start too, where this runs before the first
    /// frame: the stack is replaced and any sheet goes. A notification the extension couldn't open
    /// in time has its Nudge read here.
    private func open(_ written: String?, push: [AnyHashable: Any]) async {
        let said = written.flatMap { try? JSONDecoder().decode(NudgeInfo.self, from: Data($0.utf8)) }
        var nudge = said
        if nudge == nil { nudge = await store.nudge(in: push) }
        guard let nudge else { return }
        router.composing = false
        router.path = [nudge.thread]
        await store.land(on: nudge)
    }

    private func answered(action: String, info: [String: String], typed: String?) async {
        guard let thread = info["thread"].flatMap(UUID.init(uuidString:)) else { return }
        let ask = info["ask"]
        let command: Command.Action
        switch action {
        case NotifyCategory.allow, NotifyCategory.deny:
            guard let ask else { return }
            command = .answer(ask: ask, thread: thread, allow: action == NotifyCategory.allow, choice: nil, answers: nil, message: nil)
        case NotifyCategory.answer:
            // Reply, typed on the lock screen: into the thread, as its composer would send it.
            guard let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            command = .send(thread: thread, text: text)
        case let option where option.hasPrefix(NotifyCategory.optionPrefix):
            guard let ask, let question = info["question"], let index = Int(option.dropFirst(NotifyCategory.optionPrefix.count)),
                  let label = info["option\(index)"]
            else { return }
            command = .answer(ask: ask, thread: thread, allow: true, choice: nil, answers: [question: label], message: nil)
        default:
            return
        }
        _ = await store.sendNow(command)
    }

    /// In front, the asks are on home already: the notification goes to the list alone.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await store.pushed(userInfo)
        await showIsland(front: false)
        return .newData
    }

    /// One at a time: two at once would each find none running and each start one.
    func showIsland(front: Bool) async {
        let (island, state, before) = (island, store.island, showing)
        let shown = Task {
            await before?.value
            await island.show(state, front: front)
        }
        showing = shown
        await shown.value
    }

    /// A tap on the Island or the Lock Screen: its thread, or home.
    func opened(_ url: URL) {
        guard url.scheme == IslandLink.scheme else { return }
        router.composing = false
        router.path = IslandLink.thread(in: url).map { [$0] } ?? []
    }
}

/// The stack of threads pushed over home.
@MainActor
@Observable
final class Router {
    var path: [UUID] = []
    /// The new thread's sheet is up.
    var composing = false
}
