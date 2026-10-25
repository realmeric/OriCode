import SwiftUI

@main
struct PhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                Mark().frame(width: 44, height: 44)
            }
            .preferredColorScheme(.dark)
        }
    }
}
