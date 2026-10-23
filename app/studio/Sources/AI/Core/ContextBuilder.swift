import Foundation

/// Turns a chat message + its @-mentions and attachments into the context block
/// sent with it: the active file, explicit mentions (@file, @folder, @selection,
/// @problems, @console, @book, @docs, @codebase), and automatically retrieved
/// book sections and workspace code.
enum ContextBuilder {
    struct Built {
        var text: String = ""
        var refs: [ContextRef] = []
    }

    struct Mention: Hashable { let raw: String; let name: String }

    static let specials: [(name: String, icon: String, help: String)] = [
        ("selection", "selection.pin.in.out", "the code selected in the editor"),
        ("problems", "exclamationmark.triangle", "errors & warnings from the Problems panel"),
        ("console", "terminal", "the last program output"),
        ("codebase", "chevron.left.forwardslash.chevron.right", "search the whole workspace"),
        ("book", "book", "search The Vanta Book"),
        ("docs", "doc.richtext", "search the Vanta docs"),
    ]

    static func mentions(in text: String) -> [Mention] {
        var out: [Mention] = []
        let ns = text as NSString
        let re = try! NSRegularExpression(pattern: #"(?:^|\s)@([^\s]+)"#)
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var name = ns.substring(with: m.range(at: 1))
            while let last = name.last, ".,;:!?)".contains(last), !name.hasSuffix(".va") { name.removeLast() }
            out.append(Mention(raw: "@" + name, name: name))
        }
        return out
    }

    /// The message with @mentions removed — what retrieval should search for.
    static func query(from text: String) -> String {
        var t = text
        for m in mentions(in: text) { t = t.replacingOccurrences(of: m.raw, with: m.name.contains("/") || m.name.contains(".") ? "" : " ") }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func build(message: String, attachments: [ChatAttachment], mode: String, settings: AISettings,
                      extraQuery: String = "") -> Built {
        var b = Built()
        var parts: [String] = []
        let ms = mentions(in: message)
        let names = Set(ms.map { $0.name.lowercased() })
        let q = (query(from: message) + " " + extraQuery).trimmingCharacters(in: .whitespaces)
        let s = Services.shared

        // explicit attachments (⌘L selection, Explain/Test commands)
        for a in attachments {
            parts.append("<selection file=\"\(a.path ?? "untitled")\" lines=\"\(a.startLine + 1)-\(a.startLine + a.text.components(separatedBy: "\n").count)\">\n\(a.text)\n</selection>")
            b.refs.append(ContextRef(kind: .selection, label: a.label, path: a.path, line: a.startLine))
        }

        // @selection
        if names.contains("selection"), let ed = s.editor, !ed.selectedText.isEmpty {
            let line = ed.position(of: ed.selections.first?.location ?? 0).line
            let path = ed.url.map(WorkspaceFS.relative) ?? ed.document.name
            parts.append("<selection file=\"\(path)\" line=\"\(line + 1)\">\n\(ed.selectedText)\n</selection>")
            b.refs.append(ContextRef(kind: .selection, label: "selection · \(path):\(line + 1)", path: path, line: line))
        }

        // @file / @folder
        for m in ms where !specials.contains(where: { $0.name == m.name.lowercased() }) {
            guard let url = try? WorkspaceFS.resolve(m.name) else { continue }
            if WorkspaceFS.isDirectory(url) {
                parts.append(folderContext(url))
                b.refs.append(ContextRef(kind: .folder, label: WorkspaceFS.relative(url) + "/", path: url.path))
            } else if let text = WorkspaceFS.read(url) {
                parts.append("<file path=\"\(WorkspaceFS.relative(url))\">\n\(clip(text, 30000))\n</file>")
                b.refs.append(ContextRef(kind: .file, label: WorkspaceFS.relative(url), path: url.path))
            }
        }

        // @problems
        if names.contains("problems") {
            let all = DiagnosticsStore.shared.all.filter { !$0.1.isEmpty }
            var lines: [String] = []
            for (uri, diags) in all {
                for d in diags.prefix(30) {
                    let sev = d.severity == .error ? "error" : d.severity == .warning ? "warning" : "info"
                    lines.append("\(WorkspaceFS.relative(uri)):\(d.range.start.line + 1): \(sev): \(d.message) [\(d.source)]")
                }
            }
            parts.append("<problems>\n\(lines.isEmpty ? "(no problems reported)" : lines.joined(separator: "\n"))\n</problems>")
            b.refs.append(ContextRef(kind: .problems, label: "problems (\(lines.count))"))
        }

        // @console
        if names.contains("console") {
            let out = RunController.shared.console
            parts.append("<console last_run_failed=\"\(RunController.shared.lastRunFailed)\">\n\(out.isEmpty ? "(empty)" : String(out.suffix(5000)))\n</console>")
            b.refs.append(ContextRef(kind: .console, label: "console"))
        }

        // knowledge
        let kb = KnowledgeBase.shared
        var bookChunks: [KnowledgeChunk] = []
        if names.contains("book") { bookChunks += kb.search(q.isEmpty ? message : q, k: 6, sources: [.book]) }
        if names.contains("docs") { bookChunks += kb.search(q.isEmpty ? message : q, k: 6, sources: [.docs]) }
        if mode == "book" { bookChunks += kb.search(q.isEmpty ? message : q, k: 8) }
        else if settings.useBookKnowledge && !names.contains("book") && !names.contains("docs") && !q.isEmpty {
            bookChunks += kb.search(q, k: mode == "fix" ? 3 : 4)
        }
        bookChunks = unique(bookChunks)
        if !bookChunks.isEmpty {
            parts.append("<vanta_book_excerpts>\n" + KnowledgeBase.render(bookChunks, maxChars: mode == "book" ? 16000 : 9000) + "</vanta_book_excerpts>")
            for c in bookChunks { b.refs.append(ContextRef(kind: c.source == .book ? .book : .docs, label: c.citation, path: c.fileURL.path, line: c.line)) }
        }

        // codebase
        if mode != "book" {
            var code: [KnowledgeChunk] = []
            if names.contains("codebase") { code = CodebaseIndex.shared.search(q.isEmpty ? message : q, k: 8) }
            else if settings.indexCodebase && mode == "chat" && !q.isEmpty && s.workspace.root != nil {
                let active = s.editors.activeDocument?.url?.standardizedFileURL
                code = CodebaseIndex.shared.search(q, k: 4).filter { $0.fileURL.standardizedFileURL != active }.prefix(3).map { $0 }
            }
            if !code.isEmpty {
                var t = "<workspace_code>\n"
                for c in code { t += "<chunk path=\"\(c.docTitle)\" line=\"\(c.line + 1)\" what=\"\(c.heading)\">\n\(clip(c.text, 3000))\n</chunk>\n" }
                parts.append(t + "</workspace_code>")
                for c in code { b.refs.append(ContextRef(kind: .code, label: "\(c.docTitle):\(c.line + 1)", path: c.fileURL.path, line: c.line)) }
            }
        }

        // the active file
        if mode == "chat" || mode == "fix", let doc = s.editors.activeDocument {
            let path = doc.url.map(WorkspaceFS.relative) ?? doc.name
            if !ms.contains(where: { (try? WorkspaceFS.resolve($0.name))?.standardizedFileURL == doc.url?.standardizedFileURL }) {
                let cursor = s.editor?.cursorPosition.line ?? 0
                parts.append("<active_file path=\"\(path)\" cursor_line=\"\(cursor + 1)\">\n\(window(doc.text, around: cursor, maxChars: 16000))\n</active_file>")
                b.refs.append(ContextRef(kind: .activeFile, label: path, path: doc.url?.path, line: cursor))
            }
        } else if mode == "agent" {
            var t = "<workspace root=\"\(WorkspaceFS.root?.lastPathComponent ?? "")\">\n"
            let outline = CodebaseIndex.shared.outline()
            t += outline.isEmpty ? "(empty or not indexed yet — use list_files)\n" : outline + "\n"
            if let doc = s.editors.activeDocument {
                t += "Active file in the editor: \(doc.url.map(WorkspaceFS.relative) ?? doc.name) (cursor on line \((s.editor?.cursorPosition.line ?? 0) + 1))\n"
            }
            parts.append(t + "</workspace>")
        }

        b.text = parts.joined(separator: "\n\n")
        return b
    }

    static func folderContext(_ url: URL) -> String {
        let fm = FileManager.default
        var listing: [String] = []
        var body = ""
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                if Workspace.ignoredNames.contains(f.lastPathComponent) { e.skipDescendants(); continue }
                if WorkspaceFS.isDirectory(f) { continue }
                listing.append(WorkspaceFS.relative(f))
                if listing.count > 200 { break }
                if f.pathExtension == "va", body.count < 14000, let t = WorkspaceFS.read(f) {
                    body += "<file path=\"\(WorkspaceFS.relative(f))\">\n\(clip(t, 4000))\n</file>\n"
                }
            }
        }
        return "<folder path=\"\(WorkspaceFS.relative(url))/\">\n" + listing.joined(separator: "\n") + "\n</folder>\n" + body
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "\n…(truncated, \(s.count - n) more characters)"
    }

    /// The whole file when it fits; otherwise a window around the cursor, with line numbers.
    static func window(_ text: String, around line: Int, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        let lines = text.components(separatedBy: "\n")
        var lo = max(0, line - 1), hi = min(lines.count, line + 1)
        var size = 0
        while size < maxChars && (lo > 0 || hi < lines.count) {
            if lo > 0 { lo -= 1; size += lines[lo].count + 1 }
            if hi < lines.count { size += lines[hi].count + 1; hi += 1 }
        }
        return "(showing lines \(lo + 1)–\(hi) of \(lines.count))\n" + lines[lo..<hi].joined(separator: "\n")
    }

    private static func unique(_ c: [KnowledgeChunk]) -> [KnowledgeChunk] {
        var seen = Set<Int>(); var out: [KnowledgeChunk] = []
        for x in c where !seen.contains(x.id) { seen.insert(x.id); out.append(x) }
        return out
    }
}
