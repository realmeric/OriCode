import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Notifications", systemImage: "bell") { NotificationSettings() }
            Tab("About", systemImage: "info.circle") { AboutSettings() }
        }
        .frame(width: 460)
        .preferredColorScheme(.dark)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    @AppStorage("nodePath") private var nodePath = ""

    var body: some View {
        Form {
            Slider(value: $glass, in: Glass.range) {
                Text("Glass")
            } minimumValueLabel: {
                Text("Clear")
            } maximumValueLabel: {
                Text("Dark")
            }
            LabeledContent("Node") {
                HStack {
                    Picker("Node", selection: Binding(get: { nodePath.isEmpty ? "" : "custom" }, set: { if $0.isEmpty { use("") } })) {
                        Text("Automatic").tag("")
                        if !nodePath.isEmpty { Text(nodePath).tag("custom") }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Choose…", action: choose)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 170)
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

private struct NotificationSettings: View {
    @AppStorage("notify") private var notify = true

    var body: some View {
        Form {
            Toggle("Tell me when a thread finishes or needs me", isOn: $notify)
            Text("Only while OriCode isn't the window you're in.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 120)
    }
}

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    private var source: URL? {
        (Bundle.main.infoDictionary?["OriCodeSource"] as? String).map { URL(filePath: $0) }
    }

    var body: some View {
        Form {
            LabeledContent("Version", value: version)
            if let source {
                LabeledContent("Source") {
                    Button(source.path) { NSWorkspace.shared.activateFileViewerSelecting([source]) }
                        .buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 120)
    }
}
