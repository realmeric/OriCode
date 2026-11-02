import Link
import UIKit

/// A notification's round avatar: a thread speaks as a person does in Messages, drawn from what it
/// is on the Mac, the mark's six arcs in its project's colour around the project's letters. A
/// thread in no project has the mark itself, its dot in its agent's colour.
enum Avatar {
    private static let side: CGFloat = 180

    static func png(for nudge: NudgeInfo) -> Data {
        let letters = nudge.project.flatMap { $0.color == nil ? nil : $0.initials }
        let ink = uiColor(nudge.project?.color.map(Swatch.project) ?? 0xFFFFFF)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).pngData { context in
            let bounds = CGRect(x: 0, y: 0, width: side, height: side)
            let cg = context.cgContext
            uiColor(0x110F18).setFill()
            cg.fillEllipse(in: bounds)
            ink.withAlphaComponent(0.2).setFill()
            cg.fillEllipse(in: bounds)
            arcs(in: cg, color: ink.withAlphaComponent(0.9))
            if let letters {
                let font = UIFont.systemFont(ofSize: side * 0.3, weight: .bold)
                let rounded = font.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: side * 0.3) } ?? font
                let text = NSAttributedString(string: letters, attributes: [.font: rounded, .foregroundColor: ink])
                let size = text.size()
                text.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))
            } else {
                uiColor(Swatch.agent(nudge.agent ?? "")).setFill()
                let dot = side * 0.2
                cg.fillEllipse(in: bounds.insetBy(dx: (side - dot) / 2, dy: (side - dot) / 2))
            }
        }
    }

    /// As Phone/Mark.swift's rays: each centred on its sixth of the circle, a gap either side.
    private static func arcs(in cg: CGContext, color: UIColor) {
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(side * 0.035)
        cg.setLineCap(.round)
        for index in 0..<6 {
            let middle = (-90 + Double(index) * 60) * .pi / 180
            let spread = 19 * Double.pi / 180
            cg.addArc(center: CGPoint(x: side / 2, y: side / 2), radius: side * 0.39, startAngle: middle - spread, endAngle: middle + spread, clockwise: false)
            cg.strokePath()
        }
    }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
