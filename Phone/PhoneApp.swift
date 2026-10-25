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
            .preferredColorScheme(.dark)
            .onChange(of: phase) { _, phase in
                if phase == .active { Task { await delegate.store.fetch() } }
            }
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
        if let at = arguments.firstIndex(of: "-Screens"), at + 1 < arguments.count, let cache = Screens.cache(arguments[at + 1]) {
            delegate.store.showForScreenshots(cache)
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
        guard store.paired?.phone != "phone-screenshots" else { return }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// In front, the asks are on home already: the notification goes to the list alone.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await store.pushed(userInfo)
        return .newData
    }
}
