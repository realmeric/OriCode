// Renders the app icon from RaysMark, so the icon and the mark in the app are one drawing.
// Built and run by `make icon`, which passes the asset catalog's AppIcon folder.
import AppKit
import SwiftUI

struct IconArt: View {
    var body: some View {
        ZStack {
            // macOS's icon grid: an 824pt squircle centred on a 1024pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.21, green: 0.18, blue: 0.29), Color(red: 0.09, green: 0.08, blue: 0.13)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(0.10), .clear],
                            center: .init(x: 0.25, y: 0.1), startRadius: 0, endRadius: 620)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
            RaysMark(lit: RaysMark.rays, litOpacity: 0.62, dotOpacity: 1)
                .frame(width: 480, height: 480)
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(into folder: URL) throws {
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for (points, scale) in sizes {
    let pixels = points * scale
    let renderer = ImageRenderer(content: IconArt())
    renderer.scale = CGFloat(pixels) / 1024
    guard let cgImage = renderer.cgImage else { fatalError("couldn't render \(pixels)px") }
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])!
    try data.write(to: folder.appending(path: name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appending(path: "Contents.json"))
print("wrote \(images.count) icons to \(folder.path)")
}

// Top-level code runs on the main thread; ImageRenderer insists on being told so.
try MainActor.assumeIsolated {
    try render(into: URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory))
}
