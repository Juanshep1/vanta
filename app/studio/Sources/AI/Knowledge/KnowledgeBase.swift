import Foundation

/// One retrievable section of the Vanta Book, the Vanta docs, or the workspace.
struct KnowledgeChunk: Identifiable, Hashable {
    enum Source: String { case book, docs, code }
    let id: Int
    let source: Source
    let fileURL: URL
    /// Chapter / document title ("Functions").
    let docTitle: String
    /// Section path inside the document ("Defaults › Named values").
    let heading: String
    let text: String
    /// 0-based line where the chunk starts.
    let line: Int

    var citation: String {
        heading.isEmpty || heading == docTitle ? docTitle : "\(docTitle) › \(heading)"
    }
    var label: String {
        switch source {
        case .book: return "Book: " + citation
        case .docs: return "Docs: " + citation
        case .code: return citation
        }
    }
}

/// The Vanta Book chapters + Vanta docs, chunked by section and indexed with
/// BM25. Loads from the app bundle (`Resources/knowledge/{book,docs}`, copied
/// at build time) and falls back to the source folders on this Mac.
final class KnowledgeBase: ObservableObject {
    static let shared = KnowledgeBase()

    struct Document: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let title: String
        let source: KnowledgeChunk.Source
        let order: Int
    }

    @Published private(set) var isLoaded = false
    private(set) var documents: [Document] = []
    private(set) var chunks: [KnowledgeChunk] = []
    private var index = BM25Index(documents: [])
    private let queue = DispatchQueue(label: "vanta.ai.knowledge", qos: .utility)
    private var loading = false
    private var waiters: [() -> Void] = []
    private(set) var cheatSheet = ""
    private(set) var compactCheatSheet = ""

    // MARK: locations

    static var bookFolder: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("knowledge/book"), fm.fileExists(atPath: r.path) { return r }
        let dev = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta-book/chapters")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }

    static var docsFolder: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("knowledge/docs"), fm.fileExists(atPath: r.path) { return r }
        if let r = Bundle.main.resourceURL?.appendingPathComponent("runtime/docs"), fm.fileExists(atPath: r.path) { return r }
        let dev = fm.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta/docs")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }

    static var pdfURL: URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent("Desktop/The-Vanta-Book.pdf"),
                          home.appendingPathComponent("Documents/The-Vanta-Book.pdf"),
                          Bundle.main.resourceURL?.appendingPathComponent("knowledge/The-Vanta-Book.pdf")].compactMap { $0 }
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    // MARK: loading

    /// Load (once) on a background queue; `then` runs on the main thread.
    func load(then: (() -> Void)? = nil) {
        if isLoaded { then?(); return }
        if let then { waiters.append(then) }
        guard !loading else { return }
        loading = true
        queue.async {
            let built = Self.build()
            DispatchQueue.main.async {
                self.documents = built.docs
                self.chunks = built.chunks
                self.index = built.index
                self.cheatSheet = built.cheat
                self.compactCheatSheet = built.compact
                self.isLoaded = true
                self.loading = false
                let w = self.waiters; self.waiters = []
                w.forEach { $0() }
            }
        }
    }

    /// Synchronous load (tests, or the first request when nothing has loaded yet).
    func loadNow() {
        guard !isLoaded else { return }
        let built = Self.build()
        documents = built.docs; chunks = built.chunks; index = built.index
        cheatSheet = built.cheat; compactCheatSheet = built.compact
        isLoaded = true
    }

    private static func build() -> (docs: [Document], chunks: [KnowledgeChunk], index: BM25Index, cheat: String, compact: String) {
        var docs: [Document] = []
        var chunks: [KnowledgeChunk] = []
        var syntax = "", builtins = ""
        func ingest(_ folder: URL?, _ source: KnowledgeChunk.Source) {
            guard let folder else { return }
            let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "md" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for (i, url) in files.enumerated() {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let text = MarkdownCleaner.clean(raw)
                let title = MarkdownChunker.title(of: text) ?? url.deletingPathExtension().lastPathComponent
                docs.append(Document(url: url, title: title, source: source, order: i))
                if source == .book && url.lastPathComponent.hasPrefix("91-") { syntax = text }
                if source == .book && url.lastPathComponent.hasPrefix("92-") { builtins = raw }
                for c in MarkdownChunker.chunks(text) {
                    chunks.append(KnowledgeChunk(id: chunks.count, source: source, fileURL: url, docTitle: title,
                                                 heading: c.heading, text: c.text, line: c.line))
                }
            }
        }
        ingest(bookFolder, .book)
        ingest(docsFolder, .docs)
        // headings count three times: a section about "lambdas" should win for "lambda"
        let tokenized = chunks.map { c -> [String] in
            let h = Tokenizer.tokens(c.docTitle + " " + c.heading)
            return h + h + h + Tokenizer.tokens(c.text)
        }
        let cheat = CheatSheet.build(syntax: syntax, builtinsRaw: builtins)
        return (docs, chunks, BM25Index(documents: tokenized), cheat, CheatSheet.compact(syntax: syntax))
    }

    // MARK: search

    func search(_ query: String, k: Int = 6, sources: Set<KnowledgeChunk.Source> = [.book, .docs]) -> [KnowledgeChunk] {
        if !isLoaded { loadNow() }
        let q = Tokenizer.tokens(query)
        guard !q.isEmpty else { return [] }
        let hits = index.search(q, k: k * 3) { sources.contains(self.chunks[$0].source) }
        // Diversity: at most two sections from the same document.
        var perDoc: [URL: Int] = [:]
        var out: [KnowledgeChunk] = []
        for h in hits {
            let c = chunks[h.doc]
            if perDoc[c.fileURL, default: 0] >= 2 { continue }
            perDoc[c.fileURL, default: 0] += 1
            out.append(c)
            if out.count == k { break }
        }
        return out
    }

    func scoredSearch(_ query: String, k: Int = 6) -> [(KnowledgeChunk, Double)] {
        if !isLoaded { loadNow() }
        return index.search(Tokenizer.tokens(query), k: k).map { (chunks[$0.doc], $0.score) }
    }

    func chunks(of url: URL) -> [KnowledgeChunk] { chunks.filter { $0.fileURL == url } }

    /// Format retrieved chunks for a prompt.
    static func render(_ chunks: [KnowledgeChunk], maxChars: Int = 9000) -> String {
        var out = ""
        for c in chunks {
            var t = c.text
            if t.count > 2600 { t = String(t.prefix(2600)) + "\n…" }
            let block = "<section source=\"\(c.source.rawValue)\" title=\"\(c.citation)\">\n\(t)\n</section>\n"
            if out.count + block.count > maxChars { break }
            out += block
        }
        return out
    }
}

// MARK: - Markdown chunking

enum MarkdownCleaner {
    /// Book chapters embed HTML tables (the builtins appendix) and <style> tags:
    /// turn table rows into "- `sig` — description" lines and drop the rest.
    static func clean(_ raw: String) -> String {
        guard raw.contains("<") else { return raw }
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<style") || t.hasPrefix("<colgroup") || t.hasPrefix("<thead") || t.hasPrefix("</tbody")
                || t.hasPrefix("<table") || t.hasPrefix("</table") || t.hasPrefix("<div") || t.hasPrefix("</div") { continue }
            if t.hasPrefix("<tr>") {
                let cells = t.components(separatedBy: "<td>").dropFirst().map { stripTags($0) }
                if cells.count >= 2 { lines.append("- \(cells[0]) — \(cells[1...].joined(separator: " "))") }
                else if let c = cells.first { lines.append("- " + c) }
                continue
            }
            lines.append(t.contains("<") && !t.hasPrefix("    ") && !t.hasPrefix("```") ? stripTags(line) : line)
        }
        return lines.joined(separator: "\n")
    }

    static func stripTags(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<code>", with: "`").replacingOccurrences(of: "</code>", with: "`")
        while let o = out.range(of: "<"), let c = out.range(of: ">", range: o.upperBound..<out.endIndex) {
            out.removeSubrange(o.lowerBound..<c.upperBound)
        }
        for (e, r) in [("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: e, with: r)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

enum MarkdownChunker {
    struct Piece { let heading: String; let text: String; let line: Int }

    static func title(of text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true).first { $0.hasPrefix("# ") }
            .map { $0.dropFirst(2).trimmingCharacters(in: .whitespaces) }
    }

    /// Split by `#`/`##`/`###` headings (never inside code fences); long
    /// sections are split again at blank lines.
    static func chunks(_ text: String, maxChars: Int = 2200) -> [Piece] {
        var out: [Piece] = []
        var stack: [String] = []           // heading path by level 2..3
        var cur: [String] = []
        var curStart = 0
        var curHeading = ""
        var inFence = false
        let lines = text.components(separatedBy: "\n")

        func flush() {
            let body = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            defer { cur = [] }
            guard body.count > 40 else { return }
            if body.count <= maxChars { out.append(Piece(heading: curHeading, text: body, line: curStart)); return }
            // split at blank lines outside fences
            var part: [String] = [], fence = false, partStart = curStart, n = 0
            for (i, l) in cur.enumerated() {
                if l.hasPrefix("```") { fence.toggle() }
                part.append(l); n += l.count + 1
                if n >= maxChars * 2 / 3 && l.trimmingCharacters(in: .whitespaces).isEmpty && !fence {
                    let t = part.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(Piece(heading: curHeading, text: t, line: partStart)) }
                    part = []; n = 0; partStart = curStart + i + 1
                }
            }
            let t = part.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count > 40 { out.append(Piece(heading: curHeading, text: t, line: partStart)) }
        }

        for (i, line) in lines.enumerated() {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if (1...3).contains(level), line.dropFirst(level).first == " " {
                    flush()
                    let h = line.dropFirst(level + 1).trimmingCharacters(in: .whitespaces)
                    if level == 1 { stack = [] }
                    else if level == 2 { stack = [h] }
                    else { stack = Array(stack.prefix(1)) + [h] }
                    curHeading = level == 1 ? h : stack.joined(separator: " › ")
                    curStart = i
                }
            }
            cur.append(line)
        }
        flush()
        return out
    }
}

// MARK: - Cheat sheet

/// The always-on Vanta reference in Vee's system prompt, generated from the
/// book's syntax appendix (chapter 91, nearly verbatim) and builtins appendix
/// (chapter 92, condensed to signatures by section).
enum CheatSheet {
    static func build(syntax: String, builtinsRaw: String) -> String {
        var s = "# VANTA 6.0 REFERENCE (from The Vanta Book, appendices A–B)\n\n"
        if syntax.isEmpty {
            s += fallback
        } else {
            var t = syntax
            if let r = t.range(of: "\n## ") { t = String(t[r.lowerBound...]) }   // drop the chapter intro
            s += t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sigs = builtinSignatures(builtinsRaw)
        if !sigs.isEmpty {
            s += "\n\n## Built-in functions (always available, no import)\n"
            s += "Optional values in [brackets]. Marks: I = interpreter only, N = native canvas programs, K = kernels only.\n"
            s += sigs
        }
        s += "\n\n" + gotchas
        return s
    }

    /// A short version for fast completions: the syntax tables without examples.
    static func compact(syntax: String) -> String {
        guard !syntax.isEmpty else { return fallback }
        var out: [String] = []
        var fence = false
        for l in syntax.components(separatedBy: "\n") {
            if l.hasPrefix("```") { fence.toggle(); continue }
            if fence { continue }
            if l.hasPrefix("| `") {
                let cells = l.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if let f = cells.first { out.append(f) }
            } else if l.hasPrefix("### ") || l.hasPrefix("## ") {
                out.append(l.trimmingCharacters(in: .whitespaces))
            }
        }
        return out.joined(separator: "\n") + "\n" + gotchas
    }

    static func builtinSignatures(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        var out = ""
        var section = ""
        var sigs: [String] = []
        func flush() {
            if !section.isEmpty && !sigs.isEmpty { out += "\(section): " + sigs.joined(separator: " · ") + "\n" }
            sigs = []
        }
        for line in raw.components(separatedBy: "\n") {
            if line.hasPrefix("## ") { flush(); section = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            guard line.hasPrefix("<tr><td>"), let first = line.components(separatedBy: "</td>").first else { continue }
            var sig = MarkdownCleaner.stripTags(first).replacingOccurrences(of: "`", with: "")
            // keep marks (I/N/S/K) compactly
            sig = sig.replacingOccurrences(of: "  ", with: " ")
            if !sig.isEmpty { sigs.append(sig) }
        }
        flush()
        return out
    }

    static let gotchas = """
    ## Writing Vanta in this IDE — must-follow rules
    - Blocks end with `end`; indent 4 spaces. `otherwise if` (never `else`/`elif`). Functions: `to name(a, b)` … `give back x` … `end`.
    - Text interpolation uses `{expr}` inside double quotes. NEVER put double quotes inside the braces ("{m["k"]}" is invalid): bind to a variable first (`let v be m["k"]` then "{v}").
    - Comments start with `#` (or a line starting with `note`). There is no `//`, no semicolons, no `print` (use `say`), no `return` (use `give back`), no `def`/`function`.
    - Tests: `test "name"` … `expect VALUE is EXPECTED` … `end`; run with `vanta test FILE`. `expect CALL fails` checks for an error.
    - Prefer builtins listed above; don't invent functions. If unsure a feature exists, check the book sections provided or say so.
    """

    static let fallback = """
    Output/vars: say "Hi {name}". let x be 5 / change x to 6 / fix K be 9. Comments start with #.
    Values: numbers, "text", yes/no, nothing, [1, 2], {"k": 1}. Math: + - * / mod ^. increase x by 1.
    Compare: is, is not, is over/under, is at least/most. Logic: and or not. x is in list.
    if C … otherwise if C … otherwise … end. match v / when 1 … / otherwise … end.
    repeat N times … end | while C … end | for each x in xs … end | for each k, v in m … end. stop / skip.
    Lists: xs[0], add v to xs, change xs[0] to 9. Maps: m["k"], change m["k"] to v, keys(m).
    to add(a, b) … give back a + b … end. Lambdas: make x give x * 2. map/keep/reduce.
    type Dog / has name / to speak() … me.name … end / end. new Dog("Rex"). type Pup from Dog.
    attempt … rescue e … end. fail("msg"). ask "Q?" into x. test "t" … expect f(1) is 2 … end.
    """
}
