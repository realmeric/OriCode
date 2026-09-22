import AppKit
import UniformTypeIdentifiers

/// An image waiting in the composer. Stored scaled to at most 1568px on its long edge,
/// the size the API works at, so a Retina screenshot doesn't go out at 4x.
struct ImageAttachment: Identifiable, Hashable {
    let id = UUID()
    let data: Data
    let mediaType: String
    let thumbnail: NSImage

    static let maxEdge: CGFloat = 1568

    init?(image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = CGFloat(cg.width), height = CGFloat(cg.height)
        let scale = min(1, Self.maxEdge / max(width, height))
        let size = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: cg, size: NSSize(width: width, height: height)).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        // PNG keeps screenshots of text sharp; photos that come out big go as JPEG.
        if let png = bitmap.representation(using: .png, properties: [:]), png.count < 3_500_000 {
            data = png
            mediaType = "image/png"
        } else if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            data = jpeg
            mediaType = "image/jpeg"
        } else {
            return nil
        }
        thumbnail = NSImage(cgImage: bitmap.cgImage!, size: size)
    }

    init?(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let image = NSImage(contentsOf: url)
        else { return nil }
        self.init(image: image)
    }

    /// A small JPEG kept with the user's message, so the transcript can show what was sent.
    var preview: Data? {
        let edge: CGFloat = 240
        let size = thumbnail.size
        let scale = min(1, edge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let small = NSImage(size: target, flipped: false) { rect in
            self.thumbnail.draw(in: rect)
            return true
        }
        guard let tiff = small.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

extension AppModel {
    func attach(_ images: [NSImage]) {
        let added = images.compactMap(ImageAttachment.init(image:))
        guard !added.isEmpty else { return }
        draftAttachments.append(contentsOf: added)
    }

    func attach(fileAt url: URL) -> Bool {
        guard let attachment = ImageAttachment(url: url) else { return false }
        draftAttachments.append(attachment)
        return true
    }

    /// ⌘V with an image on the pasteboard and no text: the field editor would ignore it, so take it here.
    func installPasteMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v", event.window == NSApp.mainWindow, project != nil
            else { return event }
            let board = NSPasteboard.general
            guard board.string(forType: .string) == nil,
                  let images = board.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty
            else { return event }
            attach(images)
            return nil
        }
    }
}
