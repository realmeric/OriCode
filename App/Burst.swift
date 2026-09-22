import SwiftUI

/// Claude's mark as kullanym-notch draws it: twelve rays at two lengths. A shape written
/// in code rather than traced from anyone's artwork.
struct Burst: Shape {
    var rays = 12
    /// How far the short rays reach compared to the long ones.
    var shortReach: CGFloat = 0.66
    /// A ray's width, as a fraction of the radius.
    var thickness: CGFloat = 0.19
    /// Where a ray starts; the hole keeps the rays from merging at small sizes.
    var inner: CGFloat = 0.16

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let stroke = radius * thickness
        var spokes = Path()
        for ray in 0..<rays {
            let angle = Double(ray) / Double(rays) * 2 * .pi - .pi / 2
            let out = CGPoint(x: cos(angle), y: sin(angle))
            let reach = radius * (ray.isMultiple(of: 2) ? 1 : shortReach) - stroke / 2
            spokes.move(to: CGPoint(x: centre.x + out.x * radius * inner, y: centre.y + out.y * radius * inner))
            spokes.addLine(to: CGPoint(x: centre.x + out.x * reach, y: centre.y + out.y * reach))
        }
        return spokes.strokedPath(StrokeStyle(lineWidth: stroke, lineCap: .round))
    }
}
