import AppKit
import SwiftUI
import WebKit

/// A fenced `svg` block at the top level of a reply, which the transcript draws where it stands.
enum Drawing {
    /// The SVG of a block that is one fenced `svg` block and nothing else, and whether its fence
    /// has closed.
    static func source(of block: String) -> (svg: String, closed: Bool)? {
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard let first = lines.popFirst() else { return nil }
        let opening = first.drop { $0 == " " }
        guard first.count - opening.count <= 3, let mark = opening.first, mark == "`" || mark == "~" else { return nil }
        let fence = opening.prefix { $0 == mark }
        let info = opening.dropFirst(fence.count).split(whereSeparator: \.isWhitespace).first
        guard fence.count >= 3, info?.lowercased() == "svg" else { return nil }
        var body: [Substring] = []
        while let line = lines.popFirst() {
            let closing = line.drop { $0 == " " }
            let run = closing.prefix { $0 == mark }
            if run.count >= fence.count, closing.dropFirst(run.count).allSatisfy(\.isWhitespace) {
                // What follows a closed fence is another block's, which the split gave its own.
                guard lines.allSatisfy({ $0.allSatisfy(\.isWhitespace) }) else { return nil }
                return (body.joined(separator: "\n"), true)
            }
            body.append(line)
        }
        return (body.joined(separator: "\n"), false)
    }
}

/// Draws SVG with WebKit, AppKit's own reader dropping markers, weights and tspans: one web view,
/// off screen, made when a drawing first needs it and let go a few seconds after the last, so a
/// thread without drawings starts no WebKit process. Page scripts are off, every load is blocked
/// and nothing is kept, so a drawing can only be what its text says.
@MainActor
final class DrawingPress {
    static let shared = DrawingPress()

    /// The widest a drawing is laid out: the transcript's column inside its card.
    static let width: CGFloat = 732

    private let drawn = NSCache<NSString, NSImage>()
    /// What WebKit couldn't draw, which stays code without being tried again.
    private let refused = NSCache<NSString, NSNull>()
    private var printing: [String: Task<NSImage?, Never>] = [:]
    private var last: Task<NSImage?, Never>?
    private var web: WKWebView?
    private let loads = Loads()
    private var rest: Task<Void, Never>?

    private init() {
        drawn.totalCostLimit = 64 << 20
    }

    /// A drawing already made, without waiting.
    func image(for svg: String) -> NSImage? {
        drawn.object(forKey: svg as NSString)
    }

    func refuses(_ svg: String) -> Bool {
        refused.object(forKey: svg as NSString) != nil
    }

    /// The drawing, made once however many views ask, one at a time through the one web view.
    func draw(_ svg: String) async -> NSImage? {
        if let image = image(for: svg) { return image }
        if refuses(svg) { return nil }
        if let task = printing[svg] { return await task.value }
        let before = last
        let task = Task { () -> NSImage? in
            _ = await before?.value
            let image = await self.print(svg)
            self.printing[svg] = nil
            if let image {
                self.drawn.setObject(image, forKey: svg as NSString, cost: Int(image.size.width * image.size.height) * 16)
            } else {
                self.refused.setObject(NSNull(), forKey: svg as NSString)
            }
            self.restSoon()
            return image
        }
        printing[svg] = task
        last = task
        return await task.value
    }

    private func print(_ svg: String) async -> NSImage? {
        rest?.cancel()
        guard svg.range(of: "<svg", options: .caseInsensitive) != nil, let web = await view() else { return nil }
        let page = """
        <!doctype html><meta charset="utf-8"><style>
        html, body { margin: 0; background: transparent; color: rgba(255, 255, 255, 0.92); font: 13px -apple-system, sans-serif }
        svg { display: block; max-width: 100%; height: auto }
        </style>
        """
        guard await loads.finish({ web.loadHTMLString(page + svg, baseURL: nil) }) else { return nil }
        // A drawing with no width of its own is as wide as its viewBox says, and one with no
        // viewBox gets its own size as one, so the column can scale it down rather than cut it.
        let measure = """
        (() => {
          const svg = document.querySelector("svg");
          if (!svg) return null;
          const box = svg.viewBox.baseVal;
          if (box && box.width > 0) {
            if (!svg.hasAttribute("width")) svg.setAttribute("width", box.width);
          } else {
            const own = svg.getBoundingClientRect();
            if (own.width > 0 && own.height > 0) svg.setAttribute("viewBox", `0 0 ${own.width} ${own.height}`);
          }
          const rect = svg.getBoundingClientRect();
          return [rect.width, rect.height];
        })()
        """
        guard let size = try? await web.evaluateJavaScript(measure) as? [Double], size.count == 2, size[0] >= 1, size[1] >= 1 else { return nil }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: size[0], height: min(size[1], 4000))
        guard let data = try? await web.pdf(configuration: configuration) else { return nil }
        return Self.bitmap(of: data)
    }

    /// The PDF's one page as pixels at the screen's scale, so scrolling past it draws nothing again.
    private static func bitmap(of pdf: Data) -> NSImage? {
        guard let page = NSPDFImageRep(data: pdf) else { return nil }
        let size = page.bounds.size
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)), pixelsHigh: Int((size.height * scale).rounded(.up)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: pixels) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        page.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        pixels.size = size
        let image = NSImage(size: size)
        image.addRepresentation(pixels)
        return image
    }

    private func view() async -> WKWebView? {
        if let web { return web }
        let store = WKContentRuleListStore.default()
        let block = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        // Without the rule that blocks every load there is no drawing.
        guard let rules = try? await store?.compileContentRuleList(forIdentifier: "drawing", encodedContentRuleList: block) else { return nil }
        if let web { return web }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(rules)
        let made = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 400), configuration: configuration)
        made.setValue(false, forKey: "drawsBackground")
        made.navigationDelegate = loads
        web = made
        return made
    }

    /// Lets the web view, and WebKit's processes with it, go once nothing has been drawn for a while.
    private func restSoon() {
        rest?.cancel()
        rest = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, printing.isEmpty else { return }
            web = nil
        }
    }

    /// One load at a time, and whether it finished.
    private final class Loads: NSObject, WKNavigationDelegate {
        private var waiting: CheckedContinuation<Bool, Never>?

        func finish(_ load: () -> Void) async -> Bool {
            await withCheckedContinuation { continuation in
                waiting = continuation
                load()
            }
        }

        private func end(_ finished: Bool) {
            waiting?.resume(returning: finished)
            waiting = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { end(true) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { end(false) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { end(false) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { end(false) }
    }
}

/// A reply's `svg` block as its drawing on a card. While the block still streams, and while the
/// drawing is being made, one quiet line says so; a block WebKit can't draw shows as the code it is.
struct DrawingBlock<Code: View>: View {
    let svg: String
    /// The fence has closed, so the SVG is whole.
    let closed: Bool
    @ViewBuilder let code: Code
    @State private var image: NSImage?
    @State private var refused: Bool

    init(svg: String, closed: Bool, @ViewBuilder code: () -> Code) {
        self.svg = svg
        self.closed = closed
        self.code = code()
        _image = State(initialValue: closed ? DrawingPress.shared.image(for: svg) : nil)
        _refused = State(initialValue: closed && DrawingPress.shared.refuses(svg))
    }

    var body: some View {
        if refused {
            code
        } else if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: image.size.width)
                .padding(14)
                .background(Surface.card, in: .rect(cornerRadius: 14, style: .continuous))
                .contextMenu {
                    Button("Copy Image") { copy { $0.writeObjects([image]) } }
                    Button("Copy SVG") { copy { $0.setString(svg, forType: .string) } }
                }
                .accessibilityLabel("Drawing")
                .blockMargin(top: 4, bottom: 12)
                .transition(.opacity)
        } else {
            HStack(spacing: 6) {
                Text("Drawing…")
                ProgressView().controlSize(.mini).tint(Ink.secondary)
            }
            .font(Type.secondary)
            .foregroundStyle(Ink.secondary)
            .blockMargin(top: 4, bottom: 12)
            .task(id: closed) {
                guard closed else { return }
                let drawn = await DrawingPress.shared.draw(svg)
                withAnimation(Motion.fade) {
                    image = drawn
                    refused = drawn == nil
                }
            }
        }
    }

    private func copy(_ write: (NSPasteboard) -> Void) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        write(pasteboard)
    }
}
