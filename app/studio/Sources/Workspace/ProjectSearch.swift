import Foundation
import Combine

/// Workspace-wide find / replace (⌘⇧F). Searches open documents' live text and
/// files on disk, on a background task.
final class ProjectSearch: ObservableObject {
    struct Options: Equatable {
        var query = ""
        var replacement = ""
        var regex = false
        var caseSensitive = false
        var wholeWord = false
        var include = ""
        var exclude = ""
    }

    struct Match: Identifiable, Hashable {
        let id = UUID()
        let line: Int                 // 0-based
        let range: NSRange            // in the whole file text
        let lineText: String          // trimmed preview
        let previewRange: NSRange     // match range within lineText
        let replacement: String?      // what replace-all will put there
    }

    struct FileResult: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        let relativePath: String
        var matches: [Match]
        static func == (a: Self, b: Self) -> Bool { a.url == b.url && a.matches.count == b.matches.count }
        func hash(into h: inout Hasher) { h.combine(url) }
    }

    @Published var options = Options()
    @Published private(set) var results: [FileResult] = []
    @Published private(set) var searching = false
    @Published private(set) var error: String?
    @Published var collapsed: Set<URL> = []
    @Published var showReplace = false

    var matchCount: Int { results.reduce(0) { $0 + $1.matches.count } }

    private var task: Task<Void, Never>?
    private var debounce: AnyCancellable?

    init() {
        debounce = $options
            .removeDuplicates()
            .debounce(for: .milliseconds(220), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.run() }
    }

    func makeRegex(_ o: Options) throws -> NSRegularExpression? {
        guard !o.query.isEmpty else { return nil }
        var pattern = o.regex ? o.query : NSRegularExpression.escapedPattern(for: o.query)
        if o.wholeWord { pattern = "\\b(?:" + pattern + ")\\b" }
        var opts: NSRegularExpression.Options = [.anchorsMatchLines]
        if !o.caseSensitive { opts.insert(.caseInsensitive) }
        return try NSRegularExpression(pattern: pattern, options: opts)
    }

    func run() {
        task?.cancel()
        let o = options
        error = nil
        let re: NSRegularExpression
        do {
            guard let r = try makeRegex(o) else { results = []; searching = false; return }
            re = r
        } catch {
            self.error = "Invalid regular expression"
            results = []
            return
        }
        let ws = Services.shared.workspace
        let files: [URL]
        if ws.root != nil {
            files = ws.fileIndex
        } else {
            files = Services.shared.documents.documents.compactMap(\.url)
        }
        // Live text for open docs (unsaved edits count).
        var live: [URL: String] = [:]
        for d in Services.shared.documents.documents { if let u = d.url { live[u.standardizedFileURL] = d.text } }
        let include = GlobMatcher(o.include), exclude = GlobMatcher(o.exclude)
        let rel: (URL) -> String = { ws.relativePath($0) }
        let relPaths = files.map { ($0, rel($0)) }
        let doReplace = showReplace
        searching = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            var out: [FileResult] = []
            var total = 0
            for (url, relPath) in relPaths {
                if Task.isCancelled { return }
                if !include.isEmpty && !include.matches(relPath) { continue }
                if !exclude.isEmpty && exclude.matches(relPath) { continue }
                let text: String
                if let t = live[url] { text = t } else {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? Int, size < 2_000_000,
                          let data = try? Data(contentsOf: url),
                          !data.prefix(4096).contains(0),                         // skip binaries
                          let s = String(data: data, encoding: .utf8) else { continue }
                    text = s
                }
                let ms = Self.matches(in: text, re: re, replacement: doReplace ? o.replacement : nil, regexMode: o.regex)
                if !ms.isEmpty {
                    out.append(FileResult(url: url, relativePath: relPath, matches: ms))
                    total += ms.count
                    if total > 20_000 { break }
                }
            }
            out.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            let final = out
            await MainActor.run {
                self?.results = final
                self?.searching = false
            }
        }
    }

    static func matches(in text: String, re: NSRegularExpression, replacement: String?, regexMode: Bool) -> [Match] {
        let ns = text as NSString
        var lines = LineIndex()
        var out: [Match] = []
        var built = false
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m, m.range.length > 0 else { return }
            if !built { lines.rebuild(ns); built = true }
            let l = lines.line(at: m.range.location)
            let lr = lines.contentRange(of: l, in: ns)
            var lineText = ns.substring(with: lr)
            var start = m.range.location - lr.location
            // trim leading whitespace and keep previews short
            let lead = lineText.prefix { $0 == " " || $0 == "\t" }.utf16.count
            if lead > 0 && lead <= start { lineText = String(lineText.dropFirst(lineText.prefix { $0 == " " || $0 == "\t" }.count)); start -= lead }
            let lt = lineText as NSString
            var pr = NSRange(location: start, length: min(m.range.length, max(0, lt.length - start)))
            if lt.length > 160 {
                let from = max(0, pr.location - 40)
                let len = min(lt.length - from, 160)
                lineText = lt.substring(with: NSRange(location: from, length: len))
                pr.location -= from
                pr.length = min(pr.length, max(0, len - pr.location))
            }
            var rep: String?
            if let replacement {
                rep = regexMode ? re.replacementString(for: m, in: text, offset: 0, template: replacement) : replacement
            }
            out.append(Match(line: l, range: m.range, lineText: lineText, previewRange: pr, replacement: rep))
            if out.count > 5000 { stop.pointee = true }
        }
        return out
    }

    /// Replace every match (open documents are edited in place and stay undoable;
    /// closed files are rewritten on disk). Returns the number of replacements.
    @discardableResult
    func replaceAll() -> Int {
        let o = options
        guard let re = try? makeRegex(o) else { return 0 }
        var count = 0
        for r in results {
            if let d = Services.shared.documents.document(for: r.url) {
                let text = d.text
                let ms = Self.matches(in: text, re: re, replacement: o.replacement, regexMode: o.regex)
                for m in ms.reversed() { d.replace(m.range, with: m.replacement ?? "") }
                count += ms.count
            } else {
                guard let text = try? String(contentsOf: r.url, encoding: .utf8) else { continue }
                let ns = NSMutableString(string: text)
                let ms = Self.matches(in: text, re: re, replacement: o.replacement, regexMode: o.regex)
                for m in ms.reversed() { ns.replaceCharacters(in: m.range, with: m.replacement ?? "") }
                do { try (ns as String).write(to: r.url, atomically: true, encoding: .utf8); count += ms.count }
                catch { Services.shared.flash("Couldn't write \(r.relativePath)") }
            }
        }
        run()
        return count
    }

    func replace(in file: FileResult) {
        let saved = results
        results = [file]
        replaceAll()
        if results.isEmpty { results = saved.filter { $0.url != file.url } }
    }
}
