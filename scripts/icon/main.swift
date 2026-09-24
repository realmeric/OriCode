// Renders the app icon from RaysMark, so the icon and the mark in the app are one drawing.
// Built and run by `make icon`, which passes the asset catalog's AppIcon folder.
import AppKit
import SwiftUI

struct IconArt: View {
    /// OriCode Molten's icon: the same glass before it has set, glowing from the furnace, the
    /// mark white-hot in it.
    var molten = false

    var body: some View {
        ZStack {
            // macOS's icon grid: an 824pt squircle centred on a 1024pt canvas.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(molten ? AnyShapeStyle(Self.melt) : AnyShapeStyle(Self.glass))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .fill(RadialGradient(
                            colors: [Color.white.opacity(molten ? 0.16 : 0.10), .clear],
                            center: .init(x: 0.25, y: 0.1), startRadius: 0, endRadius: 620)))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 10)
            if molten {
                RaysMark(lit: RaysMark.rays, litOpacity: 0.9, dotOpacity: 1, color: Color(red: 1, green: 0.97, blue: 0.9))
                    .frame(width: 480, height: 480)
                    .shadow(color: Color(red: 1, green: 0.78, blue: 0.35).opacity(0.95), radius: 28)
            } else {
                RaysMark(lit: RaysMark.rays, litOpacity: 0.62, dotOpacity: 1)
                    .frame(width: 480, height: 480)
            }
        }
        .frame(width: 1024, height: 1024)
    }

    private static let glass = LinearGradient(
        colors: [Color(red: 0.21, green: 0.18, blue: 0.29), Color(red: 0.09, green: 0.08, blue: 0.13)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Hottest where the mark sits, cooling to a deep red at the corners, as a gather of glass
    /// does out of the furnace.
    private static let melt = RadialGradient(
        colors: [
            Color(red: 0.96, green: 0.45, blue: 0.16),
            Color(red: 0.80, green: 0.26, blue: 0.10),
            Color(red: 0.45, green: 0.10, blue: 0.05),
            Color(red: 0.24, green: 0.05, blue: 0.04),
        ],
        center: .init(x: 0.5, y: 0.52), startRadius: 60, endRadius: 640)
}

@MainActor
func render(into folder: URL, molten: Bool) throws {
let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []

for (points, scale) in sizes {
    let pixels = points * scale
    let renderer = ImageRenderer(content: IconArt(molten: molten))
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

// Top-level code runs on the main thread; ImageRenderer insists on being told so. A second
// argument, molten, renders OriCode Molten's icon.
try MainActor.assumeIsolated {
    let folder = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try render(into: folder, molten: CommandLine.arguments.dropFirst(2).first == "molten")
}
