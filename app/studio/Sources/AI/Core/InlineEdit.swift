import AppKit
import Combine

/// ⌘K inline edit. A prompt bar floats over the selection (or the current
/// line / block); the rewrite streams into an inline red/green diff; ⌘↩
/// accepts, Esc rejects, and a follow-up prompt refines the result. On a blank
/// line ⌘K generates new code at the cursor.
final class InlineEditController: ObservableObject {
    static let shared = InlineEditController()

    enum Phase { case idle, prompting, generating, reviewing }
    @Published var phase: Phase = .idle
    @Published var prompt = ""
    @Published var error: String?
    @Published private(set) var isGenerate = false
    @Published private(set) var regionLabel = ""
    /// Bumped to re-position the floating bar.
    @Published private(set) var anchorRevision = 0
    @Published private(set) var lastUsage: LLMUsage?
    @Published var focusToken = 0
    /// Phantom lines the diff draws above the region's first line (the bar sits above them).
    @Published private(set) var leadingInserted = 0

    private(set) var range = NSRange(location: 0, length: 0)
    private var original = ""
    private var proposed = ""
    private var docID: UUID?
    private var history: [LLMMessage] = []
    private var task: Task<Void, Never>?

    private var vee: VeeAssistant { .shared }

    /// ⌘K
    func begin() {
        let s = Services.shared
        guard let ed = s.editor else { return }
        if phase == .reviewing || phase == .generating, docID == ed.document.id {
            focusToken += 1                         // refine the current proposal
            return
        }
        guard vee.hasKey else { s.flash("Add an API key in Settings › AI to use ⌘K"); return }
        if ed.hasInlineDiff { ed.dismissInlineDiff() }
        let ns = ed.text as NSString
        let sel = ed.selections.first ?? NSRange(location: 0, length: 0)
        let lines = ed.document.lines
        if sel.length > 0 {
            range = ns.lineRange(for: sel)
            isGenerate = false
        } else {
            let caret = min(sel.location, ns.length)
            let lr = ns.lineRange(for: NSRange(location: caret, length: 0))
            let lineText = ns.substring(with: lr)
            let lineNo = lines.line(at: caret)
            if lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isGenerate = true
                range = lr
            } else if let b = ed.document.blocks.first(where: { $0.start == lineNo && $0.end > $0.start }) {
                isGenerate = false
                let start = lines.start(of: b.start)
                range = NSRange(location: start, length: NSMaxRange(lines.range(of: b.end)) - start)
            } else {
                isGenerate = false
                range = lr
            }
        }
        original = ns.substring(with: range)
        docID = ed.document.id
        let first = lines.line(at: range.location) + 1
        let last = lines.line(at: max(range.location, NSMaxRange(range) - 1)) + 1
        regionLabel = isGenerate ? "new code at line \(first)" : (first == last ? "line \(first)" : "lines \(first)–\(last)")
        prompt = ""
        error = nil
        history = []
        lastUsage = nil
        phase = .prompting
        leadingInserted = 0
        anchorRevision += 1
        focusToken += 1
    }

    func submit() {
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, phase != .generating else { return }
        let s = Services.shared
        guard let ed = s.editor, ed.document.id == docID else { cancel(); return }
        prompt = ""
        error = nil
        let text = ed.text
        if history.isEmpty {
            history = [.user(firstMessage(instruction: instruction, file: text, path: ed.url.map(WorkspaceFS.relative) ?? ed.document.name))]
        } else {
            history.append(.assistant(proposed))
            history.append(.user("Refine that rewrite: \(instruction)\nOutput only the full replacement for the region again."))
            ed.dismissInlineDiff()
        }
        phase = .generating
        let req = LLMRequest(model: vee.settings.smartModel,
                             system: AISystemPrompt.system(for: "edit", cheatSheet: KnowledgeBase.shared.cheatSheet),
                             messages: history, maxTokens: 16000, purpose: .edit)
        let st = vee.settings, key = vee.apiKey
        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var acc = ""
            var lastShown = Date.distantPast
            do {
                for try await ev in AIClient.stream(req, settings: st, apiKey: key) {
                    switch ev {
                    case let .text(t):
                        acc += t
                        if Date().timeIntervalSince(lastShown) > 0.12, let nl = acc.lastIndex(of: "\n") {
                            lastShown = Date()
                            self.preview(String(acc[...nl]), final: false)
                        }
                    case let .usage(u): self.lastUsage = u
                    default: break
                    }
                }
                self.proposed = self.normalize(acc)
                self.preview(self.proposed, final: true)
                self.phase = .reviewing
                self.focusToken += 1
            } catch is CancellationError {
                return
            } catch {
                Services.shared.editor?.dismissInlineDiff()
                self.error = (error as? AIError)?.errorDescription ?? error.localizedDescription
                self.phase = .prompting
                if self.history.count > 1 { self.history.removeLast(2) } else { self.history = [] }
            }
        }
    }

    private func firstMessage(instruction: String, file: String, path: String) -> String {
        let ns = file as NSString
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: NSMaxRange(range))
        let marked = ContextBuilder.clip(String(before.suffix(12000)), 12000) + "<region>\n" + original + "</region>\n" + String(after.prefix(6000))
        let book = KnowledgeBase.shared.search(instruction + " " + original.prefix(200), k: 3)
        var msg = "<file path=\"\(path)\">\n\(marked)\n</file>\n\n"
        if !book.isEmpty { msg += "<vanta_book_excerpts>\n\(KnowledgeBase.render(book, maxChars: 6000))</vanta_book_excerpts>\n\n" }
        if isGenerate {
            msg += "The <region> marks the cursor on an empty line. Write new Vanta code to put there, following this instruction:\n\(instruction)\n\nOutput only the new code (indented to fit where the cursor is)."
        } else {
            msg += "Instruction: \(instruction)\n\nOutput only the complete replacement for the code inside <region>."
        }
        return msg
    }

    private func normalize(_ raw: String) -> String {
        var t = CodeMerge.stripFences(raw)
        t = t.replacingOccurrences(of: "<region>\n", with: "").replacingOccurrences(of: "</region>", with: "")
        if original.hasSuffix("\n") && !t.hasSuffix("\n") { t += "\n" }
        if !original.hasSuffix("\n") && t.hasSuffix("\n") { t.removeLast() }
        // keep the region's indentation if the model dropped it on a one-liner
        if !isGenerate, !original.contains("\n") || original.filter({ $0 == "\n" }).count == 1 {
            let indent = original.prefix { $0 == " " }
            if !indent.isEmpty && !t.hasPrefix(String(indent)) && !t.contains("\n" + indent) {
                t = String(indent) + t.trimmingCharacters(in: .init(charactersIn: " "))
            }
        }
        return t
    }

    private func preview(_ text: String, final: Bool) {
        guard let ed = Services.shared.editor, ed.document.id == docID else { return }
        var newText = text
        if !final {
            // while streaming, the rest of the original still shows as pending removal
            if original.hasSuffix("\n") && !newText.hasSuffix("\n") { newText += "\n" }
        }
        leadingInserted = LineDiff.diff(original, newText).prefix { $0.kind != .same && $0.kind != .remove }.count
        ed.showInlineDiff(range: range, newText: newText, onAccept: { [weak self] in
            guard let self else { return }
            self.phase = .idle
            self.history = []
            Services.shared.flash(self.isGenerate ? "Inserted Vee's code" : "Applied ⌘K edit")
        }, onReject: { [weak self] in
            self?.task?.cancel()
            self?.phase = .idle
            self?.history = []
        })
        anchorRevision += 1
    }

    func accept() {
        if let pane = Services.shared.editor as? EditorPane, pane.hasInlineDiff { pane.acceptInlineDiff() }
        phase = .idle
        Services.shared.editor?.focus()
    }

    func cancel() {
        task?.cancel()
        if let pane = Services.shared.editor as? EditorPane, pane.hasInlineDiff { pane.rejectInlineDiff() }
        phase = .idle
        error = nil
        history = []
        Services.shared.editor?.focus()
    }

    func stopGenerating() {
        task?.cancel()
        if !proposed.isEmpty || Services.shared.editor?.hasInlineDiff == true { phase = .reviewing } else { phase = .prompting }
    }
}
