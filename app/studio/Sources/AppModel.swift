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
    @Published var lastRunFailed = false      // the last run exited non-zero
    @Published var statusText = "Ready"

    @Published var aiMessages: [AIMessage] = []
    @Published var aiInput = ""
    @Published var aiBusy = false
    @Published var settings = AISettings()

    // ⌘K inline edit
    enum InlinePhase { case idle, prompting, generating, reviewing }
    @Published var inlinePhase: InlinePhase = .idle
    @Published var inlinePrompt = ""
    @Published var inlineDiff: [DiffLine] = []
    @Published var inlineError: String?
    private var inlineRange = NSRange(location: 0, length: 0)
    private var inlineOriginal = ""     // the selected text being edited
    private var inlineProposed = ""     // the AI's rewrite

    // Agent (build + self-fix) mode
    @Published var agentMode = false
    @Published var agentStatus = ""

    // AI model catalog (for the Settings dropdown)
    @Published var modelCatalog: [String] = []
    @Published var modelsLoading = false
    @Published var modelError: String?

    private let runner = PythonRunner()
    private let settingsKey = "vanta-studio-ai-settings"

    init() {
        loadSettings()
        let starter = """
        # Welcome to Vanta Studio — the native Mac IDE for Vanta.
        # Runs natively (real python3, not WebAssembly), and Vanta is full-stack:
        # console scripts, JSON APIs, and real web servers. Press Run / Cmd-R.

        say "Hello from a native Mac app!"

        let squares be [n * n for each n in range(1, 8)]
        say "Squares: {to_json(squares)}"

        # Want a web page? Uncomment this, press Run, open http://localhost:8080
        # to home(req)
        #     give back "<h1>Served by Vanta</h1><p>It's a real web server.</p>"
        # end
        # serve(8080, home)

        # Or just ask Vee (the panel on the right): turn on Agent and say
        # "build me a web page" — it writes it, runs it, and fixes its own errors.
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
        lastRunFailed = false
        statusText = "Running \(file.name)…"
        let started = Date()
        runner.run(vantaPy: vpy, sourceFile: tmp,
            onOutput: { [weak self] s in self?.console += s },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.isRunning = false
                self.lastRunFailed = code != 0
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

    // MARK: ⌘K inline edit

    func beginInlineEdit(range: NSRange, selection: String) {
        guard !settings.apiKey.isEmpty else {
            statusText = "Add an API key in ⚙ to use ⌘K inline edit"
            return
        }
        // If nothing is selected, operate on the whole current line(s) at the cursor.
        var r = range
        var sel = selection
        if r.length == 0, let full = activeFile?.content {
            let ns = full as NSString
            let line = ns.lineRange(for: NSRange(location: min(r.location, ns.length), length: 0))
            r = line
            sel = ns.substring(with: line)
        }
        inlineRange = r
        inlineOriginal = sel
        inlinePrompt = ""
        inlineError = nil
        inlineDiff = []
        inlinePhase = .prompting
    }

    func submitInlineEdit() {
        let instruction = inlinePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        inlinePhase = .generating
        inlineError = nil
        let snippet = inlineOriginal
        let fileContext = activeFile?.content ?? ""
        let s = settings
        let user = """
        Here is the full file for context:
        ```
        \(fileContext)
        ```

        Rewrite ONLY this selected snippet:
        ```
        \(snippet)
        ```

        Instruction: \(instruction)

        Return only the rewritten snippet.
        """
        Task { [weak self] in
            do {
                var reply = try await AIClient.chat(system: AISystemPrompt.editSystem,
                                                     history: [["role": "user", "content": user]],
                                                     settings: s, maxTokens: 1500)
                reply = AIClient.stripFences(reply)
                // trim a single trailing newline mismatch so the diff is clean
                if reply.hasSuffix("\n") && !snippet.hasSuffix("\n") { reply = String(reply.dropLast()) }
                await MainActor.run {
                    guard let self else { return }
                    self.inlineProposed = reply
                    self.inlineDiff = LineDiff.diff(self.inlineOriginal, reply)
                    self.inlinePhase = .reviewing
                }
            } catch {
                await MainActor.run {
                    self?.inlineError = error.localizedDescription
                    self?.inlinePhase = .prompting
                }
            }
        }
    }

    func acceptInlineEdit() {
        guard let idx = files.firstIndex(where: { $0.id == activeID }) else { inlinePhase = .idle; return }
        let ns = files[idx].content as NSString
        guard inlineRange.location + inlineRange.length <= ns.length else { inlinePhase = .idle; return }
        let updated = ns.replacingCharacters(in: inlineRange, with: inlineProposed)
        files[idx].content = updated
        files[idx].dirty = true
        inlinePhase = .idle
        statusText = "Applied ⌘K edit"
    }

    func cancelInlineEdit() {
        inlinePhase = .idle
        inlineError = nil
        inlineDiff = []
    }

    // MARK: Agent (build → run → self-fix loop)

    struct RunResult {
        let output: String
        let failed: Bool      // process exited non-zero (and wasn't a server we timed out)
    }

    /// Run the given source and return what it printed plus whether it failed,
    /// judged by the real process exit code (Vanta exits non-zero on any error)
    /// — far more reliable than scanning the text. A long-running program (a web
    /// server) is stopped after `timeout` seconds and counted as success. When
    /// `streaming` is true the output is mirrored to the console live so the user
    /// can watch the fix run.
    func runAndCapture(_ code: String, streaming: Bool = false, timeout: Double = 18) async -> RunResult {
        guard let vpy = vantaPyURL else { return RunResult(output: "Bundled vanta.py not found.", failed: true) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-agent-run.va")
        try? code.write(to: tmp, atomically: true, encoding: .utf8)
        if streaming { console = "" }
        return await withCheckedContinuation { cont in
            var buffer = ""
            var done = false
            let finish: (Bool) -> Void = { failed in
                if done { return }; done = true
                cont.resume(returning: RunResult(output: buffer, failed: failed))
            }
            self.runner.run(vantaPy: vpy, sourceFile: tmp,
                onOutput: { s in
                    buffer += s
                    if streaming { self.console += s }
                },
                onFinish: { code in finish(code != 0) })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !done else { return }
                self.runner.stop()
                let note = "\n[still running after \(Int(timeout))s — looks like a server; left it for you to Run.]"
                buffer += note
                if streaming { self.console += note }
                finish(false)                 // a server staying up is success, not a failure
            }
        }
    }

    func agentBuild(_ goal: String) {
        guard !aiBusy else { return }
        guard !settings.apiKey.isEmpty else {
            aiMessages.append(AIMessage(role: "assistant", text: "Add an API key in ⚙ AI Settings to use Agent mode."))
            return
        }
        if isRunning { stop() }
        aiMessages.append(AIMessage(role: "user", text: goal))
        aiBusy = true
        agentStatus = "Thinking…"
        let s = settings
        Task { [weak self] in
            guard let self else { return }
            var history: [[String: String]] = [["role": "user", "content": goal]]
            var lastCode = ""
            var finalNote = ""
            let maxRounds = 4
            for round in 1...maxRounds {
                await MainActor.run { self.agentStatus = "Writing code (round \(round))…" }
                let reply: String
                do {
                    reply = try await AIClient.chat(system: AISystemPrompt.agentSystem,
                                                    history: history, settings: s, maxTokens: 4096)
                } catch {
                    await MainActor.run {
                        self.aiMessages.append(AIMessage(role: "assistant", text: "Error: \(error.localizedDescription)"))
                        self.aiBusy = false; self.agentStatus = ""
                    }
                    return
                }
                history.append(["role": "assistant", "content": reply])
                guard let code = Self.firstCodeBlock(reply) else {
                    finalNote = reply
                    break
                }
                lastCode = code
                await MainActor.run {
                    self.applyCode(code, toNewFile: false)
                    self.agentStatus = "Running (round \(round))…"
                    self.aiMessages.append(AIMessage(role: "assistant", text: "Round \(round): wrote \(code.components(separatedBy: "\n").count) lines — running it…"))
                }
                let result = await self.runAndCapture(code, streaming: true)
                if result.failed {
                    await MainActor.run {
                        self.aiMessages.append(AIMessage(role: "assistant", text: "Hit an error — fixing it:\n```\n\(result.output.suffix(500))\n```"))
                    }
                    history.append(["role": "user", "content": "When I ran that, it printed:\n\(result.output)\n\nFix the program and return the complete corrected file."])
                    continue
                } else {
                    finalNote = "Done — it ran cleanly. Output:\n```\n\(result.output.isEmpty ? "(no output)" : result.output)\n```"
                    break
                }
            }
            await MainActor.run {
                if !finalNote.isEmpty {
                    self.aiMessages.append(AIMessage(role: "assistant", text: finalNote))
                }
                self.aiBusy = false
                self.agentStatus = ""
                _ = lastCode
            }
        }
    }

    /// True when the last run failed — drives the "Fix with
    /// Vee" button — true when the last run exited with an error.
    var consoleHasError: Bool {
        lastRunFailed && !console.isEmpty && !aiBusy
    }

    /// Read whatever the console is showing, ask Vee to correct the current
    /// file, AUTO-APPLY the fix, and re-run it to confirm. Loops a few times
    /// until it actually runs clean (or gives up and tells you why).
    func fixWithVee() {
        guard !aiBusy else { return }
        guard !settings.apiKey.isEmpty else {
            aiMessages.append(AIMessage(role: "assistant", text: "Add an API key in ⚙ AI Settings so I can fix it for you."))
            return
        }
        guard let file = activeFile else { return }
        if isRunning { stop() }
        let errorText = String(console.suffix(1400))
        aiMessages.append(AIMessage(role: "user", text: "Fix the error in \(file.name)."))
        aiBusy = true
        agentStatus = "Reading the error…"
        let s = settings
        let firstFile = file.content
        Task { [weak self] in
            guard let self else { return }
            var history: [[String: String]] = [[
                "role": "user",
                "content": "Here is my Vanta file (\(file.name)):\n```\n\(firstFile)\n```\n\n"
                    + "When I ran it, the console said:\n```\n\(errorText)\n```\n\n"
                    + "Find the bug, fix it, and return the COMPLETE corrected file in a ```va block```.",
            ]]
            var finalNote = ""
            var stillFailing = true
            for round in 1...3 {
                await MainActor.run { self.agentStatus = round == 1 ? "Fixing…" : "Still fixing (round \(round))…" }
                let reply: String
                do {
                    reply = try await AIClient.chat(system: AISystemPrompt.agentSystem,
                                                    history: history, settings: s, maxTokens: 4096)
                } catch {
                    await MainActor.run {
                        self.aiMessages.append(AIMessage(role: "assistant", text: "Error: \(error.localizedDescription)"))
                        self.aiBusy = false; self.agentStatus = ""
                    }
                    return
                }
                history.append(["role": "assistant", "content": reply])
                guard let code = Self.firstCodeBlock(reply) else {
                    finalNote = reply.isEmpty ? "Vee didn't return any code to apply." : reply
                    break
                }
                await MainActor.run {
                    self.applyCode(code, toNewFile: false)        // auto-apply
                    self.agentStatus = "Running to check the fix…"
                    self.aiMessages.append(AIMessage(role: "assistant", text: "Applied a fix — running it to check…"))
                }
                let result = await self.runAndCapture(code, streaming: true)   // shows live in console
                stillFailing = result.failed
                if result.failed {
                    await MainActor.run {
                        self.aiMessages.append(AIMessage(role: "assistant", text: "Still erroring — trying again:\n```\n\(result.output.suffix(400))\n```"))
                    }
                    history.append(["role": "user", "content": "It still fails. The console now says:\n\(result.output)\n\nFix it and return the complete corrected file."])
                    continue
                } else {
                    finalNote = "✅ Fixed it — runs clean now."
                    break
                }
            }
            await MainActor.run {
                self.lastRunFailed = stillFailing
                if finalNote.isEmpty {
                    finalNote = "I couldn't fully fix it after 3 tries — the console shows where it's still stuck. Try giving me a hint in chat."
                }
                self.aiMessages.append(AIMessage(role: "assistant", text: finalNote))
                self.aiBusy = false
                self.agentStatus = ""
            }
        }
    }

    // MARK: autocomplete (ghost text)

    func requestCompletion(prefix: String, suffix: String, done: @escaping (String?) -> Void) {
        guard settings.autocomplete, !settings.apiKey.isEmpty else { done(nil); return }
        let s = settings
        Task {
            let result = try? await AIClient.complete(prefix: prefix, suffix: suffix, settings: s)
            await MainActor.run { done(result) }
        }
    }

    // MARK: helpers

    static func firstCodeBlock(_ text: String) -> String? {
        guard let open = text.range(of: "```") else { return nil }
        // skip the language tag / file attribute on the opening fence line
        let afterOpen = text[open.upperBound...]
        guard let firstNL = afterOpen.firstIndex(of: "\n") else { return nil }
        let bodyStart = afterOpen.index(after: firstNL)
        let rest = text[bodyStart...]
        guard let close = rest.range(of: "```") else { return nil }
        return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: AI model catalog

    func refreshModels() {
        guard !settings.apiKey.isEmpty else {
            modelError = "Add an API key first, then refresh."
            return
        }
        modelsLoading = true
        modelError = nil
        let s = settings
        Task { [weak self] in
            do {
                let list = try await AIClient.fetchModels(settings: s)
                await MainActor.run {
                    self?.modelCatalog = list
                    self?.modelsLoading = false
                }
            } catch {
                await MainActor.run {
                    self?.modelError = error.localizedDescription
                    self?.modelsLoading = false
                }
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
