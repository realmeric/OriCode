import SwiftUI

/// The picker's own mark, small: six arcs round a dot, the arcs lit in the head's colour while
/// workflows are on and faint while they're off. One Canvas, as RayGlyph is.
struct WorkflowsGlyph: View {
    let on: Bool
    let color: Color
    var side: CGFloat = 16

    var body: some View {
        Canvas { context, size in
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: 1.2, dy: 1.2)
            var arcs = Path()
            for index in 0..<RaysMark.rays {
                arcs.addPath(Ray(index: index, count: RaysMark.rays, gap: 26).path(in: circle))
            }
            context.stroke(arcs, with: .color(on ? color : .white.opacity(0.4)),
                           style: StrokeStyle(lineWidth: on ? 2.2 : 1.6, lineCap: .round))
            let dot = size.width * 0.28
            context.fill(Path(ellipseIn: CGRect(x: (size.width - dot) / 2, y: (size.height - dot) / 2, width: dot, height: dot)),
                         with: .color(.white.opacity(on ? 0.95 : 0.4)))
        }
        .frame(width: side, height: side)
    }
}

/// Workflows, Fast's twin beside it: the head fans each task out at the level the rail is on.
/// Off, the small mark sits faint on the card's tint; on, its arcs light in the head's colour on
/// a lit circle, as Fast's bolt does.
struct WorkflowsButton: View {
    let on: Bool
    let color: Color
    /// Workflows are off in the agent's own settings, so a click only says so.
    let blocked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            WorkflowsGlyph(on: on, color: color)
                .opacity(on || hovering ? 1 : 0.75)
                .frame(width: 30, height: 30)
                .background(on ? Color.white.opacity(0.2) : hovering ? Surface.hover : Surface.card, in: .circle)
                .shadow(color: color.opacity(on ? 0.45 : 0), radius: 8)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .opacity(blocked ? 0.35 : 1)
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: on)
        .help(blocked ? "Workflows are off in the agent's settings" : on ? "Workflows are on (W)" : "Workflows: fan each task out at this level (W)")
        .accessibilityLabel("Workflows")
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint("Fans each task out to agents at this level")
    }
}
