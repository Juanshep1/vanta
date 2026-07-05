import SwiftUI

@main
struct VantaPocketApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            FilesScreen()
                .tabItem { Label("Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            VcodeScreen()
                .tabItem { Label("vcode", systemImage: "sparkles") }
            ExamplesScreen()
                .tabItem { Label("Learn", systemImage: "book") }
            SettingsScreen()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .background(Theme.bg)
        // The engine's web view must live in the window for `ask` prompts to
        // present; it is zero-size and invisible.
        .overlay(alignment: .bottomTrailing) {
            EngineHostView(engine: model.engine).frame(width: 1, height: 1).opacity(0.01)
        }
        // Visual programs (dashboards, games) open full-screen here.
        .fullScreenCover(isPresented: $model.showArtifact) {
            ArtifactScreen().environmentObject(model)
        }
    }
}

// Hosts the engine's hidden WKWebView inside the SwiftUI hierarchy. The
// engine can rebuild its web view (Stop = reboot), so this wraps it in a
// container and re-attaches whichever web view is current.
import WebKit
struct EngineHostView: UIViewRepresentable {
    @ObservedObject var engine: VantaEngine

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        attach(engine.hostView, to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if engine.hostView.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            attach(engine.hostView, to: container)
        }
    }

    private func attach(_ webView: WKWebView, to container: UIView) {
        webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        container.addSubview(webView)
    }
}
