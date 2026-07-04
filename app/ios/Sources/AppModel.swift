import SwiftUI
import Combine

struct VantaFile: Identifiable, Equatable {
    var name: String
    var id: String { name }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant, status }
    let id = UUID()
    var role: Role
    var text: String
}

@MainActor
final class AppModel: ObservableObject {
    // ---- project files (Documents/*.va and friends) ----
    @Published var files: [VantaFile] = []
    @Published var currentFile: String?

    // ---- console ----
    @Published var consoleText: String = ""
    @Published var isRunning = false
    @Published var showConsole = false

    // ---- vcode chat ----
    @Published var chat: [ChatMessage] = []
    @Published var vcodeBusy = false

    // ---- settings ----
    @Published var ai = AISettings() { didSet { saveSettings() } }
    @Published var fontSize: CGFloat = 15 { didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") } }
    @Published var autoFix = true { didSet { UserDefaults.standard.set(autoFix, forKey: "autoFix") } }

    let engine = VantaEngine()
    private var cancellables: Set<AnyCancellable> = []

    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        loadSettings()
        fontSize = CGFloat(UserDefaults.standard.double(forKey: "fontSize"))
        if fontSize < 10 { fontSize = 15 }
        if UserDefaults.standard.object(forKey: "autoFix") != nil {
            autoFix = UserDefaults.standard.bool(forKey: "autoFix")
        }
        seedIfFirstLaunch()
        refreshFiles()
        if currentFile == nil { currentFile = files.first?.name }

        engine.onOutput = { [weak self] text in
            Task { @MainActor in self?.consoleText += text }
        }
        engine.onFilesWritten = { [weak self] written in
            Task { @MainActor in
                guard let self else { return }
                for (name, content) in written where self.isSafeName(name) {
                    try? content.write(to: self.docs.appendingPathComponent(name),
                                       atomically: true, encoding: .utf8)
                }
                self.refreshFiles()
            }
        }
        engine.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        #if DEBUG
        // Test hook: SIMCTL_CHILD_POCKET_AUTORUN=<file.va> runs a file as soon
        // as the engine is ready and logs its output, so the whole pipeline
        // can be exercised from the command line.
        if let autorun = ProcessInfo.processInfo.environment["POCKET_AUTORUN"] {
            Task { @MainActor in
                while engine.state != .ready && engine.state != .failed {
                    try? await Task.sleep(for: .milliseconds(300))
                }
                guard engine.state == .ready else { NSLog("POCKET_AUTORUN: engine failed"); return }
                let output = await engine.runCollectingOutput(main: autorun, files: projectSnapshot())
                NSLog("POCKET_AUTORUN output >>>\n%@\n<<<", output)
            }
        }
        #endif
    }

    // ---- file management ----

    func refreshFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? []
        files = names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { VantaFile(name: $0) }
        if let current = currentFile, !files.contains(where: { $0.name == current }) {
            currentFile = files.first?.name
        }
    }

    func contents(of name: String) -> String {
        (try? String(contentsOf: docs.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    func save(_ name: String, _ content: String) {
        try? content.write(to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.hasPrefix(".")
    }

    @discardableResult
    func createFile(_ rawName: String, contents: String = "say \"hello from Vanta\"\n") -> String? {
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return nil }
        if !name.contains(".") { name += ".va" }
        guard isSafeName(name) else { return nil }
        if !FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path) {
            save(name, contents)
        }
        refreshFiles()
        currentFile = name
        return name
    }

    func deleteFile(_ name: String) {
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
        refreshFiles()
    }

    func renameFile(_ name: String, to rawNew: String) {
        var newName = rawNew.trimmingCharacters(in: .whitespaces)
        if newName.isEmpty { return }
        if !newName.contains(".") { newName += ".va" }
        guard isSafeName(newName), newName != name else { return }
        try? FileManager.default.moveItem(at: docs.appendingPathComponent(name),
                                          to: docs.appendingPathComponent(newName))
        if currentFile == name { currentFile = newName }
        refreshFiles()
    }

    private func seedIfFirstLaunch() {
        let key = "seeded-v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        for example in bundledExamples() {
            let dest = docs.appendingPathComponent(example.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: example, to: dest)
            }
        }
    }

    func bundledExamples() -> [URL] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "va", subdirectory: "examples")
            ?? Bundle.main.urls(forResourcesWithExtension: "va", subdirectory: nil)
            ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // ---- running ----

    func projectSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        for file in files {
            snapshot[file.name] = contents(of: file.name)
        }
        return snapshot
    }

    func run(_ name: String) {
        guard !isRunning else { return }
        consoleText = ""
        showConsole = true
        isRunning = true
        run_start = Date()
        engine.run(main: name, files: projectSnapshot()) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                let seconds = String(format: "%.1f", -self.run_start.timeIntervalSinceNow)
                self.consoleText += code == 0
                    ? "\n· finished in \(seconds)s\n"
                    : "\n· stopped\n"
            }
        }
    }
    private var run_start = Date()

    func stopRun() {
        guard isRunning else { return }
        engine.restart()
        isRunning = false
    }

    // ---- vcode: the coding agent ----

    func sendToVcode(_ prompt: String) {
        guard !vcodeBusy else { return }
        chat.append(ChatMessage(role: .user, text: prompt))
        guard !ai.apiKey.isEmpty else {
            chat.append(ChatMessage(role: .status,
                text: "vcode needs an API key — add your Anthropic or OpenRouter key in Settings."))
            return
        }
        vcodeBusy = true
        Task { await vcodeTurn() }
    }

    private func vcodeTurn() async {
        defer { vcodeBusy = false }
        var history: [[String: String]] = chat.compactMap { message in
            switch message.role {
            case .user: return ["role": "user", "content": message.text]
            case .assistant: return ["role": "assistant", "content": message.text]
            case .status: return nil
            }
        }
        let maxRounds = autoFix ? 3 : 1
        for round in 1...maxRounds {
            let reply: String
            do {
                reply = try await AIClient.chat(system: AISystemPrompt.pocketSystem,
                                                history: history, settings: ai)
            } catch {
                chat.append(ChatMessage(role: .status, text: "vcode error: \(error.localizedDescription)"))
                return
            }
            chat.append(ChatMessage(role: .assistant, text: reply))
            history.append(["role": "assistant", "content": reply])

            guard let code = Self.extractCode(reply) else { return }
            let name = createFile("vcode.va", contents: code) ?? "vcode.va"
            save(name, code)
            refreshFiles()

            guard autoFix else { return }
            chat.append(ChatMessage(role: .status, text: "running \(name)…"))
            consoleText = ""
            let output = await engine.runCollectingOutput(main: name, files: projectSnapshot())
            let failed = output.contains("Oops!") || output.contains("Internal error")
            let shown = output.count > 2000 ? String(output.suffix(2000)) : output
            chat.append(ChatMessage(role: .status,
                text: (failed ? "✗ error — " : "✓ ran clean — ") + "output:\n" + (shown.isEmpty ? "(no output)" : shown)))
            if !failed || round == maxRounds { return }
            history.append(["role": "user",
                            "content": "I ran that and got this output:\n\(shown)\nPlease fix the program and send the COMPLETE corrected file in a ```va block."])
        }
    }

    static func extractCode(_ reply: String) -> String? {
        guard let fence = reply.range(of: "```") else { return nil }
        var rest = String(reply[fence.upperBound...])
        if let newline = rest.firstIndex(of: "\n") {
            let lang = rest[..<newline].trimmingCharacters(in: .whitespaces)
            if lang.count <= 10 { rest = String(rest[rest.index(after: newline)...]) }
        }
        guard let close = rest.range(of: "```") else { return nil }
        let code = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code + "\n"
    }

    // ---- settings persistence ----

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(ai) {
            UserDefaults.standard.set(data, forKey: "ai-settings")
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "ai-settings"),
           let settings = try? JSONDecoder().decode(AISettings.self, from: data) {
            ai = settings
        }
    }
}
