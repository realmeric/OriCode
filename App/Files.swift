import SwiftUI

/// A file open read-only over the transcript.
struct OpenFile: Identifiable {
    let id = UUID()
    let path: String
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
        let cwd = chat.cwd
        Task {
            let reply = try? await engine.request("files.list", ["cwd": .string(cwd)])
            projectFiles = reply?["files"]?.array?.compactMap(\.string) ?? []
        }
    }

    /// Opens a path from anywhere: the finder, a tool line or a diff card.
    func openFile(_ path: String) {
        guard let chat else { return }
        let cwd = chat.cwd
        let relative = ToolSummary.relative(path, to: cwd)
        withAnimation(Motion.move) {
            fileFinderShown = false
            openFile = OpenFile(path: relative)
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
}

/// ⌘P: find a file in the project by a few of its letters.
struct FileFinder: View {
    static let width: CGFloat = 560
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var results: [String] {
        Array(Fuzzy.rank(model.projectFiles, by: query) { $0 }.prefix(14))
    }

    var body: some View {
        let results = results
        VStack(alignment: .leading, spacing: 6) {
            TextField("Find a file", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Ink.primary)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .onKeyPress(.downArrow) {
                    selected = min(selected + 1, max(results.count - 1, 0))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selected = max(selected - 1, 0)
                    return .handled
                }
                .onSubmit { if results.indices.contains(selected) { model.openFile(results[selected]) } }
                .onChange(of: query) { selected = 0 }
            if !results.isEmpty {
                List(Array(results.enumerated()), id: \.element) { index, path in
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
                        .frame(height: 28)
                        .background(index == selected ? Surface.selected : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: CGFloat(results.count) * 28 + 8)
            }
        }
        .padding(.bottom, results.isEmpty ? 0 : 6)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            focused = true
        }
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
                    .buttonStyle(.plain)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            if let problem = file.problem {
                Text(problem)
                    .font(Type.secondary)
                    .foregroundStyle(Ink.secondary)
                    .padding(16)
            } else if let code = file.code {
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 14) {
                        Text((1...max(file.lines, 1)).map(String.init).joined(separator: "\n"))
                            .font(Type.mono)
                            .foregroundStyle(Ink.faint)
                            .multilineTextAlignment(.trailing)
                        Text(code)
                            .textSelection(.enabled)
                            .fixedSize()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
            } else {
                ProgressView().controlSize(.small).padding(16)
            }
        }
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 14, style: .continuous))
        .background(Surface.drawer, in: .rect(cornerRadius: 14, style: .continuous))
    }
}
