import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What an agent's Mac tools ask the app for (engine/mac.ts), each an event answered with
/// `app.reply`: the apps running, which app a name means, a picture of one of its windows, and a
/// click, text, a key or a scroll in it. The engine asks the user before the first call on an
/// app in a thread; here the switch in Settings › Agents is checked again, OriCode's own windows
/// are refused, and macOS's two permissions are checked before each use, never read ahead.
@MainActor
enum MacHands {
    static let asks: Set<String> = ["mac.apps", "mac.find", "mac.screenshot", "mac.click", "mac.type", "mac.key", "mac.scroll"]

    /// The longer side of a picture at most, the size Claude reads an image at without shrinking it.
    static let longest: CGFloat = 1568

    /// The window a thread last took a picture of in an app, and how its points became the
    /// picture's pixels, by thread and bundle id: a click's point is in that picture.
    private struct Seen {
        let window: CGWindowID
        let scale: CGFloat
    }

    private static var seen: [String: Seen] = [:]

    static func answer(_ event: EngineEvent, from thread: UUID) async throws -> JSON {
        guard MacAccess.isOn else { throw refused("The user hasn't let agents see and use the Mac. It's in OriCode's Settings › Agents, theirs to turn on.") }
        let body = event.body
        switch event.name {
        case "mac.apps":
            return ["apps": .array(apps().map { ["name": .string($0.localizedName ?? ""), "bundleId": .string($0.bundleIdentifier ?? ""), "front": .bool($0.isActive)] })]
        case "mac.find":
            let app = try find(body["app"]?.string ?? "")
            return ["name": .string(app.localizedName ?? ""), "bundleId": .string(app.bundleIdentifier ?? "")]
        default:
            break
        }
        let bundleId = body["bundleId"]?.string ?? ""
        let app = try find(bundleId)
        let key = "\(thread.uuidString)|\(bundleId)"
        switch event.name {
        case "mac.screenshot":
            return try await picture(of: app, window: body["window"]?.string, key: key)
        case "mac.click":
            let point = try place(body, in: app, key: key)
            try await forward(app, window: seen[key]?.window)
            try uncovered(app, at: point)
            click(at: point, right: body["button"]?.string == "right", times: body["clicks"]?.int == 2 ? 2 : 1)
            return ["clicked": .bool(true), "app": .string(app.localizedName ?? "")]
        case "mac.type":
            try trusted(to: "type")
            try await forward(app, window: seen[key]?.window)
            try await type(body["text"]?.string ?? "", into: app)
            return ["typed": .bool(true), "app": .string(app.localizedName ?? "")]
        case "mac.key":
            try trusted(to: "press a key")
            let keys = body["keys"]?.string ?? ""
            guard let (code, flags) = Self.keys(keys) else { throw refused("OriCode doesn't know the key \(keys). Name one as cmd+, or return, letters and digits as themselves.") }
            try await forward(app, window: seen[key]?.window)
            press(code, flags: flags)
            return ["pressed": .string(keys), "app": .string(app.localizedName ?? "")]
        case "mac.scroll":
            let point = try place(body, in: app, key: key)
            try await forward(app, window: seen[key]?.window)
            try uncovered(app, at: point)
            scroll(at: point, down: body["down"]?.int ?? 0, right: body["right"]?.int ?? 0)
            return ["scrolled": .bool(true), "app": .string(app.localizedName ?? "")]
        default:
            throw refused("OriCode doesn't know what \(event.name) asks for.")
        }
    }

    // MARK: - Which app

    /// The apps with windows a person can use, OriCode itself left out.
    private static func apps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != NSRunningApplication.current.processIdentifier && $0.bundleIdentifier != nil
        }
    }

    /// The app a name means: its bundle id, its name, or a name that has it, in that order, among
    /// the other apps. A name that only OriCode itself has is refused as its own, where a click
    /// could answer the agent's own ask.
    private static func find(_ named: String) throws -> NSRunningApplication {
        let wanted = named.trimmingCharacters(in: .whitespaces)
        let running = apps()
        let found = running.first { $0.bundleIdentifier?.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? running.first { $0.localizedName?.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? running.first { $0.localizedName?.localizedCaseInsensitiveContains(wanted) == true }
        if let found { return found }
        let current = NSRunningApplication.current
        if [current.bundleIdentifier, current.localizedName].contains(where: { $0?.caseInsensitiveCompare(wanted) == .orderedSame }) {
            throw refused("OriCode never lets an agent see or use its own windows: a click there could answer what it asks the user.")
        }
        throw refused("No app called \(wanted) is running. list_apps lists the ones that are.")
    }

    // MARK: - Seeing

    private static func picture(of app: NSRunningApplication, window title: String?, key: String) async throws -> JSON {
        let name = app.localizedName ?? "that app"
        guard CGPreflightScreenCaptureAccess() else {
            throw refused("OriCode doesn't have Screen Recording, so it can't see \(name). Tell the user to turn OriCode on in System Settings › Privacy & Security › Screen & System Audio Recording, which Settings › Agents opens, and to reopen OriCode.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let order = frontToBack()
        let all = content.windows
            .filter { $0.owningApplication?.processID == app.processIdentifier && $0.windowLayer == 0 && $0.frame.width >= 40 && $0.frame.height >= 40 }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
        let windows = unsheeted(all, frame: \.frame)
        guard let front = windows.first else { throw refused("\(name) has no window on screen.") }
        let titles = windows.map { $0.title ?? "" }
        var chosen = front
        if let title = title?.nonEmpty {
            guard let named = windows.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(title) }) else {
                throw refused("\(name) has no window called \(title). Its windows: \(titles.map { $0.isEmpty ? "(untitled)" : $0 }.joined(separator: ", ")).")
            }
            chosen = named
        }
        let frame = chosen.frame
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) ?? content.displays.first else {
            throw refused("\(name)'s window isn't on a display.")
        }
        // The app's windows alone, as they lie over each other where the chosen one is: what a
        // person sees of it, with no other app's window in front.
        let scale = min(1, longest / max(frame.width, frame.height))
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int((frame.width * scale).rounded())
        configuration.height = Int((frame.height * scale).rounded())
        configuration.showsCursor = false
        let filter = SCContentFilter(display: display, including: all)
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw refused("OriCode couldn't make a picture of \(name)'s window.")
        }
        seen[key] = Seen(window: chosen.windowID, scale: scale)
        return [
            "image": .string(jpeg.base64EncodedString()),
            "mimeType": .string("image/jpeg"),
            "app": .string(name),
            "window": .string(chosen.title ?? ""),
            "windows": .array(titles.map(JSON.string)),
            "width": .number(Double(image.width)),
            "height": .number(Double(image.height)),
        ]
    }

    /// The windows that aren't a sheet or a popover, each of which is a window of its own inside
    /// another's bigger frame, drawn with it. Two windows filling the same frame, zoomed or tiled
    /// to Fill, are both kept.
    nonisolated static func unsheeted<Window>(_ windows: [Window], frame: (Window) -> CGRect) -> [Window] {
        windows.filter { window in
            !windows.contains { frame($0) != frame(window) && frame($0).contains(frame(window)) }
        }
    }

    /// The on-screen windows' places, front first, by id. Ids and bounds are what any app may read
    /// of another's windows; their titles and pixels aren't.
    private static func frontToBack() -> [CGWindowID: Int] {
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var order: [CGWindowID: Int] = [:]
        for (index, window) in listed.enumerated() {
            if let id = window[kCGWindowNumber as String] as? CGWindowID { order[id] = index }
        }
        return order
    }

    private static func bounds(of window: CGWindowID) -> CGRect? {
        guard let listed = CGWindowListCopyWindowInfo([.optionIncludingWindow], window) as? [[String: Any]],
              let bounds = listed.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    // MARK: - Using

    /// A point in the app's latest picture, on the screen where its window is now.
    private static func place(_ body: JSON, in app: NSRunningApplication, key: String) throws -> CGPoint {
        try trusted(to: "click or scroll")
        let name = app.localizedName ?? "that app"
        guard let seen = seen[key] else { throw refused("Take a screenshot of \(name) first: a point is in the pixels of its latest picture.") }
        guard let frame = bounds(of: seen.window) else { throw refused("The window of \(name)'s latest picture has closed. Take another screenshot.") }
        let x = (body["x"]?.double ?? 0) / seen.scale
        let y = (body["y"]?.double ?? 0) / seen.scale
        guard x <= frame.width, y <= frame.height else {
            throw refused("That point is outside the picture, which is \(Int(frame.width * seen.scale)) by \(Int(frame.height * seen.scale)) pixels.")
        }
        return CGPoint(x: frame.minX + x, y: frame.minY + y)
    }

    private static func trusted(to act: String) throws {
        guard AXIsProcessTrusted() else {
            throw refused("OriCode doesn't have Accessibility, so it can't \(act). Tell the user to turn OriCode on in System Settings › Privacy & Security › Accessibility, which Settings › Agents opens.")
        }
    }

    /// The app in front with the window of its latest picture over its others, waited for up to a
    /// second, so what's posted lands there. Events go to whatever is in front, so if it's still
    /// another app, or OriCode, where a Return could answer the agent's own ask, nothing is posted.
    private static func forward(_ app: NSRunningApplication, window: CGWindowID?) async throws {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        if !app.isActive {
            app.activate()
            AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        if let window, let frame = bounds(of: window), let raised = axWindow(of: element, at: frame) {
            AXUIElementPerformAction(raised, kAXRaiseAction as CFString)
        }
        let deadline = ContinuousClock.now + .seconds(1)
        while !inFront(app), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        // A moment more for the window raised to come over the app's others.
        try await Task.sleep(for: .milliseconds(100))
        try stillInFront(app)
    }

    private static func inFront(_ app: NSRunningApplication) -> Bool {
        !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    private static func stillInFront(_ app: NSRunningApplication) throws {
        guard inFront(app) else {
            throw refused("\(app.localizedName ?? "That app") isn't in front, so nothing was done in it: what's in front would have taken it. Take another screenshot and try again.")
        }
    }

    /// Refuses a point that another app's window covers, OriCode's above all: the first window over
    /// it, front to back, has to be the app's. Another app's window above the normal level, a menu
    /// bar extra's panel say, is passed over, since it may let clicks through; OriCode's never is.
    private static func uncovered(_ app: NSRunningApplication, at point: CGPoint) throws {
        let current = NSRunningApplication.current.processIdentifier
        let listed = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in listed {
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  CGRect(dictionaryRepresentation: bounds)?.contains(point) == true
            else { continue }
            let owner = window[kCGWindowOwnerPID as String] as? pid_t
            if owner == app.processIdentifier { return }
            if owner != current, (window[kCGWindowLayer as String] as? Int ?? 0) != 0 { continue }
            let over = owner == current ? "OriCode's window" : "\(window[kCGWindowOwnerName as String] as? String ?? "another app")'s window"
            throw refused("\(over) is over that point in \(app.localizedName ?? "the app"), so nothing was done. Take another screenshot and try again.")
        }
        throw refused("\(app.localizedName ?? "The app") has no window at that point. Take another screenshot.")
    }

    /// The app's Accessibility window in the same place as a window it has on screen.
    private static func axWindow(of app: AXUIElement, at frame: CGRect) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var position: CFTypeRef?
            var size: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &size) == .success
            else { return false }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            AXValueGetValue(position as! AXValue, .cgPoint, &origin)
            AXValueGetValue(size as! AXValue, .cgSize, &extent)
            return abs(origin.x - frame.minX) < 2 && abs(origin.y - frame.minY) < 2 && abs(extent.width - frame.width) < 2
        }
    }

    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func click(at point: CGPoint, right: Bool, times: Int) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        for count in 1...times {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Text as key events carrying it, with the app checked to be still in front before each.
    private static func type(_ text: String, into app: NSRunningApplication) async throws {
        for chunk in chunks(text) {
            try stillInFront(app)
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                event?.post(tap: .cghidEventTap)
            }
            // A turn of the run loop, where macOS says which app is in front now.
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Text as UTF-16 runs of at most twenty units, the most one event takes, made of whole
    /// characters so an emoji's surrogate pair is never split between two events.
    nonisolated static func chunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var chunk: [UInt16] = []
        for character in text {
            let units = Array(character.utf16)
            if !chunk.isEmpty, chunk.count + units.count > 20 {
                chunks.append(chunk)
                chunk = []
            }
            chunk += units
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        return chunks
    }

    private static func press(_ code: CGKeyCode, flags: CGEventFlags) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func scroll(at point: CGPoint, down: Int, right: Int) {
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(-down), wheel2: Int32(-right), wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Keys

    /// A key as press_key names it, `cmd+shift+k`, as its virtual key code on a US layout and
    /// its modifiers; nil for a name it doesn't know.
    nonisolated static func keys(_ named: String) -> (CGKeyCode, CGEventFlags)? {
        var parts = named.lowercased().split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "cmd++" is the plus key.
        if named.hasSuffix("++") { parts = parts.dropLast(2) + ["+"] }
        guard let last = parts.popLast(), !last.isEmpty else { return nil }
        var flags: CGEventFlags = []
        for modifier in parts {
            switch modifier {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "option", "opt", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: return nil
            }
        }
        guard let code = codes[last] else { return nil }
        return (code, flags)
    }

    nonisolated private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "+": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f10": 109, "f12": 111,
        "home": 115, "pageup": 116, "forwarddelete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    private static func refused(_ why: String) -> AppModel.Refused {
        AppModel.Refused(why: why)
    }
}
