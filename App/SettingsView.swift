import AppKit
import SwiftUI

/// Settings laid out like Meriç's reference: a sidebar of panes under a search field, and
/// each pane's settings in cards under quiet headings, all on the main window's glass.
struct SettingsView: View {
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    @State private var pane: SettingsPane? = .general
    @State private var query = ""

    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.icon)
                    .font(Type.body)
                    .padding(.vertical, 3)
                    .tag(pane)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
            .onChange(of: query) {
                // Searching moves to the first pane that still has what was typed.
                if let pane, panes.contains(pane) { return }
                pane = panes.first
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch pane ?? .general {
                    case .general: GeneralPane()
                    case .conversation: ConversationPane()
                    case .notifications: NotificationsPane()
                    case .shortcuts: ShortcutsPane()
                    case .about: AboutPane()
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .toolbar(removing: .title)
        }
        // The toolbar stays, because it carries the traffic lights, but shows nothing else.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(width: 860, height: 640)
        // The main window's material and tint, under the sidebar and the detail alike.
        .containerBackground(for: .window) {
            ZStack {
                BehindWindowGlass()
                Color.black.opacity(glass)
            }
        }
        .preferredColorScheme(.dark)
        .tint(Color(white: 0.62))
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, conversation, notifications, shortcuts, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .conversation: "Conversation"
        case .notifications: "Notifications"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .conversation: "text.bubble"
        case .notifications: "bell"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }

    /// The words a search can find a pane by: its title and what its settings are called.
    private var words: [String] {
        switch self {
        case .general: ["glass", "window", "tint", "light", "dark", "transparency", "transparent", "clear", "frosted", "blur", "node", "engine", "new threads", "model", "effort", "permissions", "ask", "plan", "auto"]
        case .conversation: ["turn", "time", "how long", "cost", "footer", "transcript"]
        case .notifications: ["notify", "notification", "dock", "badge", "finished", "waiting"]
        case .shortcuts: ["keyboard", "shortcut", "keys"] + ShortcutList.groups.flatMap { $0.rows.map(\.name) }
        case .about: ["version", "source", "oricode"]
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return ([title] + words).contains { $0.lowercased().contains(query) }
    }
}

// MARK: - Building blocks

/// A heading over a card, quieter than the settings in it.
private struct SectionHeading: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Ink.secondary)
            .padding(.top, 22)
            .padding(.bottom, 10)
    }
}

/// Rows on white at 5%, parted by hairlines inset from the leading edge.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 1)
                            .padding(.leading, 18)
                    }
                    row
                }
            }
        }
        .background(Surface.card, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// A title with a line under it saying what the setting does, and its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14)).foregroundStyle(Ink.primary)
                if let detail {
                    Text(detail).font(Type.secondary).foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

/// A setting that is a slider: what it is and does on the left, the value on the right, and the
/// slider under them between its two ends.
private struct SliderRow: View {
    let title: String
    let detail: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    /// Where the app starts; a Default button shows while the slider is anywhere else.
    let standard: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 14)).foregroundStyle(Ink.primary)
                    Text(detail).font(Type.secondary).foregroundStyle(Ink.secondary)
                }
                Spacer()
                if abs(value - standard) > 0.005 {
                    Button("Default") { withAnimation(Motion.move) { value = standard } }
                        .controlSize(.small)
                        .transition(.opacity)
                }
                Text("\(Int((value * 100).rounded()))%")
                    .font(Type.mono)
                    .foregroundStyle(Ink.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.fade, value: value)
            }
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Text(low).font(Type.secondary).foregroundStyle(Ink.secondary)
            } maximumValueLabel: {
                Text(high).font(Type.secondary).foregroundStyle(Ink.secondary)
            }
            .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .animation(Motion.fade, value: abs(value - standard) > 0.005)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, detail: String?) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

private struct PaneTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(Ink.primary)
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    @AppStorage(Glass.transparencyKey) private var transparency = Glass.defaultTransparency
    @AppStorage("nodePath") private var nodePath = ""
    @AppStorage("lastPermissionMode") private var permissionMode = "default"

    var body: some View {
        PaneTitle(text: "General")
        SectionHeading("Window")
        SettingsCard {
            SliderRow(title: "Tint", detail: "How light or dark the glass is.",
                      value: $glass, range: Glass.range, low: "Light", high: "Dark", standard: Glass.defaultTint)
            SliderRow(title: "Transparency", detail: "How much of the desktop shows through sharp instead of frosted.",
                      value: $transparency, range: 0...1, low: "Frosted", high: "Clear", standard: Glass.defaultTransparency)
        }
        SectionHeading("New threads")
        SettingsCard {
            SettingsRow(
                title: "Model and effort",
                detail: "A new thread starts on the model and effort you last picked in the composer.")
            SettingsRow(title: "Permissions", detail: selectedMode.summary) {
                Picker("Permissions", selection: $permissionMode) {
                    ForEach(PermissionModeOption.allCases) { option in
                        Label(option.title, systemImage: option.icon).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        }
        SectionHeading("Engine")
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

    private var selectedMode: PermissionModeOption {
        PermissionModeOption(rawValue: permissionMode) ?? .ask
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

private struct ConversationPane: View {
    @AppStorage(TranscriptSettings.showTime) private var showTime = false
    @AppStorage(TranscriptSettings.showCost) private var showCost = false

    var body: some View {
        PaneTitle(text: "Conversation")
        SectionHeading("Under each turn")
        SettingsCard {
            SettingsRow(title: "How long it took", detail: "Beside the files the turn changed, which always show.") {
                Toggle("How long it took", isOn: $showTime).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(title: "What it cost", detail: "What the turn would cost on the metered API, not a bill.") {
                Toggle("What it cost", isOn: $showCost).labelsHidden().toggleStyle(.switch)
            }
        }
    }
}

private struct NotificationsPane: View {
    @AppStorage("notify") private var notify = true

    var body: some View {
        PaneTitle(text: "Notifications")
        SectionHeading("When you're elsewhere")
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

private struct ShortcutsPane: View {
    var body: some View {
        PaneTitle(text: "Shortcuts")
        ForEach(ShortcutList.groups, id: \.title) { group in
            SectionHeading(group.title)
            SettingsCard {
                ForEach(group.rows, id: \.name) { row in
                    HStack {
                        Text(row.name).font(.system(size: 14)).foregroundStyle(Ink.primary)
                        Spacer()
                        Text(row.keys).font(Type.mono).foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
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
        PaneTitle(text: "About")
        SectionHeading("OriCode")
        SettingsCard {
            VStack(spacing: 10) {
                RaysMark(lit: RaysMark.rays, litOpacity: 0.62)
                    .frame(width: 60, height: 60)
                    .padding(.bottom, 4)
                Text("OriCode").font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.primary)
                Text("A native window for Claude Code.").font(Type.body).foregroundStyle(Ink.secondary)
                Text(version).font(Type.secondary).foregroundStyle(Ink.faint)
                // The folder it was built from, which a copy built elsewhere doesn't have.
                if let source, FileManager.default.fileExists(atPath: source.path) {
                    Button("Show the source") { NSWorkspace.shared.activateFileViewerSelecting([source]) }
                        .buttonStyle(.link)
                        .foregroundStyle(Ink.secondary)
                        .font(Type.secondary)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }
}
