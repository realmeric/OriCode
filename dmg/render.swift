// Renders the background of OriCode's disk image window at 1x and 2x into background.tiff,
// which settings.py hands dmgbuild.
//
//   swift dmg/render.swift
//
// Every position is in points in a 640x400 window, y measured from the top,
// the way Finder and dmgbuild measure icon_locations. Change Layout, keep settings.py's
// icon_locations in step, and run it again.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Layout {
    static let size = CGSize(width: 640, height: 400)
    static let iconSize: CGFloat = 128
    static let app = CGPoint(x: 160, y: 184)          // icon centres, as dmgbuild takes them
    static let applications = CGPoint(x: 480, y: 184)
    // The squircle fills about 80% of a 128pt icon, so its edge is ~52pt from the centre.
    static let cueStart: CGFloat = 240
    static let cueEnd: CGFloat = 398
    static let nameBaseline: CGFloat = 362
}

struct RGB { var r, g, b: CGFloat }
let violet = RGB(r: 0.45, g: 0.33, b: 0.95)   // the icon's violet, lifted
let ember = RGB(r: 1.00, g: 0.48, b: 0.22)    // the wallpaper's orange from the brief
let base = RGB(r: 0.040, g: 0.035, b: 0.060)

func radial(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, _ color: RGB, alpha: CGFloat, squash: CGFloat = 1) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // Eased falloff: a plain two-stop gradient leaves a visible rim.
    var colors: [CGColor] = []
    var stops: [CGFloat] = []
    for i in 0...12 {
        let t = CGFloat(i) / 12
        let a = alpha * pow(1 - t, 2.2)
        colors.append(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: a))
        stops.append(t)
    }
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: stops)!
    ctx.saveGState()
    ctx.translateBy(x: c.x, y: c.y)
    ctx.scaleBy(x: 1, y: squash)
    ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
    ctx.restoreGState()
}

func render(scale s: CGFloat) -> CGImage {
    let w = Int(Layout.size.width * s), h = Int(Layout.size.height * s)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Flip so y runs down from the top, as Finder's coordinates do.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: s, y: -s)
    let W = Layout.size.width, H = Layout.size.height

    ctx.setFillColor(CGColor(srgbRed: base.r, green: base.g, blue: base.b, alpha: 1))
    ctx.fill(CGRect(origin: .zero, size: Layout.size))

    // The desktop's colour coming through glass: violet behind the app, a little
    // ember low on the far side, both kept off the label row under the icons.
    radial(ctx, at: CGPoint(x: Layout.app.x - 10, y: Layout.app.y - 40), radius: 330, violet, alpha: 0.30, squash: 0.85)
    radial(ctx, at: CGPoint(x: W * 0.62, y: -60), radius: 360, violet, alpha: 0.12, squash: 0.7)
    radial(ctx, at: CGPoint(x: W + 30, y: H + 40), radius: 400, ember, alpha: 0.18, squash: 0.8)

    // A pane's sheen along the top edge.
    let sheen = CGGradient(colorsSpace: space,
                           colors: [CGColor(gray: 1, alpha: 0.035), CGColor(gray: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: .zero, end: CGPoint(x: 0, y: H * 0.45), options: [])

    // Corners fall away so the middle reads as lit.
    var vColors: [CGColor] = [], vStops: [CGFloat] = []
    for i in 0...12 {
        let t = CGFloat(i) / 12
        vColors.append(CGColor(gray: 0, alpha: 0.30 * pow(t, 2.4)))
        vStops.append(t)
    }
    let vignette = CGGradient(colorsSpace: space, colors: vColors as CFArray, locations: vStops)!
    ctx.saveGState()
    ctx.translateBy(x: W / 2, y: H * 0.46)
    ctx.scaleBy(x: 1, y: H / W * 1.15)
    ctx.drawRadialGradient(vignette, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: W * 0.72, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    drawCue(ctx, space: space)
    drawName(ctx)

    let image = ctx.makeImage()!
    return grain(image, scale: s)
}

// A fine line that gathers light toward Applications and ends in an open chevron.
func drawCue(_ ctx: CGContext, space: CGColorSpace) {
    let y = Layout.app.y
    let x0 = Layout.cueStart, x1 = Layout.cueEnd
    let head: CGFloat = 7
    let line = CGMutablePath()
    line.move(to: CGPoint(x: x0, y: y))
    line.addLine(to: CGPoint(x: x1, y: y))
    line.move(to: CGPoint(x: x1 - head, y: y - head))
    line.addLine(to: CGPoint(x: x1, y: y))
    line.addLine(to: CGPoint(x: x1 - head, y: y + head))

    let trail = CGGradient(colorsSpace: space,
                           colors: [CGColor(gray: 1, alpha: 0),
                                    CGColor(gray: 1, alpha: 0.22),
                                    CGColor(gray: 1, alpha: 0.62)] as CFArray,
                           locations: [0, 0.55, 1])!

    // A soft bloom under the stroke, then the stroke.
    for (width, alpha) in [(CGFloat(4), CGFloat(0.05)), (1.5, 1)] {
        ctx.saveGState()
        ctx.addPath(line)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.setAlpha(alpha)
        ctx.drawLinearGradient(trail, start: CGPoint(x: x0, y: y), end: CGPoint(x: x1, y: y), options: [])
        ctx.restoreGState()
    }
}

func drawName(_ ctx: CGContext) {
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    // One quiet line, so it reads as the window's footer and not as a third label.
    let footer = NSMutableAttributedString(string: "OriCode", attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: NSColor(white: 1, alpha: 0.62),
        .kern: 0.15,
    ])
    footer.append(NSAttributedString(string: "   A native window for coding agents", attributes: [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
        .foregroundColor: NSColor(white: 1, alpha: 0.32),
        .kern: 0.1,
    ]))
    let size = footer.size()
    let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    // NSAttributedString draws from the top of its line box in a flipped context.
    footer.draw(at: CGPoint(x: (Layout.size.width - size.width) / 2, y: Layout.nameBaseline - font.ascender))

    NSGraphicsContext.restoreGraphicsState()
}

// Faint deterministic grain, so 8-bit gradients this dark don't band.
func grain(_ image: CGImage, scale: CGFloat) -> CGImage {
    let w = image.width, h = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var seed: UInt64 = 0x0D1C0DE
    for i in 0..<(w * h) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let n = Int((seed >> 33) % 5) - 2   // -2...2
        for c in 0..<3 {
            let v = Int(p[i * 4 + c]) + n
            p[i * 4 + c] = UInt8(max(0, min(255, v)))
        }
        p[i * 4 + 3] = 255
    }
    return ctx.makeImage()!
}

func write(_ image: CGImage, to path: String, dpi: CGFloat) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "could not write \(path)")
}

let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("oricode-dmg").path
try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
write(render(scale: 1), to: "\(scratch)/background.png", dpi: 72)
write(render(scale: 2), to: "\(scratch)/background@2x.png", dpi: 144)

let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck", "\(scratch)/background.png", "\(scratch)/background@2x.png", "-out", "\(dir)/background.tiff"]
try tiff.run()
tiff.waitUntilExit()
precondition(tiff.terminationStatus == 0, "tiffutil failed")
print("wrote \(dir)/background.tiff")
