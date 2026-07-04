import WebKit
import UIKit

// The Vanta execution engine: a hidden WKWebView running Pyodide (CPython in
// WebAssembly) with the real vanta.py inside. Everything is served from the
// app bundle through a custom URL scheme, so it works with no network at all.
//
//   engine.run(main: "main.va", files: ["main.va": "say 1"]) { code in ... }
//
// `ask` in a program becomes window.prompt, which WKUIDelegate turns into a
// native iOS input dialog.

enum EngineState: Equatable {
    case booting, ready, running, failed
}

final class VantaEngine: NSObject, ObservableObject {
    @Published var state: EngineState = .booting

    var onOutput: ((String) -> Void)?
    var onFilesWritten: (([String: String]) -> Void)?
    private var onDone: ((Int) -> Void)?

    private var webView: WKWebView!

    override init() {
        super.init()
        buildWebView()
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: "vanta-app")
        let content = config.userContentController
        content.add(MessageTrampoline(self), name: "out")
        content.add(MessageTrampoline(self), name: "state")
        content.add(MessageTrampoline(self), name: "done")
        content.add(MessageTrampoline(self), name: "files")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        wv.uiDelegate = self
        webView = wv
        state = .booting
        wv.load(URLRequest(url: URL(string: "vanta-app://engine/runner.html")!))
    }

    // The web view must be in a window for JavaScript prompts to present, so
    // the root view tucks this zero-size view into the hierarchy.
    var hostView: WKWebView { webView }

    func run(main: String, files: [String: String], onDone: @escaping (Int) -> Void) {
        guard state == .ready else {
            onOutput?(state == .booting ? "The engine is still warming up — one moment…\n"
                                        : "The engine isn't available. Try Restart Engine in Settings.\n")
            onDone(1)
            return
        }
        self.onDone = onDone
        state = .running
        let payload: [String: Any] = ["main": main, "files": files]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            onOutput?("Couldn't encode the project.\n")
            state = .ready
            onDone(1)
            return
        }
        let js = "(() => { const p = \(json); window.vantaRun(p.main, p.files); })()"
        webView.evaluateJavaScript(js) { [weak self] _, error in
            if let error {
                // A hard crash of the web content process, usually.
                self?.onOutput?("[engine] \(error.localizedDescription)\n")
            }
        }
    }

    // Runs a program and collects everything it prints. Used by vcode so it
    // can see the output and fix its own mistakes.
    @MainActor
    func runCollectingOutput(main: String, files: [String: String]) async -> String {
        var collected = ""
        let previous = onOutput
        return await withCheckedContinuation { continuation in
            onOutput = { text in
                collected += text
                previous?(text)
            }
            run(main: main, files: files) { [weak self] _ in
                self?.onOutput = previous
                continuation.resume(returning: collected)
            }
        }
    }

    // There is no safe way to interrupt synchronous WebAssembly, so Stop
    // reboots the whole engine. It's back in a few seconds.
    func restart() {
        onDone?(130)
        onDone = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.removeFromSuperview()
        buildWebView()
    }

    fileprivate func handle(_ name: String, _ body: Any) {
        switch name {
        case "out":
            if let text = body as? String { onOutput?(text) }
        case "state":
            if let s = body as? String {
                if s == "ready" { state = .ready }
                if s == "booting" { state = .booting }
                if s == "failed" { state = .failed }
            }
        case "done":
            state = (state == .failed) ? .failed : .ready
            let code = Int(body as? String ?? "0") ?? 0
            let done = onDone
            onDone = nil
            done?(code)
        case "files":
            if let files = body as? [String: String] { onFilesWritten?(files) }
        default:
            break
        }
    }
}

// Weak-reference trampoline so the userContentController doesn't retain the
// engine in a cycle.
private final class MessageTrampoline: NSObject, WKScriptMessageHandler {
    weak var engine: VantaEngine?
    init(_ engine: VantaEngine) { self.engine = engine }
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        engine?.handle(message.name, message.body)
    }
}

// `ask` support: window.prompt / alert / confirm become native dialogs.
extension VantaEngine: WKUIDelegate {
    private func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let host = topViewController() else { completionHandler(""); return }
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let alert = UIAlertController(title: "Your program asks",
                                      message: question.isEmpty ? "Input:" : question,
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text ?? "")
        })
        host.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let host = topViewController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        host.present(alert, animated: true)
    }
}

// Serves the engine's files out of the app bundle:
//   vanta-app://engine/runner.html   -> Resources/runtime/runner.html
//   vanta-app://engine/pyodide/...   -> Resources/pyodide/...
//   vanta-app://engine/vanta.py      -> the bundled real interpreter
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path

        guard let fileURL = locate(path), let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(NSError(domain: "vanta-app", code: 404,
                                          userInfo: [NSLocalizedDescriptionKey: "not bundled: \(path)"]))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime(for: path),
                                                      "Content-Length": String(data.count),
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func locate(_ path: String) -> URL? {
        let bundle = Bundle.main
        if path == "runner.html" {
            return bundle.url(forResource: "runner", withExtension: "html", subdirectory: "runtime")
                ?? bundle.url(forResource: "runner", withExtension: "html")
        }
        if path == "vanta.py" {
            return bundle.url(forResource: "vanta", withExtension: "py")
        }
        if path.hasPrefix("pyodide/") {
            let name = String(path.dropFirst("pyodide/".count))
            if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: "pyodide") {
                return url
            }
            return bundle.url(forResource: name, withExtension: nil)
        }
        return nil
    }

    private func mime(for path: String) -> String {
        if path.hasSuffix(".html") { return "text/html; charset=utf-8" }
        if path.hasSuffix(".js") { return "text/javascript; charset=utf-8" }
        if path.hasSuffix(".mjs") { return "text/javascript; charset=utf-8" }
        if path.hasSuffix(".wasm") { return "application/wasm" }
        if path.hasSuffix(".json") { return "application/json" }
        if path.hasSuffix(".zip") { return "application/zip" }
        if path.hasSuffix(".py") { return "text/x-python; charset=utf-8" }
        return "application/octet-stream"
    }
}
