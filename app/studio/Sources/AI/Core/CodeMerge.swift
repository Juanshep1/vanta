import Foundation

/// Fenced code blocks in a markdown reply, with the file name mentioned just
/// before each block (`calc.va:` / **calc.va** / `src/calc.va`).
enum MarkdownBlocks {
    struct Block: Hashable { let lang: String; let code: String; let fileHint: String? }

    static func codeBlocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var inFence = false
        var lang = ""
        var buf: [String] = []
        var lastProse = ""
        var hint: String?
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if inFence {
                    out.append(Block(lang: lang, code: buf.joined(separator: "\n"), fileHint: hint))
                    buf = []; inFence = false
                } else {
                    inFence = true
                    lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    // ```vanta title="calc.va" / ```vanta:calc.va
                    hint = fileName(in: lang) ?? fileName(in: lastProse)
                    lang = lang.split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init) ?? ""
                }
                continue
            }
            if inFence { buf.append(line) } else if !t.isEmpty { lastProse = t }
        }
        if inFence && !buf.isEmpty { out.append(Block(lang: lang, code: buf.joined(separator: "\n"), fileHint: hint)) }
        return out
    }

    static func fileName(in s: String) -> String? {
        guard let r = s.range(of: #"[A-Za-z0-9_\-./]+\.(va|vanta)\b"#, options: .regularExpression) else { return nil }
        return String(s[r])
    }
}

/// Local, deterministic merging of a code snippet into a file — used by Apply
/// before falling back to an AI merge.
enum CodeMerge {
    struct Decl { let kind: String; let name: String; let start: Int; let end: Int }   // line range, end inclusive

    static func merge(snippet: String, into file: String) -> String? {
        let sn = snippet.trimmingCharacters(in: .newlines)
        if file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sn + "\n" }
        let fileLines = file.components(separatedBy: "\n")
        let snLines = sn.components(separatedBy: "\n")
        if looksLikeWholeFile(snLines, fileLines) { return sn + (file.hasSuffix("\n") ? "\n" : "") }
        let snDecls = decls(snLines)
        guard !snDecls.isEmpty else { return nil }
        // every non-blank, non-comment line of the snippet must belong to a declaration
        var covered = Set<Int>()
        for d in snDecls { covered.formUnion(d.start...d.end) }
        for (i, l) in snLines.enumerated() where !covered.contains(i) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty && !t.hasPrefix("#") && t != "..." && !t.hasPrefix("# ...") { return nil }
        }
        var lines = fileLines
        let fileDecls = decls(fileLines)
        var appended: [String] = []
        // replace from the bottom so earlier ranges stay valid
        var replacements: [(Decl, [String])] = []
        for d in snDecls {
            let body = Array(snLines[d.start...d.end])
            if let f = fileDecls.first(where: { $0.kind == d.kind && $0.name == d.name }) { replacements.append((f, body)) }
            else { appended += [""] + body }
        }
        for (f, body) in replacements.sorted(by: { $0.0.start > $1.0.start }) { lines.replaceSubrange(f.start...f.end, with: body) }
        if !appended.isEmpty {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines += appended + [""]
        }
        return lines.joined(separator: "\n")
    }

    static func looksLikeWholeFile(_ sn: [String], _ file: [String]) -> Bool {
        let fileSet = Set(file.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        guard !fileSet.isEmpty else { return true }
        let snSet = Set(sn.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let shared = Double(fileSet.intersection(snSet).count) / Double(fileSet.count)
        let fd = decls(file)
        let fileDeclNames = Set(fd.map { $0.kind + $0.name })
        let snDeclNames = Set(decls(sn).map { $0.kind + $0.name })
        // lines of the file outside any declaration (top-level statements)
        var inDecl = Set<Int>()
        for d in fd { inDecl.formUnion(d.start...d.end) }
        let loose = Set(file.enumerated().filter { !inDecl.contains($0.offset) }.map { $0.element.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
        let looseKept = loose.isEmpty ? 1 : Double(loose.intersection(snSet).count) / Double(loose.count)
        if !fileDeclNames.isEmpty && fileDeclNames.isSubset(of: snDeclNames) && looseKept >= 0.7 { return true }
        return shared >= 0.7 && looseKept >= 0.7 && Double(sn.count) >= Double(file.count) * 0.6
    }

    static func decls(_ lines: [String]) -> [Decl] {
        var out: [Decl] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            let ns = l as NSString
            if let m = CodebaseIndex.declRegex.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)),
               ns.substring(with: m.range(at: 1)).isEmpty {
                let kw = ns.substring(with: m.range(at: 2))
                let name = ns.substring(with: m.range(at: 3))
                if ["to", "type", "test"].contains(kw) || (kw == "kind" && !l.contains(" is ")) {
                    var j = i + 1
                    while j < lines.count && !(lines[j].hasPrefix("end") && (lines[j].count == 3 || lines[j].dropFirst(3).allSatisfy { $0 == " " || $0 == "#" })) { j += 1 }
                    if j < lines.count {
                        // include doc comments directly above
                        var s = i
                        while s > 0 && lines[s - 1].hasPrefix("##") { s -= 1 }
                        out.append(Decl(kind: kw, name: name, start: s, end: j))
                        i = j + 1
                        continue
                    }
                }
            }
            i += 1
        }
        return out
    }

    static func stripFences(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = stripBetween(t, "<think>", "</think>")
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) } else { t = "" }
            if let close = t.range(of: "```", options: .backwards) { t = String(t[..<close.lowerBound]) }
        }
        return t.trimmingCharacters(in: .newlines)
    }

    static func stripBetween(_ text: String, _ open: String, _ close: String) -> String {
        var t = text
        while let o = t.range(of: open) {
            if let c = t.range(of: close, range: o.upperBound..<t.endIndex) { t.removeSubrange(o.lowerBound..<c.upperBound) }
            else { t.removeSubrange(o.lowerBound..<t.endIndex) }
        }
        return t
    }
}
