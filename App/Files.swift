import SwiftUI

/// A file open read-only over the transcript.
struct OpenFile: Identifiable {
    let id = UUID()
    let path: String
    /// The line a link pointed at, scrolled to and lit once the file is in.
    var line: Int?
    var code: AttributedString?
    var lines = 0
    var truncated = false
    var problem: String?
}

extension AppModel {
    func toggleFileFinder() {
        guard let chat else { return }
        withAnimation(Motion.move) {
            if fileFinderShown { fileFinderShown = false } else { openInIsland(.files) }
        }
        guard fileFinderShown else { return }
        loadProjectFiles(in: chat.cwd)
    }

    /// The folder's files as git lists them, read again each time something is about to search them.
    func loadProjectFiles(in cwd: String) {
        if projectFilesFolder != cwd {
            projectFilesFolder = cwd
            projectFiles = []
        }
        Task {
            let reply = try? await engine.request("files.list", ["cwd": .string(cwd)])
            guard projectFilesFolder == cwd else { return }
            projectFiles = reply?["files"]?.array?.compactMap(\.string) ?? []
        }
    }

    /// Opens a path from anywhere: the finder, a tool line, a diff card or a link in a reply.
    func openFile(_ path: String, line: Int? = nil) {
        guard let chat else { return }
        let cwd = chat.cwd
        let relative = ToolSummary.relative(path, to: cwd)
        // The viewer is under what grows out of the capsule, so the finder, or the review it was
        // opened from, makes way.
        if reviewShown { closeReview() }
        withAnimation(Motion.move) {
            fileFinderShown = false
            openFile = OpenFile(path: relative, line: line)
        }
        let id = openFile?.id
        Task {
            do {
                let reply = try await engine.request("files.read", ["cwd": .string(cwd), "path": .string(path)])
                let content = reply["content"]?.string ?? ""
                let code = await CodeHighlighter.shared.highlight(content, language: CodeHighlighter.language(forPath: relative))
                guard openFile?.id == id else { return }
                openFile?.code = code
                openFile?.lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
                openFile?.truncated = reply["truncated"]?.bool ?? false
            } catch {
                guard openFile?.id == id else { return }
                openFile?.problem = error.localizedDescription
            }
        }
    }

    func closeFile() {
        withAnimation(Motion.move) { openFile = nil }
    }

    /// A link clicked in a reply or a plan. A file in the thread's folder opens in the viewer at
    /// its line, one elsewhere or a folder in its own app, and the web goes to the browser.
    func openLink(_ url: URL, cwd: String) -> OpenURLAction.Result {
        guard let file = LinkedFile(url, cwd: cwd) else { return url.scheme == nil ? .discarded : .systemAction }
        var folder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &folder)
        let root = (cwd as NSString).standardizingPath
        if file.path.hasPrefix(root.hasSuffix("/") ? root : root + "/"), !folder.boolValue {
            openFile(file.path, line: file.line)
            return .handled
        }
        guard exists else { return .discarded }
        NSWorkspace.shared.open(URL(filePath: file.path))
        return .handled
    }
}

/// A file a link names, however an agent wrote it: relative to the thread's folder, absolute,
/// `~/`, or a file URL, with its line as `#L42`, `#L42-L50`, `:42` or `:42:7`.
struct LinkedFile: Equatable {
    let path: String
    let line: Int?
}

extension LinkedFile {
    /// Nil for a link that isn't a file's: the web, mail, a phone number, any other scheme.
    init?(_ url: URL, cwd: String) {
        var link = url.absoluteString
        if let scheme = url.scheme?.lowercased() {
            if scheme == "file" {
                link = url.path(percentEncoded: true) + (url.fragment(percentEncoded: true).map { "#" + $0 } ?? "")
            } else {
                // `Foo.swift:42` parses with foo.swift as its scheme. The schemes that take a
                // bare number are a phone's.
                let rest = link.dropFirst(scheme.count + 1)
                guard rest.wholeMatch(of: /\d+(:\d+)?/) != nil, !["tel", "sms", "facetime", "facetime-audio"].contains(scheme) else { return nil }
            }
        }
        var line: Int?
        if let hash = link.firstIndex(of: "#") {
            line = link[link.index(after: hash)...].prefixMatch(of: /L(\d+)/).flatMap { Int($0.1) }
            link = String(link[..<hash])
        }
        var path = link.removingPercentEncoding ?? link
        if let match = path.firstMatch(of: /:(\d+)(:\d+)?$/) {
            line = line ?? Int(match.1)
            path.removeSubrange(match.range)
        }
        guard !path.isEmpty else { return nil }
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (cwd as NSString).appendingPathComponent(path) }
        self.path = (path as NSString).standardizingPath
        self.line = line.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// ⌘P: find a file in the project by a few of its letters.
struct FileFinder: View {
    static let width: CGFloat = 560
    private static let row: CGFloat = 28
    /// The field's row, so what stands in for it is as tall.
    private static let header: CGFloat = 41
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool
    /// What has been made since it opened: nothing but the glass, then the field, then the rows a
    /// part to a frame, all behind the glass, which shows none of it until it has begun to grow.
    @State private var stage = 0
    private static let last = 4
    /// How many rows each stage shows.
    private static let rows = [0, 0, 5, 10]

    private var results: [String] {
        Array(Fuzzy.rank(model.projectFiles, by: query) { $0 }.prefix(14))
    }

    var body: some View {
        let results = stage >= 2 ? results : []
        let shown = stage >= Self.last ? results : Array(results.prefix(Self.rows[stage]))
        VStack(alignment: .leading, spacing: 6) {
            if stage < 1 {
                Color.clear.frame(height: Self.header)
            } else {
                field(results)
            }
            if stage < 2 {
                // Where the rows will be, from the files it already knows.
                Color.clear.frame(height: CGFloat(min(model.projectFiles.count, 14)) * Self.row + 8)
            } else if !results.isEmpty {
                // At most fourteen, and as tall as they are: nothing here scrolls.
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, path in
                        Button {
                            model.openFile(path)
                        } label: {
                            HStack(spacing: 8) {
                                Text((path as NSString).lastPathComponent)
                                    .font(Type.body)
                                    .foregroundStyle(Ink.primary)
                                Text((path as NSString).deletingLastPathComponent)
                                    .font(Type.secondary)
                                    .foregroundStyle(Ink.faint)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: Self.row)
                            .background(index == selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(height: CGFloat(results.count) * Self.row + 8, alignment: .top)
            }
        }
        .padding(.bottom, stage >= 2 && results.isEmpty ? 0 : 6)
        .task {
            for next in 1..<Self.last {
                try? await Task.sleep(for: .milliseconds(17))
                stage = next
            }
            try? await Task.sleep(for: .milliseconds(9))
            focused = true
            try? await Task.sleep(for: .milliseconds(300))
            stage = Self.last
        }
    }

    private func field(_ results: [String]) -> some View {
        TextField("Find a file", text: $query)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .foregroundStyle(Ink.primary)
            .focused($focused)
            .padding(.horizontal, 14)
            .frame(height: Self.header)
            // One handler for the keys: each modifier is a node SwiftUI makes on open.
            .onKeyPress(phases: [.down, .repeat]) { press in
                switch press.key {
                case .downArrow, .tab:
                    // Tab moves down the list rather than take the keyboard out of the field.
                    stage = Self.last
                    selected = min(selected + 1, max(results.count - 1, 0))
                case .upArrow:
                    stage = Self.last
                    selected = max(selected - 1, 0)
                default:
                    return .ignored
                }
                return .handled
            }
            .onSubmit { if results.indices.contains(selected) { model.openFile(results[selected]) } }
            .onChange(of: query) { selected = 0 }
    }
}

/// The file, read-only, with line numbers and muted colours.
struct FileViewer: View {
    @Environment(AppModel.self) private var model
    let file: OpenFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(file.path)
                    .font(Type.mono)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.head)
                if file.truncated {
                    Text("first 1 MB").font(Type.secondary).foregroundStyle(Ink.faint)
                }
                Spacer()
                Button("Close") { model.closeFile() }
                    .buttonStyle(.action(small: true))
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            if let problem = file.problem {
                Text(problem)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .padding(16)
            } else if let code = file.code {
                FileCode(code: code, lines: file.lines, line: file.line)
            } else {
                ProgressView().controlSize(.small).padding(16)
            }
        }
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}

/// The lines beside their numbers. The line a link named is scrolled to and lit for a moment.
private struct FileCode: View {
    let code: AttributedString
    let lines: Int
    let line: Int?
    /// Measured off the numbers, which are the same font as the code.
    @State private var lineHeight: CGFloat = 0
    @State private var lit = false
    @State private var viewport: CGFloat = 0
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 14) {
                Text((1...max(lines, 1)).map(String.init).joined(separator: "\n"))
                    .font(Type.mono)
                    .foregroundStyle(Ink.faint)
                    .multilineTextAlignment(.trailing)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height / CGFloat(max(lines, 1)) } action: { lineHeight = $0 }
                Text(code)
                    .textSelection(.enabled)
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .background(alignment: .topLeading) {
                if let line, lineHeight > 0 {
                    Surface.selected
                        .frame(height: lineHeight)
                        .opacity(lit ? 1 : 0)
                        .padding(.top, top(of: line))
                }
            }
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in viewport = height }
        .task(id: lineHeight > 0 && viewport > 0) {
            guard let line, lineHeight > 0, viewport > 0 else { return }
            // A third of the way down, with what leads up to it above.
            position.scrollTo(y: max(top(of: line) - viewport / 3, 0))
            lit = true
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.fade) { lit = false }
        }
    }

    private func top(of line: Int) -> CGFloat {
        CGFloat(min(line, max(lines, 1)) - 1) * lineHeight
    }
}
