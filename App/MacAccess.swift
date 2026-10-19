import AppKit
import ApplicationServices
import SwiftUI

/// Whether agents may see and use the Mac (K-290): a picture of an app's window, and clicks, keys
/// and scrolls in it, through Screen Recording and Accessibility granted to OriCode, whose children
/// the agents are. It's asked once, in a sheet at the first launch that hasn't answered, a fresh
/// install's or a 0.4 install's first 0.5.0 launch alike, and the answer stays in Settings ›
/// Agents. Off, the engine offers no agent the tools. On, nothing a permission covers is read
/// until an agent asks in a thread and the user lets it use that app.
enum MacAccess {
    static let key = "macAccess"
    static let on = "on"
    static let off = "off"

    static var isOn: Bool { UserDefaults.standard.string(forKey: key) == on }

    /// Never answered, so the sheet asks.
    static var unanswered: Bool { UserDefaults.standard.string(forKey: key) == nil }

    enum Permission: CaseIterable, Identifiable {
        case screen, accessibility

        var id: Self { self }

        var title: String {
            switch self {
            case .screen: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }

        var detail: String {
            switch self {
            case .screen: "To see a window an agent asks for."
            case .accessibility: "To click, type and scroll in an app you let it use."
            }
        }

        var icon: String {
            switch self {
            case .screen: "macwindow"
            case .accessibility: "cursorarrow.click.2"
            }
        }

        /// Whether macOS has given it to OriCode. Asking says nothing to the user and reads
        /// nothing the permission covers.
        var granted: Bool {
            switch self {
            case .screen: CGPreflightScreenCaptureAccess()
            case .accessibility: AXIsProcessTrusted()
            }
        }

        /// The pane in System Settings that turns it on.
        private var pane: URL {
            switch self {
            case .screen: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            }
        }

        /// Asks macOS to list OriCode in the pane, which it does only once OriCode has asked
        /// for the permission, and opens the pane.
        func open() {
            switch self {
            case .screen: _ = CGRequestScreenCaptureAccess()
            case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            NSWorkspace.shared.open(pane)
        }
    }
}

/// The two permissions, each with what it's for and either that it's allowed or the button that
/// opens its pane. Read again whenever OriCode comes back to the front, from System Settings
/// say, and never on a timer.
struct MacPermissionRows: View {
    @State private var granted: Set<MacAccess.Permission> = []

    var body: some View {
        ForEach(MacAccess.Permission.allCases) { permission in
            SettingsRow(title: permission.title, detail: permission.detail) {
                if granted.contains(permission) {
                    Label("Allowed", systemImage: "checkmark")
                        .font(Type.secondary)
                        .foregroundStyle(Ink.secondary)
                } else {
                    Button("Open System Settings") { permission.open() }
                        .buttonStyle(.action)
                }
            }
        }
        .onAppear(perform: read)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in read() }
    }

    private func read() {
        granted = Set(MacAccess.Permission.allCases.filter(\.granted))
    }
}

/// The one ask, a sheet on the window: what agents get with the two permissions, a way to each
/// pane, and Not now or Turn On, either of which is the answer for good.
struct MacAccessSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MacAccess.key) private var access: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Let agents see and use your Mac?")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Ink.primary)
            Text("With Screen Recording and Accessibility, an agent in a thread can take a picture of an app's window and click, type and scroll in it, to check a change in the running app, say. It asks you in the thread before it uses each app, and OriCode reads nothing these permissions cover until then.")
                .font(Type.body)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            SettingsCard { MacPermissionRows() }
                .padding(.top, 18)
            Text("Not now leaves it off and asks nothing again. It's in Settings › Agents whenever you want it.")
                .font(Type.secondary)
                .foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            HStack(spacing: 8) {
                Spacer()
                Button("Not now") { answer(MacAccess.off) }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On") { answer(MacAccess.on) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 500)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func answer(_ choice: String) {
        access = choice
        dismiss()
    }
}

/// Settings › Agents' card for it: the switch, and while it's on the two permissions.
struct MacAccessCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(MacAccess.key) private var access: String?

    var body: some View {
        SectionHeading("The Mac")
        SettingsCard {
            SettingsRow(
                title: "Agents may see and use the Mac",
                detail: "An agent in a thread can take a picture of an app's window and click, type and scroll in it. It asks you in the thread before it uses each app, and can never see or use OriCode's own windows."
            ) {
                Toggle("Agents may see and use the Mac", isOn: Binding(get: { access == MacAccess.on }, set: { on in
                    access = on ? MacAccess.on : MacAccess.off
                    if !on { model.tellMacOff() }
                }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if access == MacAccess.on {
                MacPermissionRows()
            }
        }
    }
}
