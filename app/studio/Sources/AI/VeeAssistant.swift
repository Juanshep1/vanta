import SwiftUI
import AppKit

/// Vee, the AI assistant — the coordinator for chat, Ask the Book, the agent
/// loop, Fix with Vee, Explain / Write tests, and code-block Apply. ⌘K lives in
/// `InlineEditController`, ghost text in `Autocomplete`.
final class VeeAssistant: ObservableObject, InlineCompletionProvider {
    static let shared = VeeAssistant()

    // MARK: published state

    @Published var settings = AISettings() { didSet { if settings != oldValue { saveSettings() } } }
    /// "chat" | "agent" | "book"
    @Published var mode = "chat"
    @Published var input = ""
    @Published var attachments: [ChatAttachment] = []
    @Published private(set) var busy = false
    @Published var status = ""
    @Published private(set) var streamingItemID: UUID?
    @Published var question: PendingQuestion?
    @Published private(set) var sessionUsage = LLMUsage()
    @Published var focusToken = 0
    @Published private(set) var keyRevision = 0
    @Published var editingItemID: UUID?
    @Published var applyingBlock: String?

    // model catalog (Settings + panel picker)
    @Published var modelCatalog: [String] = []
    @Published var modelsLoading = false
    @Published var modelError: String?

    struct PendingQuestion: Identifiable { let id = UUID(); let text: String; let continuation: CheckedContinuation<String, Never> }

    let store = ChatStore.shared
    let tracker = ChangeTracker.shared
    let isMock: Bool
    /// The folder the agent uses when no workspace is open.
    var scratchRoot: URL?
    private var currentTask: Task<Void, Never>?
    private let settingsKey = "vanta-studio-ai-settings"

    init() {
        let env = ProcessInfo.processInfo.environment
        isMock = env["VANTA_STUDIO_MOCK_AI"] == "1" || CommandLine.arguments.contains("--mock-ai")
        AIClient.useMock = isMock
        let sandbox = isMock || Services.shared.isSnapshot || CommandLine.arguments.contains("--snapshot")
            || CommandLine.arguments.contains("--selftest")
        KeyStore.shared.sandboxed = sandbox
        if !sandbox { loadSettings() }
        if isMock { settings.provider = "anthropic" }
    }

    // MARK: keys

    var apiKey: String { isMock ? "mock-key" : KeyStore.shared.key(for: settings.provider) }
    var hasKey: Bool { isMock || !apiKey.isEmpty }

    func setKey(_ key: String) {
        KeyStore.shared.setKey(key, for: settings.provider)
        keyRevision += 1
    }

    var providerLabel: String { isMock ? "Mock AI" : AIProvider.name(settings.provider) }

    // MARK: InlineCompletionProvider (forwarded to the autocomplete engine)

    var isEnabled: Bool { Autocomplete.shared.isEnabled }
    func inlineCompletion(prefix: String, suffix: String, uri: URL) async -> String? {
        await Autocomplete.shared.complete(prefix: prefix, suffix: suffix, uri: uri)
    }

    // MARK: sending

    func send(_ raw: String? = nil) {
        let text = (raw ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        if let editing = editingItemID { truncate(before: editing); editingItemID = nil }
        input = ""
        let atts = attachments
        attachments = []
        Services.shared.layout.auxVisible = true
        if mode == "agent" { runAgent(text, attachments: atts) } else { runChat(text, attachments: atts, mode: mode) }
    }

    func stop() {
        currentTask?.cancel()
        if let q = question { question = nil; q.continuation.resume(returning: "") }
        status = "Stopping…"
    }

    func answerQuestion(_ answer: String) {
        guard let q = question else { return }
        question = nil
        q.continuation.resume(returning: answer)
    }

    private func requireKey(_ convID: UUID) -> Bool {
        if hasKey { return true }
        store.update(id: convID) { $0.items.append(ChatItem(role: .notice, text: "Add an API key in **Settings › AI** and I can help. Anthropic Claude is the default; OpenRouter, Ollama Cloud and NVIDIA work too. Keys are stored in your macOS Keychain.", isError: true)) }
        return false
    }

    private var cheatSheet: String {
        let kb = KnowledgeBase.shared
        if !kb.isLoaded { kb.loadNow() }
        return kb.cheatSheet
    }

    // MARK: chat / book

    func runChat(_ text: String, attachments: [ChatAttachment], mode: String, extraQuery: String = "",
                 display: String? = nil, onDone: ((String) -> Void)? = nil) {
        if store.conversations.isEmpty { store.newConversation() }
        let convID = store.current.id
        guard requireKey(convID) else { return }
        let ctx = ContextBuilder.build(message: text, attachments: attachments, mode: mode, settings: settings, extraQuery: extraQuery)
        let content = (ctx.text.isEmpty ? "" : "<context>\n\(ctx.text)\n</context>\n\n") + text
        let assistantID = UUID()
        store.update(id: convID) { c in
            c.items.append(ChatItem(role: .user, text: display ?? text, refs: ctx.refs, attachments: attachments,
                                    transcriptIndex: c.transcript.count, mode: mode))
            c.transcript.append(.user(content))
            c.items.append(ChatItem(id: assistantID, role: .assistant, mode: mode))
            if !c.titled { c.title = Self.title(from: display ?? text); c.titled = true }
        }
        let req = LLMRequest(model: settings.smartModel,
                             system: AISystemPrompt.system(for: mode == "book" ? "book" : mode == "fix" ? "fix" : "chat", cheatSheet: cheatSheet),
                             messages: trimmed(store.current.transcript), maxTokens: 16000,
                             purpose: .chat, cacheConversation: true)
        busy = true
        streamingItemID = assistantID
        status = mode == "book" ? "Reading the book…" : "Thinking…"
        let s = settings, key = apiKey
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let r = await self.streamTurn(req, settings: s, key: key, convID: convID, itemID: assistantID)
            self.store.update(id: convID) { c in
                c.transcript.append(r.message ?? .assistant(r.text.isEmpty ? "(no reply)" : r.text))
            }
            self.finishBusy()
            if !r.failed { onDone?(r.text) }
        }
    }

    struct TurnResult { var text = ""; var message: LLMMessage?; var toolCalls: [LLMToolCall] = []; var failed = false; var cancelled = false }

    /// Stream one model turn into the assistant item `itemID`.
    @MainActor
    private func streamTurn(_ req: LLMRequest, settings s: AISettings, key: String, convID: UUID, itemID: UUID) async -> TurnResult {
        var r = TurnResult()
        var pendingText = "", pendingThinking = ""
        var lastFlush = Date()
        func flush(force: Bool = false) {
            guard force || Date().timeIntervalSince(lastFlush) > 0.05 else { return }
            lastFlush = Date()
            guard !pendingText.isEmpty || !pendingThinking.isEmpty else { return }
            let t = pendingText, th = pendingThinking
            pendingText = ""; pendingThinking = ""
            updateItem(convID, itemID) { $0.text += t; $0.thinking += th }
        }
        do {
            for try await ev in AIClient.stream(req, settings: s, apiKey: key) {
                switch ev {
                case let .text(t):
                    r.text += t; pendingText += t
                    if status.hasPrefix("Thinking") || status.hasPrefix("Reading") || status.contains("retrying") { status = "Writing…" }
                case let .thinking(t): pendingThinking += t; if r.text.isEmpty { status = "Thinking…" }
                case let .toolCallStarted(_, name): status = "Preparing \(AgentTools.title(name).lowercased())…"
                case let .toolCall(c): r.toolCalls.append(c)
                case let .message(m): r.message = m
                case let .usage(u):
                    updateItem(convID, itemID) { $0.usage = u }
                    store.update(id: convID) { $0.usage.add(u) }
                    sessionUsage.add(u)
                case let .status(msg): status = msg
                case .stop: break
                }
                flush()
            }
            flush(force: true)
        } catch is CancellationError {
            flush(force: true)
            r.cancelled = true
            updateItem(convID, itemID) { $0.text += $0.text.isEmpty ? "_Stopped._" : "\n\n_Stopped._" }
        } catch {
            flush(force: true)
            r.failed = true
            let msg = (error as? AIError)?.errorDescription ?? error.localizedDescription
            updateItem(convID, itemID) { $0.text += ($0.text.isEmpty ? "" : "\n\n") + msg; $0.isError = true }
        }
        if Task.isCancelled && !r.cancelled {
            r.cancelled = true
        }
        return r
    }

    private func updateItem(_ convID: UUID, _ itemID: UUID, _ body: (inout ChatItem) -> Void) {
        store.update(id: convID) { c in
            if let i = c.items.firstIndex(where: { $0.id == itemID }) { body(&c.items[i]) }
        }
    }

    private func finishBusy() {
        busy = false
        streamingItemID = nil
        status = ""
        currentTask = nil
    }

    /// Keep requests bounded: very long chats drop their oldest turns (in pairs, at a user boundary).
    private func trimmed(_ t: [LLMMessage]) -> [LLMMessage] {
        guard t.count > 80 else { return t }
        var out = Array(t.suffix(60))
        while let f = out.first, f.role != .user || f.blocks.contains(where: { if case .toolResult = $0 { return true }; return false }) {
            out.removeFirst()
        }
        return out
    }

    static func title(from text: String) -> String {
        let words = text.replacingOccurrences(of: "\n", with: " ").split(separator: " ").prefix(7).joined(separator: " ")
        return words.count > 48 ? String(words.prefix(48)) + "…" : words
    }

    // MARK: edit & resend

    func beginEdit(_ item: ChatItem) {
        guard !busy, item.role == .user else { return }
        editingItemID = item.id
        input = item.text
        attachments = item.attachments
        focusToken += 1
    }

    func cancelEdit() { editingItemID = nil; input = ""; attachments = [] }

    /// Remove `itemID` and everything after it (and the matching transcript tail).
    private func truncate(before itemID: UUID) {
        store.update { c in
            guard let i = c.items.firstIndex(where: { $0.id == itemID }) else { return }
            if let ti = c.items[i].transcriptIndex, ti <= c.transcript.count { c.transcript.removeSubrange(ti...) }
            c.items.removeSubrange(i...)
        }
    }

    // MARK: agent

    func runAgent(_ goal: String, attachments: [ChatAttachment] = []) {
        if store.conversations.isEmpty { store.newConversation() }
        let convID = store.current.id
        guard requireKey(convID) else { return }
        ensureAgentRoot()
        let checkpoint = tracker.beginTurn(String(goal.prefix(60)))
        let ctx = ContextBuilder.build(message: goal, attachments: attachments, mode: "agent", settings: settings)
        let content = (ctx.text.isEmpty ? "" : "<context>\n\(ctx.text)\n</context>\n\n") + goal
        store.update(id: convID) { c in
            c.items.append(ChatItem(role: .user, text: goal, refs: ctx.refs, attachments: attachments,
                                    transcriptIndex: c.transcript.count, checkpointID: checkpoint, mode: "agent"))
            c.transcript.append(.user(content))
            if !c.titled { c.title = Self.title(from: goal); c.titled = true }
        }
        busy = true
        status = "Planning…"
        let s = settings, key = apiKey
        let system = AISystemPrompt.system(for: "agent", cheatSheet: cheatSheet)
        currentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var steps = 0
            var finished = false
            while !Task.isCancelled {
                steps += 1
                if steps > s.agentStepLimit {
                    self.store.update(id: convID) { $0.items.append(ChatItem(role: .notice, text: "Reached the step limit (\(s.agentStepLimit) steps). Say **continue** to keep going, or raise the limit in Settings › AI.", mode: "agent")) }
                    break
                }
                let itemID = UUID()
                self.store.update(id: convID) { $0.items.append(ChatItem(id: itemID, role: .assistant, mode: "agent")) }
                self.streamingItemID = itemID
                let req = LLMRequest(model: s.smartModel, system: system, messages: self.trimmed(self.store.current(id: convID).transcript),
                                     tools: AgentTools.definitions, maxTokens: 32000, purpose: .agent, cacheConversation: true)
                let r = await self.streamTurn(req, settings: s, key: key, convID: convID, itemID: itemID)
                self.streamingItemID = nil
                // drop an empty assistant bubble (pure tool-call turns)
                self.store.update(id: convID) { c in
                    if let i = c.items.firstIndex(where: { $0.id == itemID }), c.items[i].text.isEmpty, !c.items[i].isError {
                        let th = c.items[i].thinking
                        if th.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { c.items.remove(at: i) }
                    }
                }
                if r.failed { break }
                let message = r.message ?? LLMMessage(role: .assistant, blocks: (r.text.isEmpty ? [] : [.text(r.text)]) + r.toolCalls.map { .toolUse($0) })
                let calls = message.toolCalls
                if message.blocks.isEmpty {
                    self.store.update(id: convID) { $0.transcript.append(.assistant("(stopped)")) }
                    break
                }
                self.store.update(id: convID) { $0.transcript.append(message) }
                if calls.isEmpty { finished = !r.cancelled; break }

                var results: [LLMBlock] = []
                for call in calls {
                    let toolItem = UUID()
                    self.store.update(id: convID) {
                        $0.items.append(ChatItem(id: toolItem, role: .tool, tool: ToolStep(callID: call.id, name: call.name, arguments: call.arguments), mode: "agent"))
                    }
                    if Task.isCancelled {
                        results.append(.toolResult(id: call.id, content: "Stopped by the user before this ran.", isError: true))
                        self.updateItem(convID, toolItem) { $0.tool?.status = .denied; $0.tool?.result = "Stopped" }
                        continue
                    }
                    self.status = "\(AgentTools.title(call.name)) \(AgentTools.summary(call.name, call.args))…"
                    if call.name == "ask_user" { self.updateItem(convID, toolItem) { $0.tool?.status = .waiting } }
                    let t0 = Date()
                    let out = await AgentTools.execute(call, tracker: self.tracker, askUser: { q in await self.ask(q) })
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    var text = out.text
                    if text.count > 20000 { text = String(text.prefix(14000)) + "\n…(truncated)…\n" + String(text.suffix(4000)) }
                    self.updateItem(convID, toolItem) {
                        $0.tool?.result = text; $0.tool?.status = out.isError ? .failed : .done; $0.tool?.durationMs = ms
                    }
                    results.append(.toolResult(id: call.id, content: text, isError: out.isError))
                }
                self.store.update(id: convID) { $0.transcript.append(LLMMessage(role: .user, blocks: results)) }
                self.status = "Thinking…"
            }
            if Task.isCancelled {
                self.store.update(id: convID) { $0.items.append(ChatItem(role: .notice, text: "Stopped. Your files keep the changes made so far — review them below or restore the checkpoint.", mode: "agent")) }
            }
            self.tracker.endTurn()
            if s.agentAutoApply && finished { self.tracker.acceptAll() }
            self.finishBusy()
        }
    }

    @MainActor
    private func ask(_ q: String) async -> String {
        Services.shared.layout.auxVisible = true
        status = "Waiting for your answer…"
        return await withCheckedContinuation { cont in
            self.question = PendingQuestion(text: q, continuation: cont)
        }
    }

    /// The agent needs a folder: the workspace, else the active file's folder, else a fresh scratch project.
    private func ensureAgentRoot() {
        let s = Services.shared
        guard s.workspace.root == nil else { scratchRoot = nil; return }
        if let u = s.editors.activeDocument?.url { scratchRoot = u.deletingLastPathComponent(); return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HHmm"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Vanta Projects/Vee \(fmt.string(from: Date()))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if s.isSnapshot { scratchRoot = dir } else { s.workspace.open(dir) }
    }

    func restoreCheckpoint(_ id: UUID) {
        guard !busy else { return }
        tracker.restore(checkpoint: id)
        Services.shared.flash("Restored files to the checkpoint")
        store.update { $0.items.append(ChatItem(role: .notice, text: "Restored the checkpoint — files are back to how they were before that request.", mode: "agent")) }
    }

    // MARK: Fix with Vee / Explain / Tests

    var consoleHasError: Bool {
        RunController.shared.lastRunFailed && !RunController.shared.console.isEmpty && !busy
    }

    /// Explain the console's runtime error in plain words and propose the fix as an inline diff.
    func fixRunError() {
        let s = Services.shared
        guard let doc = s.editors.activeDocument else { s.flash("Open the file that failed"); return }
        let err = String(RunController.shared.console.suffix(3000))
        fix(doc: doc, problem: "When I run \(doc.name), it fails with:\n```\n\(err)\n```", display: "Fix the error in \(doc.name)", errorText: err)
    }

    /// Fix one diagnostic (Problems panel / lightbulb).
    func fixDiagnostic(_ d: Diagnostic, uri: URL) {
        let s = Services.shared
        if s.editors.activeDocument?.uri != uri { s.editors.open(location: Location(uri: uri, range: d.range)) }
        guard let doc = s.editors.activeDocument else { return }
        let line = d.range.start.line
        let src = doc.text.components(separatedBy: "\n")
        let snippet = line < src.count ? src[line] : ""
        fix(doc: doc, problem: "`\(d.source)` reports on line \(line + 1) (`\(snippet.trimmingCharacters(in: .whitespaces))`):\n> \(d.message)",
            display: "Fix: \(d.message) (line \(line + 1))", errorText: d.message)
    }

    private func fix(doc: Document, problem: String, display: String, errorText: String) {
        guard !busy else { return }
        Services.shared.layout.auxVisible = true
        if mode == "agent" {
            runAgent("\(problem)\n\nFind the cause in \(doc.url.map(WorkspaceFS.relative) ?? doc.name), fix it, and verify by running it.")
            return
        }
        let original = doc.text
        let docID = doc.id
        runChat(problem + "\n\nExplain what went wrong in beginner-friendly terms, then give the complete corrected file.",
                attachments: [], mode: "fix", extraQuery: errorText, display: display) { [weak self] reply in
            guard let self, let code = Self.extractProgram(from: reply), Self.isPlausibleProgram(code, errorText: errorText) else { return }
            guard let d = Services.shared.documents.document(id: docID), d.text == original else { return }
            self.proposeEdit(in: d, newText: code.hasSuffix("\n") || !original.hasSuffix("\n") ? code : code + "\n",
                             accepted: "Fix applied — press ⌘R to run it again")
        }
    }

    func explainSelection() { askAboutSelection("Explain this code simply: what it does, step by step, and anything surprising.", display: "Explain this code") }

    func writeTestsForSelection() {
        askAboutSelection("Write Vanta tests for this code using `test \"…\"` blocks with `expect`. Cover normal cases and edge cases. Put the tests in one ```vanta block, and say which file they should go in (e.g. tests/test_NAME.va or the same file).",
                          display: "Write tests for this")
    }

    private func askAboutSelection(_ prompt: String, display: String) {
        guard let a = selectionAttachment(wholeFileIfEmpty: true) else { Services.shared.flash("Open a file first"); return }
        guard !busy else { return }
        Services.shared.layout.auxVisible = true
        let m = mode == "agent" ? "chat" : mode
        runChat(prompt, attachments: [a], mode: m == "book" ? "chat" : m, display: display)
    }

    /// The editor selection (whole lines) as an attachment.
    func selectionAttachment(wholeFileIfEmpty: Bool = false) -> ChatAttachment? {
        guard let ed = Services.shared.editor else { return nil }
        var r = ed.selections.first ?? NSRange(location: 0, length: 0)
        let ns = ed.text as NSString
        if r.length == 0 {
            guard wholeFileIfEmpty else { return nil }
            r = NSRange(location: 0, length: ns.length)
        } else {
            r = ns.lineRange(for: r)
        }
        let text = ns.substring(with: r)
        let start = ed.position(of: r.location).line
        let end = start + max(0, text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 2 : 1))
        let path = ed.url.map(WorkspaceFS.relative) ?? ed.document.name
        return ChatAttachment(label: r.location == 0 && r.length == ns.length ? path : "\(path):\(start + 1)–\(end + 1)",
                              path: path, text: text, startLine: start)
    }

    /// ⌘L: with a selection, attach it and focus the chat; otherwise toggle the panel.
    func addSelectionToChat() {
        let layout = Services.shared.layout
        if let a = selectionAttachment() {
            if !attachments.contains(where: { $0.label == a.label }) { attachments.append(a) }
            layout.auxVisible = true
            focusToken += 1
        } else {
            layout.auxVisible.toggle()
            if layout.auxVisible { focusToken += 1 }
        }
    }

    // MARK: code-block actions

    /// Show `newText` (a full new version of `doc`) as a focused inline diff in its editor.
    func proposeEdit(in doc: Document, newText: String, accepted: String = "Applied") {
        let s = Services.shared
        let pane = s.editors.open(document: doc)
        let old = doc.text
        guard let region = LineDiff.changedRegion(old: old, new: newText) else { s.flash("Already up to date"); return }
        pane.showInlineDiff(range: region.range, newText: region.replacement, onAccept: {
            Services.shared.flash(accepted)
        }, onReject: {})
        pane.scrollToLine(pane.position(of: region.range.location).line, select: false)
    }

    /// Apply: merge the block into its target file (structurally when possible,
    /// with the model otherwise) and show the result as an inline diff.
    func applyBlock(_ code: String, fileHint: String?) {
        let s = Services.shared
        var doc: Document?
        if let hint = fileHint, let url = try? WorkspaceFS.resolve(hint), FileManager.default.fileExists(atPath: url.path) {
            doc = s.documents.open(url)
        }
        doc = doc ?? s.editors.activeDocument
        guard let target = doc else { newFile(code, nameHint: fileHint); return }
        let old = target.text
        if let merged = CodeMerge.merge(snippet: code, into: old) {
            proposeEdit(in: target, newText: merged)
            return
        }
        guard hasKey else { proposeEdit(in: target, newText: code); return }
        applyingBlock = code
        s.flash("Vee is merging the change into \(target.name)…")
        let req = LLMRequest(model: settings.smartModel, system: AISystemPrompt.system(for: "edit", cheatSheet: cheatSheet),
                             messages: [.user("""
                             Merge the SNIPPET into the FILE and output the COMPLETE updated file — nothing else (no fences, no commentary). Keep every unrelated line exactly as it is; replace the parts the snippet rewrites, and add new code where it belongs.
                             <file path="\(target.name)">
                             \(old)
                             </file>
                             <snippet>
                             \(code)
                             </snippet>
                             """)], maxTokens: 32000, purpose: .edit)
        let st = settings, key = apiKey
        Task { @MainActor [weak self] in
            do {
                let r = try await AIClient.send(req, settings: st, apiKey: key)
                self?.applyingBlock = nil
                var merged = CodeMerge.stripFences(r.text)
                if old.hasSuffix("\n") && !merged.hasSuffix("\n") { merged += "\n" }
                guard target.text == old else { Services.shared.flash("The file changed while merging — try Apply again"); return }
                self?.proposeEdit(in: target, newText: merged)
            } catch {
                self?.applyingBlock = nil
                Services.shared.flash("Apply failed: \(error.localizedDescription)")
            }
        }
    }

    func insertBlock(_ code: String) {
        guard let ed = Services.shared.editor else { newFile(code, nameHint: nil); return }
        ed.insertAtCursor(code)
        ed.focus()
    }

    func copyBlock(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        Services.shared.flash("Copied")
    }

    func newFile(_ code: String, nameHint: String?) {
        let s = Services.shared
        let name = (nameHint.map { URL(fileURLWithPath: $0).lastPathComponent }).flatMap { $0.hasSuffix(".va") ? $0 : nil }
            ?? "vee-\(s.documents.documents.count + 1).va"
        let d = s.documents.newUntitled(text: code.hasSuffix("\n") ? code : code + "\n", name: name)
        s.editors.open(document: d)
    }

    // MARK: program extraction (Fix with Vee)

    static func extractProgram(from reply: String) -> String? {
        var text = CodeMerge.stripBetween(reply, "<think>", "</think>")
        text = CodeMerge.stripBetween(text, "<thinking>", "</thinking>")
        let blocks = MarkdownBlocks.codeBlocks(text)
        let vanta = blocks.filter { $0.lang.isEmpty || ["va", "vanta"].contains($0.lang.lowercased()) }
        if let best = (vanta.isEmpty ? blocks : vanta).max(by: { $0.code.count < $1.code.count }) {
            let t = best.code.trimmingCharacters(in: .newlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static func isPlausibleProgram(_ code: String, errorText: String) -> Bool {
        let t = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("Oops!") || t.contains("Traceback (most recent call last)") { return false }
        let errLine = errorText.split(separator: "\n").first.map(String.init) ?? ""
        if !errLine.isEmpty && t.contains(errLine) && t.count < errLine.count + 60 { return false }
        return true
    }

    // MARK: model catalog

    func refreshModels() {
        guard hasKey else { modelError = "Add an API key first, then refresh."; return }
        modelsLoading = true
        modelError = nil
        let s = settings, key = apiKey
        Task { @MainActor [weak self] in
            do {
                let list = try await AIClient.fetchModels(settings: s, apiKey: key)
                self?.modelCatalog = list
            } catch {
                self?.modelError = (error as? AIError)?.errorDescription ?? error.localizedDescription
            }
            self?.modelsLoading = false
        }
    }

    func setProvider(_ p: String) {
        guard p != settings.provider else { return }
        settings.provider = p
        settings.smartModel = AIProvider.defaultSmartModel(p)
        settings.fastModel = AIProvider.defaultFastModel(p)
        settings.baseURL = ""
        modelCatalog = []
        modelError = nil
        keyRevision += 1
    }

    // MARK: settings persistence

    func saveSettings() {
        guard !Services.shared.isSnapshot, !isMock, let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: settingsKey)
    }

    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              var s = try? JSONDecoder().decode(AISettings.self, from: data) else { return }
        // One-time migration of a plaintext key from Phase 1 / Studio 1 into the Keychain.
        if let legacy = s.legacyAPIKey {
            if !KeyStore.shared.hasKey(s.provider) { KeyStore.shared.setKey(legacy, for: s.provider) }
            s.legacyAPIKey = nil
            if let clean = try? JSONEncoder().encode(s) { UserDefaults.standard.set(clean, forKey: settingsKey) }
        }
        settings = s
    }
}

extension ChatStore {
    func current(id: UUID) -> Conversation { conversations.first { $0.id == id } ?? current }
}
