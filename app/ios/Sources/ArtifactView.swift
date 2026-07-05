import SwiftUI
import WebKit

// The Artifact preview: when a Vanta program emits an HTML page — a dashboard,
// a chart, an interactive game — this renders it live and full-screen instead
// of dumping the markup into the console. Inline JS/CSS run in the web view, so
// canvas games and interactive dashboards actually work, entirely offline.
struct ArtifactScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showConsole = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if showConsole {
                    consolePane
                } else {
                    ArtifactWebView(html: model.artifactHTML ?? "",
                                    reloadToken: model.artifactReloadToken)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2).foregroundStyle(Theme.muted)
            }
            Text(model.artifactTitle)
                .font(.headline).foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer()
            Picker("", selection: $showConsole) {
                Image(systemName: "safari").tag(false)
                Image(systemName: "terminal").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 108)
            Button {
                model.artifactReloadToken &+= 1
            } label: {
                Image(systemName: "arrow.clockwise").font(.body)
            }
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var consolePane: some View {
        ScrollView {
            Text(model.consoleText.isEmpty ? "(no text output)" : model.consoleText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .textSelection(.enabled)
        }
        .background(Theme.bg)
    }
}

// Renders an HTML string in a WKWebView. Wraps bare fragments in a dark,
// mobile-friendly document so they look right without the program having to.
struct ArtifactWebView: UIViewRepresentable {
    let html: String
    var reloadToken: UInt64 = 0

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.043, green: 0.043, blue: 0.072, alpha: 1)
        webView.scrollView.backgroundColor = .clear
        context.coordinator.load(html, into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken || context.coordinator.lastHTML != html {
            context.coordinator.lastToken = reloadToken
            context.coordinator.load(html, into: webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastHTML: String?
        var lastToken: UInt64 = 0

        func load(_ html: String, into webView: WKWebView) {
            lastHTML = html
            webView.loadHTMLString(Self.wrap(html), baseURL: nil)
        }

        static func wrap(_ html: String) -> String {
            if html.range(of: "<html", options: .caseInsensitive) != nil { return html }
            return """
            <!doctype html><html><head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
            <style>
              html,body{margin:0;padding:0;min-height:100%;
                background:#0b0b14;color:#e6e9f5;
                font-family:-apple-system,system-ui,'Segoe UI',sans-serif;
                -webkit-text-size-adjust:100%}
              *{box-sizing:border-box}
            </style></head><body>
            \(html)
            </body></html>
            """
        }
    }
}
