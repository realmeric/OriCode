import SwiftUI

/// The Mac's mark, a dot inside six arcs, as RaysMark draws it: lit rays are agents at work in the
/// thread, each in its agent's colour. It turns while the thread works and its dot pulses while it
/// asks, only while it's on screen, and with Reduce Motion it stays still.
struct Mark: View {
    /// The lit rays, by where they stand, each with its colour.
    var lit: [Int: Color] = [:]
    var turning = false
    var asking = false
    var dot: Color = .white
    var dotOpacity = 0.92
    var restingOpacity = 0.3
    @Environment(\.accessibilityReduceMotion) private var still
    @State private var angle = 0.0
    @State private var pulsed = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let width = max(1.2, side * 0.085)
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    Ray(index: index)
                        .stroke(lit[index] ?? .white, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .opacity(lit[index] == nil ? restingOpacity : 0.92)
                        .padding(width / 2)
                }
                .rotationEffect(.degrees(angle))
                Circle().fill(dot)
                    .opacity(pulsed ? dotOpacity * 0.35 : dotOpacity)
                    .frame(width: side * 0.3, height: side * 0.3)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .onAppear(perform: move)
        .onChange(of: turning) { move() }
        .onChange(of: asking) { move() }
        .onChange(of: still) { move() }
        .onDisappear {
            angle = 0
            pulsed = false
        }
        .accessibilityHidden(true)
    }

    private func move() {
        let turns = turning && !still
        withAnimation(turns ? .linear(duration: 9).repeatForever(autoreverses: false) : .easeOut(duration: 0.18)) {
            angle = turns ? 360 : 0
        }
        let pulses = asking && !still
        withAnimation(pulses ? .easeInOut(duration: 0.9).repeatForever() : .easeOut(duration: 0.18)) {
            pulsed = pulses
        }
    }
}

/// One of the arcs, centred on its sixth of the circle with a gap either side.
struct Ray: Shape {
    let index: Int

    func path(in rect: CGRect) -> Path {
        let middle = -90 + Double(index) * 60
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
            startAngle: .degrees(middle - 19), endAngle: .degrees(middle + 19), clockwise: false)
        return path
    }
}
