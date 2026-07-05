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
    // What actually goes to the model (e.g. with attached file contents);
    // `text` is what the user sees in the bubble.
    var payload: String? = nil
}

struct RunError: Equatable {
    var file: String
    var line: Int
    var message: String
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
    @Published var lastError: RunError?
    @Published var fixingWithAI = false
    // A rendered visual output (dashboard / chart / game) — set when a run
    // emits an HTML page, shown full-screen in the Artifact preview.
    @Published var artifactHTML: String?
    @Published var artifactTitle = "Preview"
    @Published var showArtifact = false
    @Published var artifactReloadToken: UInt64 = 0
    // Bumped when something outside the editor rewrites the open file (AI fix,
    // vcode). The editor watches this and reloads its text so on-screen code
    // always reflects the change, even if the text binding didn't propagate.
    @Published var editorReloadToken: UInt64 = 0

    // ---- vcode chat ----
    @Published var chat: [ChatMessage] = []
    @Published var vcodeBusy = false
    // The file vcode is currently building. Follow-up edits ("add a score",
    // "make it blue") keep editing THIS file instead of spawning a new one.
    @Published var vcodeProjectFile: String?

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
        // Test hook: reproduce the "deleted file pops back up" bug — create a
        // file, simulate the editor autosaving it, delete it, then autosave
        // again (as a stale editor would on disappear). It must stay deleted.
        if ProcessInfo.processInfo.environment["POCKET_DELETETEST"] != nil {
            let name = "delete_probe.va"
            createFile(name, contents: "say \"hi\"\n")
            autosave(name, "say \"edited\"\n")
            deleteFile(name)
            autosave(name, "say \"resave attempt\"\n")     // the old bug path
            let back = FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path)
            NSLog("POCKET_DELETETEST result: file_back=%@ (expect false)", back ? "true" : "false")
        }

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
                consoleText = output
                lastError = Self.parseError(from: output, file: autorun)
                presentArtifactIfAny(from: output, title: autorun)
                NSLog("POCKET_AUTORUN output >>>\n%@\n<<<", output)
                // POCKET_AUTOFIX exercises the AI-fix path (with a local fake
                // repair) so the live editor update can be verified headlessly.
                if ProcessInfo.processInfo.environment["POCKET_AUTOFIX"] != nil, lastError != nil {
                    try? await Task.sleep(for: .seconds(2))
                    fixWithAI(file: autorun, source: contents(of: autorun)) { _ in }
                }
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
        tombstoned.remove(name)
    }

    // The editor autosaves as you type / when it closes. It must never
    // re-CREATE a file: if the file was deleted while its editor was still on
    // screen, saving it back is the "deleted project pops up again" bug. So
    // autosave only writes to a file that still exists (and isn't tombstoned).
    func autosave(_ name: String, _ content: String) {
        guard !tombstoned.contains(name),
              FileManager.default.fileExists(atPath: docs.appendingPathComponent(name).path) else { return }
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
        tombstoned.insert(name)
        try? FileManager.default.removeItem(at: docs.appendingPathComponent(name))
        if vcodeProjectFile == name { vcodeProjectFile = nil }
        refreshFiles()
    }

    // Files the user just deleted; guards against a stale editor resaving them.
    private var tombstoned: Set<String> = []

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
        lastError = nil
        artifactHTML = nil
        run_start = Date()
        engine.run(main: name, files: projectSnapshot()) { [weak self] code in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                self.lastError = Self.parseError(from: self.consoleText, file: name)
                let seconds = String(format: "%.1f", -self.run_start.timeIntervalSinceNow)
                self.consoleText += code == 0
                    ? "\n· finished in \(seconds)s\n"
                    : "\n· stopped\n"
                if self.lastError != nil { Haptics.warning() } else if code == 0 { Haptics.success() }
                self.presentArtifactIfAny(from: self.consoleText, title: name)
            }
        }
    }
    private var run_start = Date()

    // If a run's output is (or contains) an HTML page, capture it as a visual
    // artifact and open the full-screen preview.
    func presentArtifactIfAny(from output: String, title: String) {
        if let html = Self.extractHTML(from: output) {
            artifactHTML = html
            artifactTitle = title
            artifactReloadToken &+= 1
            showArtifact = true
            Haptics.tap()
        }
    }

    static func extractHTML(from output: String) -> String? {
        for marker in ["<!doctype html", "<html"] {
            if let r = output.range(of: marker, options: .caseInsensitive) {
                let html = String(output[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return html.isEmpty ? nil : html
            }
        }
        // A bare fragment that clearly renders (canvas / svg / a closed tag).
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<"), trimmed.count > 12,
           trimmed.contains("</") || trimmed.contains("/>") {
            return trimmed
        }
        return nil
    }

    // Vanta errors look like "Oops! line 12: some message".
    static func parseError(from output: String, file: String) -> RunError? {
        for rawLine in output.split(separator: "\n").reversed() {
            let line = String(rawLine)
            guard line.hasPrefix("Oops!") else { continue }
            if let match = line.range(of: #"line (\d+): (.+)$"#, options: .regularExpression) {
                let bits = String(line[match]).dropFirst("line ".count)
                let parts = bits.split(separator: ":", maxSplits: 1)
                if let number = Int(parts[0].trimmingCharacters(in: .whitespaces)), parts.count == 2 {
                    return RunError(file: file, line: number,
                                    message: parts[1].trimmingCharacters(in: .whitespaces))
                }
            }
            return RunError(file: file, line: 0,
                            message: String(line.dropFirst("Oops!".count)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // One-tap repair: send the file + the error to the model, get the whole
    // corrected file back, save it, and run it again.
    func fixWithAI(file: String, source: String, onFixed: @escaping (String) -> Void) {
        guard !fixingWithAI, let error = lastError else { return }
        #if DEBUG
        let fakeFix = ProcessInfo.processInfo.environment["POCKET_FAKEFIX"] != nil
        #else
        let fakeFix = false
        #endif
        guard !ai.apiKey.isEmpty || fakeFix else {
            consoleText += "\n✨ AI fix needs an API key — add one in Settings.\n"
            return
        }
        fixingWithAI = true
        let describe = error.line > 0 ? "line \(error.line): \(error.message)" : error.message
        Task { @MainActor in
            defer { fixingWithAI = false }
            let fixed: String
            do {
                if fakeFix {
                    // Deterministic local repair for tests: fix the classic
                    // lenth->length typo so the editor update can be observed.
                    fixed = source.replacingOccurrences(of: "lenth(", with: "length(")
                } else {
                    let user = """
                    This Vanta program (\(file)) fails with:
                    \(describe)

                    THE FILE:
                    \(source)

                    Return the COMPLETE corrected file as raw Vanta code — no fences, no commentary.
                    """
                    let reply = try await AIClient.chat(system: AISystemPrompt.fixSystem,
                                                        history: [["role": "user", "content": user]],
                                                        settings: ai)
                    let cleaned = AIClient.stripThinking(reply)
                    fixed = AIClient.stripFences(cleaned).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                }
            } catch {
                consoleText += "\n✨ AI fix failed: \(error.localizedDescription)\n"
                return
            }
            // Apply the fix to the editor FIRST and let SwiftUI paint it, so
            // the corrected code visibly replaces the old text before the
            // re-run kicks off.
            save(file, fixed)
            lastError = nil
            onFixed(fixed)
            editorReloadToken &+= 1
            await Task.yield()
            run(file)
        }
    }

    func stopRun() {
        guard isRunning else { return }
        engine.restart()
        isRunning = false
    }

    // ---- vcode: the coding agent ----

    // The project vcode is working on this session. Follow-up edits target it
    // automatically so "add a score" edits the same file instead of making a
    // new one. Editor files are brought in explicitly with the 📎 button.
    var activeProjectFile: String? {
        guard let f = vcodeProjectFile, files.contains(where: { $0.name == f }) else { return nil }
        return f
    }

    func sendToVcode(_ prompt: String, attachments rawAttachments: [String] = []) {
        guard !vcodeBusy else { return }
        // Auto-include the project vcode is working on so follow-up edits keep
        // editing the SAME file instead of spawning a new one.
        var attachments = rawAttachments
        if attachments.isEmpty, let active = activeProjectFile {
            attachments = [active]
        }
        let target = attachments.first ?? vcodeProjectFile
        if let target { vcodeProjectFile = target }

        var payload = prompt
        var shown = prompt
        if !attachments.isEmpty {
            shown += "\n📎 " + attachments.joined(separator: ", ")
            for name in attachments {
                payload += "\n\n--- project file: \(name) ---\n\(contents(of: name))"
            }
            if let target {
                payload += "\n\nThis is edit is for the EXISTING project `\(target)`. Return the COMPLETE updated file in ONE ```va block whose first line is `# file: \(target)`. Do NOT create a new file, and do NOT split it into separate files — keep the whole app (including any HTML/CSS/JS) in `\(target)`."
            } else {
                payload += "\n\nWhen you change or extend one of these files, send its COMPLETE new contents in a ```va block whose first line is `# file: <name>`."
            }
        }
        chat.append(ChatMessage(role: .user, text: shown, payload: payload))
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
            case .user: return ["role": "user", "content": message.payload ?? message.text]
            case .assistant: return ["role": "assistant", "content": message.text]
            case .status: return nil
            }
        }
        let maxRounds = autoFix ? 3 : 1
        for round in 1...maxRounds {
            let reply: String
            do {
                let raw = try await AIClient.chat(system: AISystemPrompt.pocketSystem,
                                                  history: history, settings: ai)
                reply = AIClient.stripThinking(raw)
            } catch {
                chat.append(ChatMessage(role: .status, text: "vcode error: \(error.localizedDescription)"))
                return
            }
            chat.append(ChatMessage(role: .assistant, text: reply))
            history.append(["role": "assistant", "content": reply])

            let blocks = Self.extractFiles(reply)
            guard !blocks.isEmpty else { return }
            var saved: [String] = []
            for block in blocks {
                // An untagged block edits the project already in progress
                // rather than spawning a brand-new vcode.va every turn.
                let name = block.name ?? vcodeProjectFile ?? "vcode.va"
                guard isSafeName(name) else { continue }
                save(name, block.code)
                saved.append(name)
            }
            refreshFiles()
            editorReloadToken &+= 1
            guard let runTarget = saved.first else { return }
            vcodeProjectFile = runTarget
            currentFile = runTarget
            if saved.count > 1 {
                chat.append(ChatMessage(role: .status, text: "saved " + saved.joined(separator: ", ")))
            }

            guard autoFix else { return }
            chat.append(ChatMessage(role: .status, text: "running \(runTarget)…"))
            consoleText = ""
            let output = await engine.runCollectingOutput(main: runTarget, files: projectSnapshot())
            let failed = output.contains("Oops!") || output.contains("Internal error")
            let hasArtifact = !failed && Self.extractHTML(from: output) != nil
            let shown = output.count > 2000 ? String(output.suffix(2000)) : output
            let note: String
            if hasArtifact {
                note = "✓ ran clean — opening the preview…"
                presentArtifactIfAny(from: output, title: runTarget)
            } else {
                note = (failed ? "✗ error — " : "✓ ran clean — ") + "output:\n" + (shown.isEmpty ? "(no output)" : shown)
            }
            chat.append(ChatMessage(role: .status, text: note))
            if !failed || round == maxRounds { return }
            history.append(["role": "user",
                            "content": "I ran that and got this output:\n\(shown)\nPlease fix the program and send the COMPLETE corrected file in a ```va block."])
        }
    }

    struct CodeBlock: Equatable {
        var name: String?
        var code: String
    }

    // Every fenced code block in the reply; a first line of `# file: name.va`
    // names the project file it belongs to.
    static func extractFiles(_ reply: String) -> [CodeBlock] {
        var out: [CodeBlock] = []
        var rest = reply[...]
        while let fence = rest.range(of: "```") {
            var body = rest[fence.upperBound...]
            if let newline = body.firstIndex(of: "\n"),
               body[..<newline].trimmingCharacters(in: .whitespaces).count <= 10 {
                body = body[body.index(after: newline)...]
            }
            guard let close = body.range(of: "```") else { break }
            var code = String(body[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            var name: String? = nil
            let firstLine = code.firstIndex(of: "\n").map { String(code[..<$0]) } ?? code
            if firstLine.range(of: #"^#\s*file:"#, options: .regularExpression) != nil {
                name = firstLine.components(separatedBy: ":").last?
                    .trimmingCharacters(in: .whitespaces)
                if let newline = code.firstIndex(of: "\n") {
                    code = String(code[code.index(after: newline)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    code = ""
                }
            }
            if !code.isEmpty { out.append(CodeBlock(name: name, code: code + "\n")) }
            rest = body[close.upperBound...]
        }
        return out
    }

    // The first code block's contents (used by the chat bubble's Apply button).
    static func extractCode(_ reply: String) -> String? {
        extractFiles(reply).first?.code
    }

    // ---- settings persistence ----

    // Switching providers swaps in THAT provider's saved key and model, so an
    // OpenRouter key is never sent to Ollama (and vice versa).
    func switchProvider(_ provider: String) {
        ai.provider = provider
        ai.apiKey = ai.keys[provider] ?? ""
        ai.model = ai.models[provider] ?? AIClient.defaultModel(for: provider)
    }

    func setApiKey(_ key: String) {
        ai.apiKey = key
        ai.keys[ai.provider] = key
    }

    func setModel(_ id: String) {
        ai.model = id
        ai.models[ai.provider] = id
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(ai) {
            UserDefaults.standard.set(data, forKey: "ai-settings")
        }
    }

    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "ai-settings"),
           var settings = try? JSONDecoder().decode(AISettings.self, from: data) {
            // Make the active key/model consistent with the per-provider store.
            settings.apiKey = settings.keys[settings.provider] ?? settings.apiKey
            settings.model = settings.models[settings.provider] ?? settings.model
            ai = settings
        }
    }
}
