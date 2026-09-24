import AppKit
import SwiftUI

/// Settings laid out like Meriç's reference: a sidebar of panes under a search field, and
/// each pane's settings in cards under quiet headings, all on the main window's glass.
struct SettingsView: View {
    @AppStorage(Glass.key) private var glass = Glass.defaultTint
    /// The pane on show, kept so ⌘K can open Settings on one.
    @AppStorage(SettingsPane.key) private var paneName = SettingsPane.general.rawValue
    @State private var query = ""

    private var pane: SettingsPane? {
        get { SettingsPane(rawValue: paneName) }
        nonmutating set { paneName = (newValue ?? .general).rawValue }
    }

    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0.matches(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: Binding(get: { pane }, set: { pane = $0 })) { pane in
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
                    case .actions: ActionsPane()
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
    case general, conversation, notifications, actions, shortcuts, about

    static let key = "settingsPane"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .conversation: "Conversation"
        case .notifications: "Notifications"
        case .actions: "Actions"
        case .shortcuts: "Shortcuts"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .conversation: "text.bubble"
        case .notifications: "bell"
        case .actions: "bolt"
        case .shortcuts: "command"
        case .about: "info.circle"
        }
    }

    /// The words a search can find a pane by: its title and what its settings are called.
    private var words: [String] {
        switch self {
        case .general: ["editor", "cursor", "zed", "xcode", "glass", "liquid glass", "system", "window", "tint", "dark", "transparency", "transparent", "clear", "frosted", "blur", "node", "engine", "new threads", "model", "effort", "permissions", "ask", "plan", "auto"]
        case .conversation: ["turn", "time", "how long", "cost", "footer", "transcript"]
        case .notifications: ["notify", "notification", "dock", "badge", "finished", "waiting"]
        case .actions: ["action", "custom", "command", "script", "placeholder", "terminal", "stash", "branch", "pull request", "tests"]
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
struct SectionHeading: View {
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
struct SettingsCard<Content: View>: View {
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
struct SettingsRow<Control: View>: View {
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
            Slider(value: magnetic, in: range) {
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

    /// The default holds the slider a moment as it passes, with a tap on the trackpad, so it can
    /// be found by feel.
    private var magnetic: Binding<Double> {
        Binding {
            value
        } set: { next in
            let band = (range.upperBound - range.lowerBound) * 0.012
            let holding = abs(next - standard) < band
            if holding, value != standard { Haptics.detent() }
            value = holding ? standard : next
        }
    }
}

extension View {
    /// A pop-up menu sized to its choice, at the right of a settings row.
    fileprivate func menuRow() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, detail: String?) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

struct PaneTitle: View {
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
    @AppStorage(Editor.key) private var editor = ""
    @AppStorage(NewThreads.model) private var newModel = ""
    @AppStorage(NewThreads.effort) private var newEffort = ""
    @AppStorage(NewThreads.fast) private var newFast = ""
    @AppStorage(NewThreads.permissionMode) private var newMode = ""
    @AppStorage("lastModel") private var lastModel = ""
    @AppStorage("lastEffort") private var lastEffort = ""
    @AppStorage("lastFast") private var lastFast = false
    @AppStorage("lastPermissionMode") private var lastMode = "default"

    var body: some View {
        PaneTitle(text: "General")
        SectionHeading("Window")
        SettingsCard {
            SliderRow(title: "Glass", detail: "At System it's your Mac's own Liquid Glass. Slide right to darken it.",
                      value: $glass, range: Glass.range, low: "System", high: "Dark", standard: Glass.defaultTint)
            SliderRow(title: "Transparency", detail: "How much of the desktop shows through sharp instead of frosted.",
                      value: $transparency, range: 0...1, low: "Frosted", high: "Clear", standard: Glass.defaultTransparency)
        }
        SectionHeading("Editor")
        SettingsCard {
            SettingsRow(title: "Open projects in", detail: "What ⌘K's Open in uses.") {
                let apps = Editor.installed
                if apps.isEmpty {
                    Text("None installed").font(Type.secondary).foregroundStyle(Ink.secondary)
                } else {
                    Picker("Editor", selection: Binding(get: { Editor.chosen?.id ?? "" }, set: { editor = $0 })) {
                        ForEach(apps, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        SectionHeading("New threads")
        SettingsCard {
            SettingsRow(title: "Model", detail: "Each of these can follow what you last picked in the composer.") {
                Picker("Model", selection: $newModel) {
                    Text(lastPicked(model.models.first { $0.id == lastModel }?.name)).tag("")
                    ForEach(model.modelGroups) { group in
                        Divider()
                        ForEach(group.models.filter { $0.needs == nil }) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                }
                .menuRow()
            }
            SettingsRow(title: "Effort", detail: effortDetail) {
                Picker("Effort", selection: $newEffort) {
                    Text(lastPicked(lastEffort.nonEmpty.map(ModelMenu.effortName) ?? "Default")).tag("")
                    Divider()
                    Text(startingOption?.defaultEffort.map { "Default (\(ModelMenu.effortName($0)))" } ?? "Default").tag(NewThreads.claudeDefault)
                    ForEach(levels, id: \.self) { level in
                        Text(ModelMenu.effortName(level)).tag(level)
                    }
                }
                .menuRow()
                .disabled(startingOption?.efforts.isEmpty == true)
            }
            SettingsRow(title: "Fast mode", detail: "Only on models that have it.") {
                Picker("Fast mode", selection: $newFast) {
                    Text(lastPicked(lastFast ? "On" : "Off")).tag("")
                    Divider()
                    Text("On").tag(NewThreads.on)
                    Text("Off").tag(NewThreads.off)
                }
                .menuRow()
            }
            SettingsRow(title: "Permissions", detail: startingMode.summary) {
                Picker("Permissions", selection: $newMode) {
                    Text(lastPicked(PermissionModeOption(rawValue: lastMode)?.title)).tag("")
                    Divider()
                    ForEach(PermissionModeOption.allCases) { option in
                        Label(option.title, systemImage: option.icon).tag(option.rawValue)
                    }
                }
                .menuRow()
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

    private var startingMode: PermissionModeOption {
        PermissionModeOption(rawValue: newMode.nonEmpty ?? lastMode) ?? .ask
    }

    private func lastPicked(_ current: String?) -> String {
        current.map { "Last picked (\($0))" } ?? "Last picked"
    }

    /// The fixed model's levels, or every level some model has while the model follows the last
    /// pick. Never Ultracode, which a new thread doesn't start in.
    private var levels: [String] {
        let options = model.models.filter { newModel.isEmpty || $0.id == newModel }
        let order = ["low", "medium", "high", "xhigh", "max"]
        return order.filter { level in options.contains { $0.levels.contains(level) } }
    }

    /// The model a new thread starts on.
    private var startingOption: ModelOption? {
        model.models.first { $0.id == (newModel.nonEmpty ?? lastModel) }
    }

    /// Where Claude Code's default lands for the model a new thread starts on.
    private var effortDetail: String {
        let starting = startingOption
        if let starting, starting.levels.isEmpty {
            return "\(ModelMenu.shortName(starting.name)) has one reasoning level."
        }
        guard let starting, let level = starting.defaultEffort else {
            return "Claude Code's default is the model's own, unless your Claude Code settings pick one."
        }
        return "Claude Code's default on \(ModelMenu.shortName(starting.name)) is \(ModelMenu.effortName(level))."
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
        SectionHeading(Build.name)
        SettingsCard {
            VStack(spacing: 10) {
                RaysMark(lit: RaysMark.rays, litOpacity: 0.62)
                    .frame(width: 60, height: 60)
                    .padding(.bottom, 4)
                Text(Build.name).font(.system(size: 20, weight: .semibold)).foregroundStyle(Ink.primary)
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
