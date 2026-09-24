import Foundation
import os
import Sparkle

/// Updates from the appcast on GitHub, through Sparkle with OriCode's own quiet UI instead of
/// Sparkle's windows: once a newer release is out, a circle beside the title capsule offers it,
/// fills from the bottom as it downloads, and restarts OriCode into it on a second click.
/// Sparkle checks, downloads, verifies the EdDSA signature and installs; this only answers it.
/// Only the Release build has a feed, so OriCode Molten never updates itself into OriCode.
@MainActor @Observable
final class Updates: NSObject, SPUUserDriver {
    enum Phase: Equatable {
        case idle
        /// A newer release is out; a click downloads it.
        case available
        /// Downloading, 0 to 1, and unpacking once it's at 1.
        case downloading(Double)
        /// Unpacked and checked; a click restarts into it.
        case ready
    }

    private(set) var phase = Phase.idle
    /// The release on offer, as its notes name it: "0.2.0".
    private(set) var version = ""
    /// Its CHANGELOG entry, as plain text.
    private(set) var notes = ""
    /// Where a check you asked for says how it went: the note under the composer.
    @ObservationIgnored var say: ((String) -> Void)?

    @ObservationIgnored private var updater: SPUUpdater?
    /// Sparkle's question in waiting, answered by the circle's click.
    @ObservationIgnored private var reply: ((SPUUserUpdateChoice) -> Void)?
    @ObservationIgnored private var expected: UInt64 = 0
    @ObservationIgnored private var received: UInt64 = 0
    /// Whether the check under way came from Check for Updates…, so only that one reports "newest".
    @ObservationIgnored private var asked = false

    private static let logger = Logger(subsystem: "com.realmeric.oricode", category: "updates")

    override init() {
        super.init()
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String, !feed.isEmpty else { return }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: nil)
        do {
            try updater.start()
            self.updater = updater
        } catch {
            Self.logger.error("Sparkle didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// False in OriCode Molten, and wherever Sparkle couldn't start.
    var enabled: Bool { updater != nil }

    /// Check for Updates…
    func check() {
        asked = true
        updater?.checkForUpdates()
    }

    /// The circle: the first click downloads, the second restarts into the new version.
    func proceed() {
        guard let reply else { return }
        self.reply = nil
        if phase == .available { phase = .downloading(0) }
        reply(.install)
    }

    private var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // SUEnableAutomaticChecks in the Info.plist means this isn't asked; if it is, checks yes, profile no.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        asked = false
        version = appcastItem.displayVersionString
        notes = appcastItem.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // One already installing in the background is let finish; anything else waits for a click,
        // a download already on disk included, which the click then installs straight away.
        guard state.stage != .installing else { return reply(.install) }
        self.reply = reply
        phase = .available
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        if asked { say?("OriCode \(current) is the newest.") }
        asked = false
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        Self.logger.error("Update failed: \(error.localizedDescription, privacy: .public)")
        if asked || phase != .idle { say?("The update didn't go through: \(error.localizedDescription)") }
        asked = false
        reply = nil
        phase = .idle
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        expected = 0
        received = 0
        phase = .downloading(0)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        guard expected > 0 else { return }
        phase = .downloading(min(1, Double(received) / Double(expected)))
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .downloading(1)
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        self.reply = reply
        phase = .ready
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        reply = nil
        phase = .idle
    }
}
