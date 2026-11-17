import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A picture to look at closely, AppKit's magnifying scroll view around it: fitted to start, a
/// pinch or ⌘+ and ⌘− zoom up to eight times its pixels, ⌘0 shows its actual pixels, a double
/// click goes between fitted and actual pixels where it's clicked, and its context menu shows
/// the file in Finder or opens it in the app the Mac opens it with.
struct PictureView: NSViewRepresentable {
    let picture: NSImage
    let file: URL?

    func makeNSView(context: Context) -> PictureScroll {
        let view = PictureScroll()
        view.show(picture)
        view.file = file
        return view
    }

    func updateNSView(_ view: PictureScroll, context: Context) {
        if view.picture !== picture { view.show(picture) }
        view.file = file
    }
}

extension PictureView {
    static func reveal(_ file: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    static func open(_ file: URL) {
        NSWorkspace.shared.open(file)
    }

    /// "Open with Preview", named for the app that would open it, as Quick Look says it.
    static func openTitle(_ file: URL) -> String {
        title(NSWorkspace.shared.urlForApplication(toOpen: file))
    }

    /// The same for a kind of picture, before its file is found.
    static func openTitle(_ type: UTType) -> String {
        title(NSWorkspace.shared.urlForApplication(toOpen: type))
    }

    private static func title(_ app: URL?) -> String {
        app.map { "Open with \($0.deletingPathExtension().lastPathComponent)" } ?? "Open"
    }
}

final class PictureScroll: NSScrollView {
    private(set) var picture: NSImage?
    var file: URL?
    private let canvas = PictureCanvas()
    /// Fitted to the view as it's resized, until the picture is zoomed.
    private var fitting = true

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        contentView = CenteringClip()
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        maxMagnification = 8
        documentView = canvas
        canvas.scroll = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ picture: NSImage) {
        self.picture = picture
        canvas.layer?.contents = picture
        sizeCanvas()
        fitting = true
        needsLayout = true
    }

    /// One of the picture's pixels to one of the screen's at magnification 1. Its size is in
    /// pixels, as the viewer decodes it.
    private func sizeCanvas() {
        guard let picture else { return }
        let scale = window?.backingScaleFactor ?? 2
        canvas.frame = NSRect(origin: .zero, size: NSSize(width: picture.size.width / scale, height: picture.size.height / scale))
    }

    /// The whole picture in view, never drawn larger than a pixel to a point, as it was before
    /// it could be zoomed.
    private var fit: CGFloat {
        let size = canvas.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        let scale = window?.backingScaleFactor ?? 2
        return min(scale, bounds.width / size.width, bounds.height / size.height)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sizeCanvas()
        needsLayout = true
    }

    /// Run whenever the view's size changes, which SwiftUI sets without asking for a layout.
    override func tile() {
        super.tile()
        guard bounds.width > 0, bounds.height > 0 else { return }
        minMagnification = min(fit, 1)
        if fitting, abs(magnification - fit) > 0.001 { magnification = fit }
    }

    override func layout() {
        super.layout()
        tile()
    }

    override func magnify(with event: NSEvent) {
        fitting = false
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        toggle(at: canvas.convert(event.locationInWindow, from: nil))
    }

    /// Fitted to actual pixels at the point, and actual pixels or any other zoom back to fitted.
    func toggle(at point: NSPoint) {
        if fitting || abs(magnification - fit) < 0.001 {
            zoom(to: 1, at: point)
        } else {
            fitting = true
            magnification = fit
        }
    }

    private func zoom(to level: CGFloat, at point: NSPoint? = nil) {
        fitting = false
        let level = min(max(level, minMagnification), maxMagnification)
        let visible = contentView.documentVisibleRect
        setMagnification(level, centeredAt: point ?? NSPoint(x: visible.midX, y: visible.midY))
    }

    /// ⌘+, ⌘− and ⌘0 while the picture is up, whichever view has the keyboard: nothing else in
    /// the app takes them, and SwiftUI doesn't hand key equivalents down to a view of AppKit's,
    /// so a monitor lives for as long as the picture is in a window.
    private var keys: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        guard window != nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === window, zoomKey(event) else { return event }
            return nil
        }
    }

    private func zoomKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .numericPad, .function]) == .command
        else { return false }
        switch event.charactersIgnoringModifiers {
        case "=", "+": zoom(to: magnification * 1.5)
        case "-": zoom(to: magnification / 1.5)
        case "0": zoom(to: 1)
        default: return false
        }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        if let file {
            menu.addItem(Item("Show in Finder") { PictureView.reveal(file) })
            menu.addItem(Item(PictureView.openTitle(file)) { PictureView.open(file) })
            menu.addItem(.separator())
        }
        let point = canvas.convert(event.locationInWindow, from: nil)
        menu.addItem(Item("Actual Size") { [weak self] in self?.zoom(to: 1, at: point) })
        menu.addItem(Item("Zoom to Fit") { [weak self] in
            guard let self else { return }
            fitting = true
            magnification = fit
        })
        return menu
    }

    /// A menu item that runs a closure, which it keeps.
    private final class Item: NSMenuItem {
        private let run: () -> Void

        init(_ title: String, _ run: @escaping () -> Void) {
            self.run = run
            super.init(title: title, action: #selector(fire), keyEquivalent: "")
            target = self
        }

        @available(*, unavailable)
        required init(coder: NSCoder) { fatalError() }

        @objc private func fire() { run() }
    }
}

/// The picture itself, drawn by its layer, which takes the double click and passes the
/// right click to the scroll view's menu.
final class PictureCanvas: NSView {
    weak var scroll: PictureScroll?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// A drag on the picture doesn't take the window with it.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            scroll?.toggle(at: convert(event.locationInWindow, from: nil))
        } else {
            super.mouseDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        scroll?.menu(for: event)
    }
}

/// Keeps a picture smaller than the view in its middle.
private final class CenteringClip: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if rect.height > document.frame.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}
