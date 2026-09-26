import AppKit
import Highlightr
import MarkdownUI
import SwiftUI

/// Syntax colours, muted to five kinds: keyword, string, number, comment, name. Highlightr
/// can only load its bundled themes, so it renders with Atom One Dark and each of that
/// theme's colours is mapped onto one of ours; anything unmapped is plain ink.
actor CodeHighlighter {
    static let shared = CodeHighlighter()

    /// The app's one Highlightr, for the review's hunks and the transcript's code blocks alike:
    /// each loads highlight.js into a JavaScriptCore context of its own, 7MB more for a second.
    /// It's made on first use and taken by one thread at a time.
    private nonisolated(unsafe) static let highlightr: Highlightr? = {
        let highlightr = Highlightr()
        _ = highlightr?.setTheme(to: "atom-one-dark")
        highlightr?.theme.setCodeFont(.monospacedSystemFont(ofSize: 12.5, weight: .regular))
        return highlightr
    }()
    private static let lock = NSLock()

    nonisolated static func render(_ code: String, as language: String?) -> NSAttributedString? {
        lock.withLock { highlightr?.highlight(code, as: language, fastRender: true) }
    }

    enum Kind {
        case keyword, string, number, comment, name, plain
    }

    // Atom One Dark's palette, by what each colour is used for.
    private nonisolated static let atom: [(r: Int, g: Int, b: Int, kind: Kind)] = [
        (0xC6, 0x78, 0xDD, .keyword),
        (0x98, 0xC3, 0x79, .string),
        (0xD1, 0x9A, 0x66, .number),
        (0x5C, 0x63, 0x70, .comment),
        (0x61, 0xAE, 0xEE, .name),
        (0xE6, 0xC0, 0x7B, .name),
        (0xE0, 0x6C, 0x75, .plain),
        (0x56, 0xB6, 0xC2, .plain),
        (0xAB, 0xB2, 0xBF, .plain),
    ]

    nonisolated static func color(_ kind: Kind) -> NSColor {
        switch kind {
        case .keyword: NSColor(red: 0.80, green: 0.74, blue: 0.93, alpha: 0.95)
        case .string: NSColor(red: 0.86, green: 0.82, blue: 0.68, alpha: 0.95)
        case .number: NSColor(red: 0.92, green: 0.78, blue: 0.70, alpha: 0.95)
        case .comment: NSColor(white: 1, alpha: 0.38)
        case .name: NSColor(red: 0.74, green: 0.84, blue: 0.93, alpha: 0.95)
        case .plain: NSColor(white: 1, alpha: 0.88)
        }
    }

    func highlight(_ code: String, language: String?) -> AttributedString {
        let plain = AttributedString(code, attributes: AttributeContainer([
            .foregroundColor: Self.color(.plain),
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
        ]))
        guard code.utf8.count < 400_000, let rendered = Self.render(code, as: language) else { return plain }
        return Self.mute(rendered) ?? plain
    }

    /// Atom One Dark's colours swapped for ours, and its background dropped.
    nonisolated static func mute(_ rendered: NSAttributedString) -> AttributedString? {
        let muted = NSMutableAttributedString(attributedString: rendered)
        muted.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: muted.length))
        muted.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: muted.length)) { value, range, _ in
            let kind = (value as? NSColor).map(Self.kind(of:)) ?? .plain
            muted.addAttribute(.foregroundColor, value: Self.color(kind), range: range)
        }
        return try? AttributedString(muted, including: \.appKit)
    }

    private nonisolated static func kind(of color: NSColor) -> Kind {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .plain }
        let r = Int(rgb.redComponent * 255), g = Int(rgb.greenComponent * 255), b = Int(rgb.blueComponent * 255)
        let nearest = atom.min { abs($0.r - r) + abs($0.g - g) + abs($0.b - b) < abs($1.r - r) + abs($1.g - g) + abs($1.b - b) }
        guard let nearest, abs(nearest.r - r) + abs(nearest.g - g) + abs(nearest.b - b) < 60 else { return .plain }
        return nearest.kind
    }

    nonisolated static func language(forPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == "makefile" { return "makefile" }
        if name == "dockerfile" { return "dockerfile" }
        return language(forExtension: (path as NSString).pathExtension.lowercased())
    }

    nonisolated static func language(forExtension ext: String) -> String? {
        switch ext {
        case "swift": "swift"
        case "ts", "tsx", "mts": "typescript"
        case "js", "jsx", "mjs", "cjs": "javascript"
        case "py": "python"
        case "rb": "ruby"
        case "go": "go"
        case "rs": "rust"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "c", "h": "c"
        case "cc", "cpp", "hpp", "mm": "cpp"
        case "m": "objectivec"
        case "cs": "csharp"
        case "php": "php"
        case "json": "json"
        case "yml", "yaml": "yaml"
        case "toml", "ini", "cfg": "ini"
        case "md", "markdown": "markdown"
        case "sh", "bash", "zsh": "bash"
        case "html", "xml", "plist", "svg": "xml"
        case "css", "scss": "css"
        case "sql": "sql"
        case "": nil
        default: ext
        }
    }
}

/// Code blocks in a reply still streaming show plain: the reply is drawn again on every frame,
/// and coloured code cost more to draw than all the rest of it. Each block is coloured in the
/// background as it closes, so the reply has its colours at once when it settles.
struct StreamingCodeHighlighter: CodeSyntaxHighlighter {
    let text: String

    func highlightCode(_ code: String, language: String?) -> Text {
        if !Self.isOpen(code, in: text) {
            MainActor.assumeIsolated { TranscriptCodeHighlighter.shared.prepare(code, language: language) }
        }
        return Text(code)
    }

    /// An open block runs to the end of the text, where a closed one ends in its fence.
    static func isOpen(_ code: String, in text: String) -> Bool {
        func trimmed(_ text: String) -> Substring {
            var end = text[...]
            while end.last?.isNewline == true { end = end.dropLast() }
            return end
        }
        return trimmed(text).hasSuffix(trimmed(code))
    }
}

/// Code blocks in the transcript. MarkdownUI asks from the view update, where colouring a block
/// could take several frames, so a block with no colours yet shows plain while it's coloured off
/// the main thread; the view that asked reads the block's entry and is drawn again when they're
/// in. It keeps 300 blocks, the one used longest ago going first.
@MainActor
final class TranscriptCodeHighlighter: CodeSyntaxHighlighter {
    static let shared = TranscriptCodeHighlighter()
    private static let capacity = 300

    @Observable
    final class Colours {
        var text: AttributedString?
        @ObservationIgnored var used = 0
    }

    private var cache: [String: Colours] = [:]
    private var uses = 0

    nonisolated func highlightCode(_ code: String, language: String?) -> Text {
        MainActor.assumeIsolated {
            let colours = entry(code, language: language)
            uses += 1
            colours.used = uses
            return colours.text.map(Text.init) ?? Text(code)
        }
    }

    /// Colours a block before it's asked for.
    func prepare(_ code: String, language: String?) {
        _ = entry(code, language: language)
    }

    private func entry(_ code: String, language: String?) -> Colours {
        let key = (language ?? "") + "\u{0}" + code
        if let colours = cache[key] { return colours }
        if cache.count >= Self.capacity, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key {
            cache[oldest] = nil
        }
        let colours = Colours()
        cache[key] = colours
        guard code.utf8.count < 100_000 else {
            colours.text = AttributedString(code)
            return colours
        }
        let name = language.flatMap { CodeHighlighter.language(forExtension: $0.lowercased()) }
        Task {
            let muted = await Task.detached(priority: .userInitiated) {
                CodeHighlighter.render(code, as: name).flatMap(CodeHighlighter.mute)
            }.value
            cache[key]?.text = muted ?? AttributedString(code)
        }
        return colours
    }
}
