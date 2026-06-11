import SwiftUI

// The entire app is this window plus the WebView. All the actual content —
// the Vanta language and the CHIP-8 emulator — is the web playground, which is
// written in Vanta. This Swift shell only opens a window onto it.

@main
struct VantaPlaygroundApp: App {
    private let playgroundURL = URL(string: "https://juanshep1.github.io/vanta/playground/")!

    var body: some Scene {
        WindowGroup("Vanta") {
            WebView(url: playgroundURL)
                .frame(minWidth: 800, minHeight: 660)
        }
        .windowStyle(.titleBar)
    }
}
