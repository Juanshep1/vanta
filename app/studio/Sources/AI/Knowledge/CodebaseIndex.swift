import Foundation
import Combine

/// Workspace context for chat and the agent: a symbol table (functions, types,
/// kinds, tests, top-level lets) plus BM25 over file chunks (top-level Vanta
/// blocks; ~40-line windows for other text files). Rebuilt in the background
/// when the workspace opens and, incrementally per file, when files change.
final class CodebaseIndex: ObservableObject {
    static let shared = CodebaseIndex()

    struct Symbol: Hashable {
        let name: String
        let kind: String         // function | type | kind | test | let
        let signature: String    // the declaration line
        let url: URL
        let line: Int
    }

    @Published private(set) var fileCount = 0
    @Published private(set) var chunkCount = 0
    @Published private(set) var indexing = false

    private var fileChunks: [URL: [KnowledgeChunk]] = [:]
    private var fileSymbols: [URL: [Symbol]] = [:]
    private var chunks: [KnowledgeChunk] = []
    private var index = BM25Index(documents: [])
    private var bag = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "vanta.ai.codebase", qos: .utility)
    private var root: URL?
    private var generation = 0

    static let textExtensions: Set<String> = ["va", "vanta", "md", "txt", "json", "toml", "yml", "yaml", "html", "css",
                                              "js", "py", "csv", "sh"]
    static let maxFileBytes = 256 * 1024
    static let maxFiles = 3000

    func start() {
        let ws = Services.shared.workspace
        ws.$fileIndex
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] files in self?.rebuild(files) }
            .store(in: &bag)
        ws.filesChanged
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] paths in self?.update(paths: paths) }
            .store(in: &bag)
        Services.shared.documents.$documents
            .sink { [weak self] docs in
                guard let self else { return }
                for d in docs { self.watch(d) }
            }
            .store(in: &bag)
    }

    private var watched = Set<UUID>()
    private func watch(_ d: Document) {
        guard !watched.contains(d.id) else { return }
        watched.insert(d.id)
        d.changes
            .debounce(for: .seconds(1.5), scheduler: DispatchQueue.main)
            .sink { [weak self, weak d] _ in
                guard let self, let d, let url = d.url, self.isIndexable(url) else { return }
                self.reindex(url: url, text: d.text)
            }
            .store(in: &bag)
    }

    func isIndexable(_ url: URL) -> Bool {
        guard let root, url.path.hasPrefix(root.path + "/") else { return false }
        return Self.textExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: building

    func rebuild(_ files: [URL]) {
        guard Services.shared.workspace.root != nil else {
            root = nil; fileChunks = [:]; fileSymbols = [:]; finish(); return
        }
        root = Services.shared.workspace.root?.standardizedFileURL
        generation += 1
        let gen = generation
        let list = files.filter { Self.textExtensions.contains($0.pathExtension.lowercased()) }.prefix(Self.maxFiles)
        let live = liveTexts()
        indexing = true
        queue.async { [weak self] in
            var chunks: [URL: [KnowledgeChunk]] = [:]
            var syms: [URL: [Symbol]] = [:]
            for url in list {
                guard let text = live[url] ?? Self.read(url) else { continue }
                let r = Self.analyze(url: url, text: text, root: self?.root)
                chunks[url] = r.chunks; syms[url] = r.symbols
            }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.fileChunks = chunks; self.fileSymbols = syms
                self.finish()
            }
        }
    }

    func update(paths: Set<String>) {
        guard root != nil else { return }
        let live = liveTexts()
        for p in paths {
            let url = URL(fileURLWithPath: p).standardizedFileURL
            guard isIndexable(url) else { continue }
            if let text = live[url] ?? Self.read(url) { reindex(url: url, text: text, publish: false) }
            else { fileChunks[url] = nil; fileSymbols[url] = nil }
        }
        finish()
    }

    func reindex(url: URL, text: String, publish: Bool = true) {
        let r = Self.analyze(url: url, text: text, root: root)
        fileChunks[url] = r.chunks
        fileSymbols[url] = r.symbols
        if publish { finish() }
    }

    private func finish() {
        var all: [KnowledgeChunk] = []
        for url in fileChunks.keys.sorted(by: { $0.path < $1.path }) {
            for c in fileChunks[url] ?? [] {
                all.append(KnowledgeChunk(id: all.count, source: .code, fileURL: c.fileURL, docTitle: c.docTitle,
                                          heading: c.heading, text: c.text, line: c.line))
            }
        }
        chunks = all
        index = BM25Index(documents: all.map { c in
            let path = Tokenizer.tokens(c.docTitle + " " + c.heading)
            return path + path + Tokenizer.tokens(c.text)
        })
        fileCount = fileChunks.count
        chunkCount = all.count
        indexing = false
    }

    private func liveTexts() -> [URL: String] {
        var out: [URL: String] = [:]
        for d in Services.shared.documents.documents { if let u = d.url { out[u.standardizedFileURL] = d.text } }
        return out
    }

    static func read(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: analysis

    static let declRegex = try! NSRegularExpression(
        pattern: #"^(\s*)(to|type|kind|test|let|fix)\s+("[^"]*"|[A-Za-z_][A-Za-z0-9_]*)(.*)$"#)

    static func analyze(url: URL, text: String, root: URL?) -> (chunks: [KnowledgeChunk], symbols: [Symbol]) {
        let rel = root.map { url.path.hasPrefix($0.path + "/") ? String(url.path.dropFirst($0.path.count + 1)) : url.lastPathComponent }
            ?? url.lastPathComponent
        let lines = text.components(separatedBy: "\n")
        var symbols: [Symbol] = []
        var chunks: [KnowledgeChunk] = []
        let isVanta = ["va", "vanta"].contains(url.pathExtension.lowercased())

        func addChunk(_ from: Int, _ to: Int, _ heading: String) {
            let body = lines[from..<min(to, lines.count)].joined(separator: "\n")
            guard body.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 else { return }
            chunks.append(KnowledgeChunk(id: 0, source: .code, fileURL: url, docTitle: rel, heading: heading,
                                         text: body, line: from))
        }

        if isVanta {
            // top-level blocks: a declaration at column 0 through its matching `end`
            var i = 0
            var looseStart: Int?
            while i < lines.count {
                let l = lines[i]
                let ns = l as NSString
                if let m = declRegex.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                    let indent = ns.substring(with: m.range(at: 1))
                    let kw = ns.substring(with: m.range(at: 2))
                    let name = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    let kind = ["to": "function", "type": "type", "kind": "kind", "test": "test", "let": "let", "fix": "let"][kw] ?? kw
                    if indent.count <= 4 && (indent.isEmpty || kind == "function") {
                        symbols.append(Symbol(name: name, kind: kind, signature: l.trimmingCharacters(in: .whitespaces), url: url, line: i))
                    }
                    if indent.isEmpty && (kind == "function" || kind == "type" || kind == "test" || (kind == "kind" && !l.contains(" is "))) {
                        if let s = looseStart { addChunk(s, i, "top level"); looseStart = nil }
                        var j = i + 1
                        while j < lines.count && !(lines[j].hasPrefix("end") && (lines[j].count == 3 || lines[j].dropFirst(3).first == " ")) { j += 1 }
                        addChunk(i, min(j + 1, lines.count), "\(kind) \(name)")
                        i = j + 1
                        continue
                    }
                }
                if looseStart == nil && !l.trimmingCharacters(in: .whitespaces).isEmpty { looseStart = i }
                if let s = looseStart, i - s >= 40 { addChunk(s, i + 1, "top level"); looseStart = nil }
                i += 1
            }
            if let s = looseStart { addChunk(s, lines.count, "top level") }
        } else {
            var s = 0
            while s < lines.count {
                addChunk(s, s + 40, "lines \(s + 1)–\(min(s + 40, lines.count))")
                s += 35
            }
        }
        return (chunks, symbols)
    }

    // MARK: queries

    func search(_ query: String, k: Int = 6) -> [KnowledgeChunk] {
        let q = Tokenizer.tokens(query)
        guard !q.isEmpty else { return [] }
        return index.search(q, k: k).map { chunks[$0.doc] }
    }

    var allSymbols: [Symbol] { fileSymbols.values.flatMap { $0 } }

    func symbols(named names: Set<String>) -> [Symbol] {
        allSymbols.filter { names.contains($0.name) && $0.kind != "let" }
    }

    /// Workspace function/type signatures referenced in `text` (for autocomplete context).
    func relatedSignatures(for text: String, excluding url: URL?, limit: Int = 12) -> [String] {
        var words = Set<String>()
        var cur = ""
        for ch in text { if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { if cur.count > 2 { words.insert(cur) }; cur = "" } }
        if cur.count > 2 { words.insert(cur) }
        return symbols(named: words).filter { $0.url != url }.prefix(limit).map { "\($0.signature)   # \($0.url.lastPathComponent):\($0.line + 1)" }
    }

    /// A compact outline of the workspace (for the agent's first turn).
    func outline(maxLines: Int = 60) -> String {
        guard let root else { return "" }
        var lines: [String] = []
        for url in fileSymbols.keys.sorted(by: { $0.path < $1.path }) {
            let rel = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
            let syms = (fileSymbols[url] ?? []).filter { $0.kind != "let" }.map { $0.kind == "test" ? "test \"\($0.name)\"" : $0.name }
            lines.append(syms.isEmpty ? rel : "\(rel): " + syms.prefix(14).joined(separator: ", "))
            if lines.count >= maxLines { lines.append("…"); break }
        }
        return lines.joined(separator: "\n")
    }
}
