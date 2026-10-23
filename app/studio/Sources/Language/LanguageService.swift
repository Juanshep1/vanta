import Foundation
import Combine

/// A quick fix the server offered for a diagnostic (applied from the Problems panel,
/// the hover, or ⌥↩ "Quick Fix").
struct QuickFix: Identifiable {
    let id = UUID()
    var title: String
    var uri: URL
    var edits: [URL: [LSPTextEdit]]
    var diagnosticRange: TextRange
    var isPreferred = false
}

struct LSPTextEdit: Hashable {
    var range: TextRange
    var newText: String
}

/// Owns the Vanta language server (one per workspace) and keeps it in sync with the
/// open documents: didOpen / debounced didChange / didClose, diagnostics → the
/// DiagnosticsStore, and typed wrappers for every request the providers make.
final class LanguageService: ObservableObject {
    static let shared = LanguageService()

    enum State: Equatable { case stopped, starting, ready, failed(String) }
    @Published private(set) var state: State = .stopped

    private(set) var client: LSPClient?
    private var clientRoot: URL?
    private var tracked: [UUID: Tracked] = [:]
    private var bag = Set<AnyCancellable>()
    /// Fixes by uri (rebuilt whenever that file's diagnostics arrive).
    private(set) var fixes: [URL: [(range: TextRange, message: String, replacement: String)]] = [:]
    /// Everything that wants to know diagnostics arrived (tests: wait for a file).
    let diagnosticsArrived = PassthroughSubject<URL, Never>()

    static let diagnosticSources = ["vanta", "vanta check"]
    var debounce: TimeInterval = 0.25

    private final class Tracked {
        let doc: Document
        var uri: URL
        var version = 1
        var lastSent = ""
        var work: DispatchWorkItem?
        var sub: AnyCancellable?
        var urlSub: AnyCancellable?
        init(doc: Document) { self.doc = doc; self.uri = doc.uri }
    }

    private init() {}

    // MARK: lifecycle

    func start(_ s: Services) {
        s.workspace.$root.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] root in self?.useRoot(root) }
            .store(in: &bag)
        s.documents.$documents.receive(on: DispatchQueue.main)
            .sink { [weak self] docs in self?.syncDocuments(docs) }
            .store(in: &bag)
        s.workspace.filesChanged.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.client?.notify("workspace/didChangeWatchedFiles", ["changes": []]) }
            .store(in: &bag)
    }

    private func useRoot(_ root: URL?) {
        if client != nil && clientRoot == root { return }
        client?.stop()
        for t in tracked.values { t.lastSent = ""; t.version = 1 }
        clientRoot = root
        let c = LSPClient(root: root)
        client = c
        state = .starting
        c.onNotification = { [weak self] method, params in self?.handle(method, params) }
        c.onReady = { [weak self] in
            guard let self, self.client === c else { return }
            self.state = .ready
            for t in self.tracked.values { self.open(t) }
        }
        c.onFailure = { [weak self] why in
            guard let self, self.client === c else { return }
            self.state = .failed(why)
            Services.shared.flash("Vanta language server: \(why)")
        }
        c.start()
    }

    func restart() {
        guard let c = client else { useRoot(Services.shared.workspace.root); return }
        state = .starting
        for t in tracked.values { t.lastSent = ""; t.version = 1 }
        for src in Self.diagnosticSources { Services.shared.diagnostics.clear(source: src) }
        c.restart()
        Services.shared.flash("Restarting the Vanta language server…")
    }

    // MARK: documents

    private func syncDocuments(_ docs: [Document]) {
        let ids = Set(docs.map(\.id))
        for (id, t) in tracked where !ids.contains(id) {
            t.work?.cancel()
            if client?.isReady == true { client?.notify("textDocument/didClose", ["textDocument": ["uri": t.uri.absoluteString]]) }
            for src in Self.diagnosticSources { Services.shared.diagnostics.publish([], for: t.uri, source: src) }
            tracked[id] = nil
        }
        for d in docs where tracked[d.id] == nil && d.language == .vanta {
            let t = Tracked(doc: d)
            t.sub = d.changes.receive(on: DispatchQueue.main).sink { [weak self, weak t] _ in
                guard let self, let t else { return }
                self.scheduleChange(t)
            }
            t.urlSub = d.$url.dropFirst().receive(on: DispatchQueue.main).sink { [weak self, weak t] _ in
                guard let self, let t else { return }
                self.retarget(t)
            }
            tracked[d.id] = t
            if client?.isReady == true { open(t) }
        }
    }

    private func open(_ t: Tracked) {
        guard let c = client, c.isReady else { return }
        t.uri = t.doc.uri
        t.lastSent = t.doc.text
        t.version += 1
        c.notify("textDocument/didOpen", ["textDocument": ["uri": t.uri.absoluteString, "languageId": "vanta",
                                                           "version": t.version, "text": t.lastSent]])
    }

    private func retarget(_ t: Tracked) {
        client?.notify("textDocument/didClose", ["textDocument": ["uri": t.uri.absoluteString]])
        for src in Self.diagnosticSources { Services.shared.diagnostics.publish([], for: t.uri, source: src) }
        open(t)
    }

    private func scheduleChange(_ t: Tracked) {
        t.work?.cancel()
        let w = DispatchWorkItem { [weak self, weak t] in
            guard let self, let t else { return }
            self.sendChange(t)
        }
        t.work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: w)
    }

    private func sendChange(_ t: Tracked) {
        t.work?.cancel()
        t.work = nil
        guard let c = client, c.isReady else { return }
        let text = t.doc.text
        guard text != t.lastSent else { return }
        t.lastSent = text
        t.version += 1
        c.notify("textDocument/didChange", ["textDocument": ["uri": t.uri.absoluteString, "version": t.version],
                                            "contentChanges": [["text": text]]])
    }

    /// Make sure the server has exactly `text` for `uri` before asking about it.
    func ensureSynced(uri: URL, text: String) {
        if let t = tracked.values.first(where: { $0.uri == uri }) {
            if t.lastSent != text, let c = client, c.isReady {
                t.work?.cancel()
                t.lastSent = text
                t.version += 1
                c.notify("textDocument/didChange", ["textDocument": ["uri": uri.absoluteString, "version": t.version],
                                                    "contentChanges": [["text": text]]])
            }
            return
        }
        // not an editor document (e.g. a file the outline asked about): give the server the text
        client?.whenReady { [weak self] in
            self?.client?.notify("textDocument/didOpen", ["textDocument": ["uri": uri.absoluteString, "languageId": "vanta",
                                                                           "version": 1, "text": text]])
        }
    }

    func trackedDocument(for uri: URL) -> Document? { tracked.values.first { $0.uri == uri }?.doc }

    /// A server uri → the URL our documents use (so diagnostics land on the open tab).
    func localURL(_ s: String) -> URL? {
        guard let u = URL(string: s) else { return nil }
        if let t = tracked.values.first(where: { $0.uri.absoluteString == s }) { return t.uri }
        if u.isFileURL {
            let p = u.standardizedFileURL.resolvingSymlinksInPath().path
            if let t = tracked.values.first(where: { $0.uri.isFileURL && $0.uri.standardizedFileURL.resolvingSymlinksInPath().path == p }) {
                return t.uri
            }
            return URL(fileURLWithPath: u.path)
        }
        return u
    }

    // MARK: notifications

    private func handle(_ method: String, _ params: [String: Any]) {
        guard method == "textDocument/publishDiagnostics", let us = params["uri"] as? String,
              let uri = localURL(us) else { return }
        let raw = params["diagnostics"] as? [[String: Any]] ?? []
        var bySource: [String: [Diagnostic]] = [:]
        var fx: [(range: TextRange, message: String, replacement: String)] = []
        for d in raw {
            guard let r = Self.range(d["range"]) else { continue }
            let sev = DiagnosticSeverity(rawValue: d["severity"] as? Int ?? 1) ?? .error
            let source = (d["source"] as? String).flatMap { Self.diagnosticSources.contains($0) ? $0 : nil } ?? "vanta"
            let msg = d["message"] as? String ?? ""
            var diag = Diagnostic(range: r, severity: sev, message: msg, source: source)
            diag.code = d["code"] as? String
            bySource[source, default: []].append(diag)
            if let data = d["data"] as? [String: Any], let rep = data["replace"] as? String {
                fx.append((r, msg, rep))
            }
        }
        fixes[uri] = fx.isEmpty ? nil : fx
        for src in Self.diagnosticSources {
            Services.shared.diagnostics.publish(bySource[src] ?? [], for: uri, source: src)
        }
        diagnosticsArrived.send(uri)
    }

    // MARK: conversions

    static func position(_ any: Any?) -> TextPosition? {
        guard let p = any as? [String: Any], let l = p["line"] as? Int, let c = p["character"] as? Int else { return nil }
        return TextPosition(line: l, column: c)
    }

    static func range(_ any: Any?) -> TextRange? {
        guard let r = any as? [String: Any], let s = position(r["start"]), let e = position(r["end"]) else { return nil }
        return TextRange(start: s, end: e)
    }

    static func json(_ p: TextPosition) -> [String: Any] { ["line": p.line, "character": p.column] }
    static func json(_ r: TextRange) -> [String: Any] { ["start": json(r.start), "end": json(r.end)] }

    func location(_ any: Any?) -> Location? {
        guard let l = any as? [String: Any], let us = l["uri"] as? String, let uri = localURL(us),
              let r = Self.range(l["range"]) else { return nil }
        return Location(uri: uri, range: r)
    }

    func locations(_ any: Any?) -> [Location] {
        if let arr = any as? [Any] { return arr.compactMap { location($0) } }
        return location(any).map { [$0] } ?? []
    }

    func workspaceEdit(_ any: Any?) -> [URL: [LSPTextEdit]] {
        var out: [URL: [LSPTextEdit]] = [:]
        guard let we = any as? [String: Any] else { return out }
        if let changes = we["changes"] as? [String: Any] {
            for (us, list) in changes {
                guard let uri = localURL(us), let edits = list as? [[String: Any]] else { continue }
                out[uri, default: []] += edits.compactMap { e in
                    Self.range(e["range"]).map { LSPTextEdit(range: $0, newText: e["newText"] as? String ?? "") }
                }
            }
        }
        if let dc = we["documentChanges"] as? [[String: Any]] {
            for c in dc {
                guard let td = c["textDocument"] as? [String: Any], let us = td["uri"] as? String,
                      let uri = localURL(us), let edits = c["edits"] as? [[String: Any]] else { continue }
                out[uri, default: []] += edits.compactMap { e in
                    Self.range(e["range"]).map { LSPTextEdit(range: $0, newText: e["newText"] as? String ?? "") }
                }
            }
        }
        return out
    }

    // MARK: requests

    private func docParams(_ uri: URL, _ pos: TextPosition) -> [String: Any] {
        ["textDocument": ["uri": uri.absoluteString], "position": Self.json(pos)]
    }

    func request(_ method: String, _ params: [String: Any], timeout: TimeInterval = 8) async -> Result<Any?, LSPError> {
        guard let c = client else { return .failure(LSPError(code: -1, message: "no language server")) }
        return await c.request(method, params, timeout: timeout)
    }

    @MainActor
    func sync(_ ctx: DocumentContext) { ensureSynced(uri: ctx.uri, text: ctx.text) }

    func completion(_ ctx: DocumentContext) async -> [[String: Any]] {
        await MainActor.run { sync(ctx) }
        let r = await request("textDocument/completion", docParams(ctx.uri, ctx.position))
        guard case .success(let v) = r else { return [] }
        if let list = v as? [String: Any] { return list["items"] as? [[String: Any]] ?? [] }
        return v as? [[String: Any]] ?? []
    }

    func hover(_ ctx: DocumentContext) async -> String? {
        await MainActor.run { sync(ctx) }
        guard case .success(let v) = await request("textDocument/hover", docParams(ctx.uri, ctx.position)),
              let h = v as? [String: Any] else { return nil }
        if let c = h["contents"] as? [String: Any] { return c["value"] as? String }
        if let s = h["contents"] as? String { return s }
        return nil
    }

    func definition(_ ctx: DocumentContext) async -> [Location] {
        await MainActor.run { sync(ctx) }
        guard case .success(let v) = await request("textDocument/definition", docParams(ctx.uri, ctx.position)) else { return [] }
        return await MainActor.run { locations(v) }
    }

    func references(uri: URL, text: String, position: TextPosition, includeDeclaration: Bool = true) async -> [Location] {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        var p = docParams(uri, position)
        p["context"] = ["includeDeclaration": includeDeclaration]
        guard case .success(let v) = await request("textDocument/references", p, timeout: 30) else { return [] }
        return await MainActor.run { locations(v) }
    }

    func prepareRename(uri: URL, text: String, position: TextPosition) async -> Result<(TextRange, String), LSPError> {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        switch await request("textDocument/prepareRename", docParams(uri, position)) {
        case .failure(let e): return .failure(e)
        case .success(let v):
            guard let d = v as? [String: Any], let r = Self.range(d["range"]) else {
                return .failure(LSPError(code: 0, message: "Nothing to rename here."))
            }
            return .success((r, d["placeholder"] as? String ?? ""))
        }
    }

    func rename(uri: URL, text: String, position: TextPosition, to newName: String) async -> Result<[URL: [LSPTextEdit]], LSPError> {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        var p = docParams(uri, position)
        p["newName"] = newName
        switch await request("textDocument/rename", p, timeout: 30) {
        case .failure(let e): return .failure(e)
        case .success(let v): return .success(await MainActor.run { workspaceEdit(v) })
        }
    }

    struct Signature {
        var label: String
        var parameters: [NSRange]
        var active: Int
        var documentation: String?
    }

    func signatureHelp(uri: URL, text: String, position: TextPosition) async -> Signature? {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        guard case .success(let v) = await request("textDocument/signatureHelp", docParams(uri, position), timeout: 4),
              let h = v as? [String: Any], let sigs = h["signatures"] as? [[String: Any]], !sigs.isEmpty else { return nil }
        let sig = sigs[min(h["activeSignature"] as? Int ?? 0, sigs.count - 1)]
        let label = sig["label"] as? String ?? ""
        let ns = label as NSString
        var ranges: [NSRange] = []
        for p in sig["parameters"] as? [[String: Any]] ?? [] {
            if let pair = p["label"] as? [Int], pair.count == 2 {
                ranges.append(NSRange(location: pair[0], length: pair[1] - pair[0]))
            } else if let s = p["label"] as? String {
                ranges.append(ns.range(of: s))
            }
        }
        var doc: String?
        if let d = sig["documentation"] as? [String: Any] { doc = d["value"] as? String } else { doc = sig["documentation"] as? String }
        return Signature(label: label, parameters: ranges, active: h["activeParameter"] as? Int ?? 0, documentation: doc)
    }

    func documentSymbols(text: String, uri: URL) async -> [DocumentSymbol]? {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        guard case .success(let v) = await request("textDocument/documentSymbol", ["textDocument": ["uri": uri.absoluteString]]),
              let arr = v as? [[String: Any]] else { return nil }
        func conv(_ d: [String: Any]) -> DocumentSymbol? {
            guard let name = d["name"] as? String, let r = Self.range(d["range"]) else { return nil }
            let sel = Self.range(d["selectionRange"]) ?? r
            let kind: SymbolKind
            switch d["kind"] as? Int ?? 13 {
            case 12: kind = .function
            case 6: kind = .method
            case 5: kind = .type
            case 10: kind = .kind
            case 8: kind = .field
            case 22, 14: kind = .constant
            case 24: kind = .test
            default: kind = .variable
            }
            var detail = d["detail"] as? String ?? ""
            if (d["kind"] as? Int) == 2 { detail = "module " + detail }
            if kind == .test { detail = "" }
            var s = DocumentSymbol(name: name, kind: kind, detail: detail, line: sel.start.line,
                                   endLine: r.end.line > sel.start.line ? r.end.line : nil)
            s.children = (d["children"] as? [[String: Any]] ?? []).compactMap(conv)
            return s
        }
        return arr.compactMap(conv)
    }

    func format(text: String, uri: URL) async -> String? {
        await MainActor.run { ensureSynced(uri: uri, text: text) }
        guard case .success(let v) = await request("textDocument/formatting",
                                                   ["textDocument": ["uri": uri.absoluteString],
                                                    "options": ["tabSize": 4, "insertSpaces": true]], timeout: 15),
              let edits = v as? [[String: Any]] else { return nil }
        guard let first = edits.first, let newText = first["newText"] as? String else { return text }
        return newText
    }

    /// Quick fixes for the diagnostics touching `range` in `uri` (from the server's code actions).
    func quickFixes(uri: URL, text: String, range: TextRange) async -> [QuickFix] {
        let diags = await MainActor.run { () -> [[String: Any]] in
            ensureSynced(uri: uri, text: text)
            return Services.shared.diagnostics.diagnostics(for: uri).filter {
                Self.diagnosticSources.contains($0.source) &&
                $0.range.start.line <= range.end.line && $0.range.end.line >= range.start.line
            }.map { d in
                var j: [String: Any] = ["range": Self.json(d.range), "severity": d.severity.rawValue,
                                        "message": d.message, "source": d.source]
                if let c = d.code { j["code"] = c }
                if let f = fixes[uri]?.first(where: { $0.range == d.range && $0.message == d.message }) {
                    j["data"] = ["replace": f.replacement]
                }
                return j
            }
        }
        guard !diags.isEmpty else { return [] }
        let p: [String: Any] = ["textDocument": ["uri": uri.absoluteString], "range": Self.json(range),
                                "context": ["diagnostics": diags]]
        guard case .success(let v) = await request("textDocument/codeAction", p), let arr = v as? [[String: Any]] else { return [] }
        return await MainActor.run {
            arr.compactMap { a -> QuickFix? in
                guard let title = a["title"] as? String else { return nil }
                let edits = workspaceEdit(a["edit"])
                guard !edits.isEmpty else { return nil }
                let dr = ((a["diagnostics"] as? [[String: Any]])?.first).flatMap { Self.range($0["range"]) } ?? range
                return QuickFix(title: title, uri: uri, edits: edits, diagnosticRange: dr,
                                isPreferred: a["isPreferred"] as? Bool ?? false)
            }
        }
    }

    // MARK: applying edits

    /// Apply a workspace edit: open documents are edited in place (undoable, left
    /// unsaved like any edit); files that aren't open are rewritten on disk.
    @discardableResult
    func apply(_ edits: [URL: [LSPTextEdit]]) -> Int {
        var count = 0
        let s = Services.shared
        for (uri, list) in edits where !list.isEmpty {
            let doc = s.documents.documents.first { $0.uri == uri } ??
                (uri.isFileURL ? s.documents.document(for: uri) : nil)
            if let doc {
                let ns = doc.text as NSString
                var lines = LineIndex()
                lines.rebuild(ns)
                let ranges = list.map { e -> (NSRange, String) in
                    let a = lines.offset(of: e.range.start), b = lines.offset(of: e.range.end)
                    return (NSRange(location: a, length: max(0, b - a)), e.newText)
                }.sorted { $0.0.location > $1.0.location }
                if let pane = s.editors.groups.lazy.compactMap({ $0.existingPane(for: doc) }).first {
                    pane.replace(edits: ranges.map { (range: $0.0, text: $0.1) })
                } else {
                    doc.undoManager.beginUndoGrouping()
                    for (r, t) in ranges { doc.replace(r, with: t) }
                    doc.undoManager.endUndoGrouping()
                }
                count += list.count
            } else if uri.isFileURL, let data = try? Data(contentsOf: uri) {
                let text = String(decoding: data, as: UTF8.self)
                let ns = NSMutableString(string: text)
                var lines = LineIndex()
                lines.rebuild(ns)
                let ranges = list.map { e -> (NSRange, String) in
                    let a = lines.offset(of: e.range.start), b = lines.offset(of: e.range.end)
                    return (NSRange(location: a, length: max(0, b - a)), e.newText)
                }.sorted { $0.0.location > $1.0.location }
                for (r, t) in ranges { ns.replaceCharacters(in: r, with: t) }
                do {
                    try (ns as String).write(to: uri, atomically: true, encoding: .utf8)
                    count += list.count
                } catch {
                    s.flash("Couldn't write \(uri.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        return count
    }
}
