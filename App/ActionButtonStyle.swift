import SwiftUI

/// The app's one kind of action button, in the glass's own tints and lit under the pointer so
/// it's plain what can be pressed: white at 10%, 16% under the pointer or pressed; the one Return
/// presses is white, like Send. Disabled, a button shows at 40%. Small is for headers and for
/// lines set in secondary type.
struct ActionButtonStyle: ButtonStyle {
    var prominent = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        ActionButton(configuration: configuration, prominent: prominent, small: small)
    }

    private struct ActionButton: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let small: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            let lit = enabled && (hovering || configuration.isPressed)
            configuration.label
                .font(small ? Type.secondary : Type.body)
                .lineLimit(1)
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Ink.primary)
                .padding(.horizontal, small ? 10 : 14)
                .frame(height: small ? 24 : 30)
                .background(prominent ? Color.white.opacity(lit ? 1 : 0.8) : Color.white.opacity(lit ? 0.16 : 0.10), in: .capsule)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(.capsule)
                .onHover { hovering = $0 }
                .animation(Motion.fade, value: lit)
        }
    }
}

extension ButtonStyle where Self == ActionButtonStyle {
    static var action: ActionButtonStyle { ActionButtonStyle() }

    static func action(prominent: Bool = false, small: Bool = false) -> ActionButtonStyle {
        ActionButtonStyle(prominent: prominent, small: small)
    }
}
