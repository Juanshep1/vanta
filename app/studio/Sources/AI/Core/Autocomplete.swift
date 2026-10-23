import AppKit
import Combine

/// Tab autocomplete (ghost text) with the fast model: fill-in-the-middle
/// context (prefix + suffix + related workspace declarations), its own
/// debounce (Settings › AI, ~300 ms) that prefetches and shows the suggestion,
/// stale-request cancellation, an LRU cache and "typed-through" reuse. The
/// editor's own (slower) request then hits the cache.
///
/// Also: ⌘→ accepts the next word, and "next edit" prediction — rename a
/// variable / function at its declaration and Vee offers the matching edits
/// elsewhere in the file as an inline diff.
final class Autocomplete {
    static let shared = Autocomplete()

    private var vee: VeeAssistant { .shared }
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private var last: (prefix: String, completion: String)?
    private var inflight: (key: String, task: Task<String?, Never>)?
    private var bag = Set<AnyCancellable>()
    private var editorBag = Set<AnyCancellable>()
    private var snapshots: [UUID: String] = [:]
    private(set) var requests = 0
    private(set) var hits = 0

    var isEnabled: Bool { vee.settings.autocomplete && vee.hasKey }

    func start() {
        Services.shared.activeEditorChanged
            .sink { [weak self] ed in self?.attach(ed) }
            .store(in: &bag)
        attach(Services.shared.editor)
    }

    private func attach(_ ed: EditorController?) {
        editorBag.removeAll()
        guard let ed else { return }
        snapshots[ed.document.id] = ed.text
        let delay = max(80, vee.settings.autocompleteDelayMs)
        ed.textChanges
            .debounce(for: .milliseconds(delay), scheduler: DispatchQueue.main)
            .sink { [weak self, weak ed] _ in if let ed { self?.prefetch(ed) } }
            .store(in: &editorBag)
        ed.textChanges
            .debounce(for: .milliseconds(1100), scheduler: DispatchQueue.main)
            .sink { [weak self, weak ed] _ in if let ed { self?.predictNextEdit(ed) } }
            .store(in: &editorBag)
    }

    // MARK: prefetch → ghost text

    private func prefetch(_ ed: EditorController) {
        guard isEnabled, !ed.hasInlineDiff, ed.selections.count == 1, let sel = ed.selections.first, sel.length == 0 else { return }
        let ns = ed.text as NSString
        let loc = sel.location
        guard loc <= ns.length else { return }
        if loc < ns.length && ns.character(at: loc) != 10 {
            // mid-line: only when the rest of the line is closing punctuation
            let rest = ns.substring(with: NSRange(location: loc, length: ns.lineRange(for: NSRange(location: loc, length: 0)).upperBound - loc))
            guard rest.trimmingCharacters(in: CharacterSet(charactersIn: ")]}\"' \n")).isEmpty else { return }
        }
        let prefix = ns.substring(to: loc)
        guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let suffix = ns.substring(from: loc)
        let uri = ed.document.uri
        let version = ns.length
        Task { @MainActor [weak self, weak ed] in
            guard let self, let s = await self.complete(prefix: prefix, suffix: suffix, uri: uri), !s.isEmpty,
                  let ed, ed.selections.first == NSRange(location: loc, length: 0), (ed.text as NSString).length == version,
                  !ed.hasInlineDiff else { return }
            ed.setGhostText(s, at: loc)
        }
    }

    // MARK: completion

    func complete(prefix: String, suffix: String, uri: URL) async -> String? {
        guard isEnabled else { return nil }
        // typed-through: the user typed the start of the last suggestion
        if let l = last, prefix.hasPrefix(l.prefix), prefix.count > l.prefix.count {
            let typed = String(prefix.dropFirst(l.prefix.count))
            if l.completion.hasPrefix(typed) && l.completion.count > typed.count {
                hits += 1
                return String(l.completion.dropFirst(typed.count))
            }
        }
        let key = String(prefix.suffix(1500)) + "\u{1}" + String(suffix.prefix(300))
        if let c = cache[key] { hits += 1; return c.isEmpty ? nil : c }
        if let f = inflight, f.key == key { return await f.task.value }
        inflight?.task.cancel()
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.request(prefix: prefix, suffix: suffix, uri: uri)
        }
        inflight = (key, task)
        let result = await task.value
        if inflight?.key == key { inflight = nil }
        guard !task.isCancelled else { return nil }
        store(key, result ?? "")
        if let r = result, !r.isEmpty { last = (prefix, r) }
        return result
    }

    private func store(_ key: String, _ value: String) {
        cache[key] = value
        cacheOrder.append(key)
        if cacheOrder.count > 80 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func request(prefix: String, suffix: String, uri: URL) async -> String? {
        requests += 1
        let s = vee.settings
        let key = vee.apiKey
        let p = String(prefix.suffix(3500)), sfx = String(suffix.prefix(1200))
        let related = await MainActor.run { CodebaseIndex.shared.relatedSignatures(for: String(prefix.suffix(2500)) + sfx, excluding: uri) }
        let kb = KnowledgeBase.shared
        if !kb.isLoaded { kb.loadNow() }
        var user = "<file path=\"\(uri.lastPathComponent)\">\n"
        if !related.isEmpty { user += "<related_declarations>\n\(related.joined(separator: "\n"))\n</related_declarations>\n" }
        user += "<prefix>\(p)</prefix><suffix>\(sfx)</suffix>\n</file>\nText to insert at the end of <prefix>:"
        let fast = s.fastModel.isEmpty ? AIProvider.defaultFastModel(s.provider) : s.fastModel
        let req = LLMRequest(model: fast,
                             system: [SystemPart(text: AISystemPrompt.completionSystem), SystemPart(text: kb.compactCheatSheet, cache: true)],
                             messages: [.user(user)], maxTokens: fast.contains("haiku") ? 256 : 1024, purpose: .completion)
        guard let r = try? await AIClient.send(req, settings: s, apiKey: key), !Task.isCancelled else { return nil }
        return Self.clean(r.text, prefix: prefix, suffix: suffix)
    }

    /// Make a model's answer safe to drop in at the cursor.
    static func clean(_ raw: String, prefix: String, suffix: String) -> String? {
        var t = raw.contains("```") ? CodeMerge.stripFences(raw) : CodeMerge.stripBetween(raw, "<think>", "</think>")
        t = t.replacingOccurrences(of: "<prefix>", with: "").replacingOccurrences(of: "</prefix>", with: "")
        if let r = t.range(of: "<suffix>") { t = String(t[..<r.lowerBound]) }
        let lineStart = prefix.components(separatedBy: "\n").last ?? ""
        let typed = lineStart.trimmingCharacters(in: .whitespaces)
        // the model repeated the current line
        if !typed.isEmpty, t.trimmingCharacters(in: .whitespaces).hasPrefix(typed) {
            if let r = t.range(of: typed) { t = String(t[r.upperBound...]) }
        }
        // cursor sits after indentation: don't indent the first line twice
        if typed.isEmpty && !lineStart.isEmpty {
            let lead = t.prefix { $0 == " " }
            if lead.count >= lineStart.count { t = String(t.dropFirst(lineStart.count)) }
        }
        // don't duplicate what follows the cursor
        let nextLine = suffix.split(separator: "\n", omittingEmptySubsequences: true).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var lines = t.components(separatedBy: "\n")
        while let lastLine = lines.last, lastLine.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if !nextLine.isEmpty, let lastLine = lines.last, lastLine.trimmingCharacters(in: .whitespaces) == nextLine, lines.count > 1 { lines.removeLast() }
        if lines.count > 12 { lines = Array(lines.prefix(12)) }
        t = lines.joined(separator: "\n")
        while t.hasSuffix(" ") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t
    }

    // MARK: ⌘→ accept next word

    func acceptNextWord() {
        guard let pane = Services.shared.editor as? EditorPane else { return }
        guard let g = pane.ghostText, !g.isEmpty else {
            pane.textView.moveToRightEndOfLine(nil)
            return
        }
        let loc = pane.textView.selectedRange().location
        var word = ""
        var idx = g.startIndex
        while idx < g.endIndex, g[idx] == " " || g[idx] == "\n" || g[idx] == "\t" { word.append(g[idx]); idx = g.index(after: idx) }
        if idx < g.endIndex {
            if g[idx].isLetter || g[idx].isNumber || g[idx] == "_" {
                while idx < g.endIndex, g[idx].isLetter || g[idx].isNumber || g[idx] == "_" { word.append(g[idx]); idx = g.index(after: idx) }
            } else {
                word.append(g[idx]); idx = g.index(after: idx)
            }
        }
        let rest = String(g[idx...])
        pane.setGhostText(nil, at: nil)
        pane.textView.insertText(word, replacementRange: NSRange(location: loc, length: 0))
        let newLoc = loc + (word as NSString).length
        if !rest.isEmpty { pane.setGhostText(rest, at: newLoc) }
        last = nil
    }

    // MARK: next-edit prediction

    private static let declLead = try! NSRegularExpression(pattern: #"^\s*(let|fix|to|type|kind|has|for each)\s"#)

    /// After a rename at a declaration, offer the same rename for the other uses in the file.
    private func predictNextEdit(_ ed: EditorController) {
        let id = ed.document.id
        let new = ed.text
        defer { snapshots[id] = new }
        guard vee.settings.nextEditPrediction, !ed.hasInlineDiff, let old = snapshots[id], old != new else { return }
        let o = old.components(separatedBy: "\n"), n = new.components(separatedBy: "\n")
        guard o.count == n.count else { return }
        let changed = (0..<o.count).filter { o[$0] != n[$0] }
        guard changed.count == 1, let li = changed.first else { return }
        let ol = o[li], nl = n[li]
        guard Self.declLead.firstMatch(in: nl, range: NSRange(location: 0, length: (nl as NSString).length)) != nil else { return }
        let ow = Self.words(ol), nw = Self.words(nl)
        guard ow.count == nw.count else { return }
        let diffs = zip(ow, nw).filter { $0 != $1 }
        guard diffs.count == 1, let (from, to) = diffs.first, from.count > 1, to.count > 0,
              !VantaLexer.keywords.contains(from), !VantaLexer.keywords.contains(to) else { return }
        guard let re = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b") else { return }
        var lines = n
        var count = 0
        for i in 0..<lines.count where i != li {
            let l = lines[i] as NSString
            let ms = re.numberOfMatches(in: lines[i], range: NSRange(location: 0, length: l.length))
            if ms > 0 {
                count += ms
                lines[i] = re.stringByReplacingMatches(in: lines[i], range: NSRange(location: 0, length: l.length), withTemplate: NSRegularExpression.escapedTemplate(for: to))
            }
        }
        guard count > 0, let region = LineDiff.changedRegion(old: new, new: lines.joined(separator: "\n")) else { return }
        ed.showInlineDiff(range: region.range, newText: region.replacement, onAccept: {
            Services.shared.flash("Renamed \(count) more use\(count == 1 ? "" : "s") of ‘\(from)’")
        }, onReject: {})
        Services.shared.flash("Vee: rename the other \(count) use\(count == 1 ? "" : "s") of ‘\(from)’ too? ⌘↩ accept · Esc dismiss")
    }

    private static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        for ch in s { if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { if !cur.isEmpty { out.append(cur) }; cur = "" } }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
