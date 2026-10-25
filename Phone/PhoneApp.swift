import Link
import SwiftUI
import UIKit

@main
struct PhoneApp: App {
    @UIApplicationDelegateAdaptor private var delegate: PhoneDelegate
    @Environment(\.scenePhase) private var phase

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
            .task { pairForTestIfAsked() }
        }
    }

    /// A script's pairing, for a phone build with no camera to scan with (PhoneLink+Test.swift).
    private func pairForTestIfAsked() {
#if DEBUG
        let arguments = CommandLine.arguments
        guard delegate.store.paired == nil, let at = arguments.firstIndex(of: "-PairCode"), at + 1 < arguments.count,
              let code = PairingCode(string: arguments[at + 1])
        else { return }
        Task { await delegate.store.pair(with: code) }
#endif
    }
}

/// Holds the store, and takes CloudKit's pushes to it, in the background too.
@MainActor
final class PhoneDelegate: NSObject, UIApplicationDelegate {
    let store = PhoneClient(keychain: PhoneDelegate.keychain, deviceName: UIDevice.current.model, folder: .applicationSupportDirectory) {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The keychain group the app shares with its notification extension.
    nonisolated static var keychain: PhoneKeychain {
        PhoneKeychain(group: (Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String).map { $0 + "com.realmeric.oricode.phone" })
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await store.pushed(userInfo)
        return .newData
    }
}
