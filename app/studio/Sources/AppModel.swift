import SwiftUI
import AppKit

struct VFile: Identifiable, Equatable {
    let id = UUID()
    var url: URL?
    var name: String
    var content: String
    var dirty: Bool = false
    static func == (a: VFile, b: VFile) -> Bool { a.id == b.id }
}

struct AIMessage: Identifiable {
    let id = UUID()
    let role: String      // "user" | "assistant"
    let text: String
}

final class AppModel: ObservableObject {
    @Published var files: [VFile] = []
    @Published var activeID: UUID?
    @Published var console: String = ""
    @Published var isRunning = false
    @Published var statusText = "Ready"

    @Published var aiMessages: [AIMessage] = []
    @Published var aiInput = ""
    @Published var aiBusy = false
    @Published var settings = AISettings()

    private let runner = PythonRunner()
    private let settingsKey = "vanta-studio-ai-settings"

    init() {
        loadSettings()
        let starter = """
        # Welcome to Vanta Studio — the native Mac IDE for Vanta.
        # This runs your code natively (real python3, not WebAssembly) — fast.
        # Press the Run button or Cmd-R.

        say "Hello from a native Mac app!"

        let squares be [n * n for each n in range(1, 8)]
        say "Squares: {to_json(squares)}"

        to greet(who, greeting be "Hey")
            give back "{greeting}, {who}!"
        end
        say greet("Vanta")

        # Ask Vee (the panel on the right) to write something for you.
        """
        files = [VFile(url: nil, name: "welcome.va", content: starter)]
        activeID = files.first?.id
    }

    // MARK: files

    var activeFile: VFile? { files.first { $0.id == activeID } }

    func updateActiveContent(_ newValue: String) {
        guard let idx = files.firstIndex(where: { $0.id == activeID }) else { return }
        if files[idx].content != newValue {
            files[idx].content = newValue
            files[idx].dirty = true
        }
    }

    func newFile() {
        let f = VFile(url: nil, name: "untitled-\(files.count + 1).va", content: "say \"hi\"\n")
        files.append(f)
        activeID = f.id
    }

    func select(_ id: UUID) { activeID = id }

    func closeFile(_ id: UUID) {
        files.removeAll { $0.id == id }
        if activeID == id { activeID = files.last?.id }
        if files.isEmpty { newFile() }
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = []
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { openURL(url) }
        }
    }

    func openURL(_ url: URL) {
        if let existing = files.first(where: { $0.url == url }) { activeID = existing.id; return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let f = VFile(url: url, name: url.lastPathComponent, content: content)
        files.append(f)
        activeID = f.id
    }

    func loadExample(_ url: URL) {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let f = VFile(url: nil, name: url.lastPathComponent, content: content)
        files.append(f)
        activeID = f.id
    }

    @discardableResult
    func save() -> Bool {
        guard let idx = files.firstIndex(where: { $0.id == activeID }) else { return false }
        if let url = files[idx].url {
            try? files[idx].content.write(to: url, atomically: true, encoding: .utf8)
            files[idx].dirty = false
            statusText = "Saved \(files[idx].name)"
            return true
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = files[idx].name
        if panel.runModal() == .OK, let url = panel.url {
            try? files[idx].content.write(to: url, atomically: true, encoding: .utf8)
            files[idx].url = url
            files[idx].name = url.lastPathComponent
            files[idx].dirty = false
            statusText = "Saved \(files[idx].name)"
            return true
        }
        return false
    }

    // MARK: running

    private var vantaPyURL: URL? {
        Bundle.main.url(forResource: "vanta", withExtension: "py", subdirectory: "runtime")
    }

    var examples: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "va", subdirectory: "examples") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func run() {
        guard let vpy = vantaPyURL else {
            console += "⚠️  Bundled vanta.py not found.\n"; return
        }
        guard let file = activeFile else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-studio-run.va")
        try? file.content.write(to: tmp, atomically: true, encoding: .utf8)
        console = ""
        isRunning = true
        statusText = "Running \(file.name)…"
        let started = Date()
        runner.run(vantaPy: vpy, sourceFile: tmp,
            onOutput: { [weak self] s in self?.console += s },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.statusText = code == 0 ? "Finished in \(ms) ms" : "Exited with code \(code)"
            })
    }

    func stop() {
        runner.stop()
        isRunning = false
        statusText = "Stopped"
        console += "\n⏹  stopped\n"
    }

    func sendInput(_ line: String) {
        console += line + "\n"
        runner.sendInput(line)
    }

    // MARK: AI (Vee)

    func systemPrompt() -> String {
        let code = activeFile?.content ?? ""
        return AISystemPrompt.base + "\n\nThe user's current file (\(activeFile?.name ?? "untitled")):\n" + code
    }

    func askVee(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !aiBusy else { return }
        aiInput = ""
        aiMessages.append(AIMessage(role: "user", text: text))
        if settings.apiKey.isEmpty {
            aiMessages.append(AIMessage(role: "assistant", text: "Add an API key in ⚙ AI Settings and I can write Vanta for you. (OpenRouter, Anthropic, Ollama Cloud, or NVIDIA — native calls, no CORS limits.)"))
            return
        }
        aiBusy = true
        var history = aiMessages.suffix(12).map { ["role": $0.role, "content": $0.text] }
        let sys = systemPrompt()
        let s = settings
        Task { [weak self] in
            do {
                let reply = try await AIClient.chat(system: sys, history: Array(history), settings: s)
                await MainActor.run {
                    self?.aiMessages.append(AIMessage(role: "assistant", text: reply))
                    self?.aiBusy = false
                }
            } catch {
                await MainActor.run {
                    self?.aiMessages.append(AIMessage(role: "assistant", text: "Error: \(error.localizedDescription)"))
                    self?.aiBusy = false
                }
            }
        }
        _ = history
    }

    func applyCode(_ code: String, toNewFile: Bool) {
        if toNewFile {
            let f = VFile(url: nil, name: "vee-\(files.count + 1).va", content: code)
            files.append(f); activeID = f.id
        } else {
            updateActiveContent(code)
            // force the editor to refresh by reassigning content
            if let idx = files.firstIndex(where: { $0.id == activeID }) {
                files[idx].content = code
            }
        }
    }

    // MARK: settings persistence

    func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: settingsKey)
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: settingsKey),
           let s = try? JSONDecoder().decode(AISettings.self, from: data) {
            settings = s
        }
    }
}
