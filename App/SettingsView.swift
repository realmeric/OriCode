import AppKit
import SwiftUI

/// Settings on the main window's glass: native tabs and controls, laid out as the same
/// quiet cards the transcript uses, in the brief's ink.
struct SettingsView: View {
    @AppStorage(Glass.key) private var glass = Glass.defaultTint

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralPane() }
            Tab("Transcript", systemImage: "text.bubble") { TranscriptPane() }
            Tab("Notifications", systemImage: "bell") { NotificationsPane() }
            Tab("About", systemImage: "info.circle") { AboutPane() }
        }
        .frame(width: 480)
        .background(Color.black.opacity(glass).ignoresSafeArea())
        .containerBackground(for: .window) { BehindWindowGlass() }
        .preferredColorScheme(.dark)
        // Switches and the slider in grey rather than the system's accent, which the app doesn't use.
        .tint(Color(white: 0.62))
    }
}

/// A group of settings on white at 5%, apart from the next by space rather than a line.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// A label with a line under it saying what the setting does, and the control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Type.body).foregroundStyle(Ink.primary)
                if let detail {
                    Text(detail).font(Type.secondary).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
    }
}

private struct Pane<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    @AppStorage("nodePath") private var nodePath = ""

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow(title: "Glass", detail: "How much of the desktop shows through the window.") {
                    Text("\(Int((glass * 100).rounded()))%")
                        .font(Type.mono)
                        .foregroundStyle(Ink.secondary)
                        .contentTransition(.numericText())
                        .animation(Motion.fade, value: glass)
                }
                Slider(value: $glass, in: Glass.range) {
                    Text("Glass")
                } minimumValueLabel: {
                    Text("Clear").font(Type.secondary).foregroundStyle(Ink.secondary)
                } maximumValueLabel: {
                    Text("Dark").font(Type.secondary).foregroundStyle(Ink.secondary)
                }
                .labelsHidden()
            }
            SettingsCard {
                SettingsRow(title: "Node", detail: nodePath.isEmpty ? "Found on its own; it needs Node 24 or newer." : nodePath) {
                    HStack(spacing: 8) {
                        if !nodePath.isEmpty {
                            Button("Automatic") { use("") }
                        }
                        Button("Choose…", action: choose)
                    }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(filePath: "/opt/homebrew/bin")
        panel.prompt = "Use This Node"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        use(url.path)
    }

    private func use(_ path: String) {
        nodePath = path
        Task { await model.startEngine() }
    }
}

private struct TranscriptPane: View {
    @AppStorage(TranscriptSettings.showTime) private var showTime = false
    @AppStorage(TranscriptSettings.showCost) private var showCost = false

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow(title: "How long each turn took", detail: "Under each turn, beside the files it changed.") {
                    Toggle("How long each turn took", isOn: $showTime).labelsHidden().toggleStyle(.switch)
                }
                SettingsRow(title: "What each turn cost", detail: "What it would cost on the metered API, not a bill.") {
                    Toggle("What each turn cost", isOn: $showCost).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

private struct NotificationsPane: View {
    @AppStorage("notify") private var notify = true

    var body: some View {
        Pane {
            SettingsCard {
                SettingsRow(
                    title: "When a thread finishes or needs you",
                    detail: "Only while you're in another app or another thread. The Dock icon counts threads waiting on you."
                ) {
                    Toggle("Notify", isOn: $notify).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "Version \(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    private var source: URL? {
        (Bundle.main.infoDictionary?["OriCodeSource"] as? String).map { URL(filePath: $0) }
    }

    var body: some View {
        Pane {
            VStack(spacing: 10) {
                RaysMark(lit: RaysMark.rays, litOpacity: 0.62)
                    .frame(width: 56, height: 56)
                    .padding(.bottom, 4)
                Text("OriCode").font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.primary)
                Text("A native window for Claude Code.").font(Type.body).foregroundStyle(Ink.secondary)
                Text(version).font(Type.secondary).foregroundStyle(Ink.faint)
                if let source {
                    Button("Show the source") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
                        .buttonStyle(.link)
                        .foregroundStyle(Ink.secondary)
                        .font(Type.secondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
        }
    }
}
