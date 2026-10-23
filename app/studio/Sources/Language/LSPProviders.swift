import Foundation

// The editor-facing providers, all backed by the Vanta language server. Each one
// falls back to the Phase-1 local logic when the server isn't available, so the
// editor never goes quiet.

/// Context-aware completion: members after `.`, module names in `import "…"`, names
/// in scope, keywords, builtins (signature + docs) and block snippets.
final class LSPCompletionProvider: CompletionProvider {
    let id = "vanta-lsp"
    let triggerCharacters: Set<Character> = [".", "\""]
    private let fallback = KeywordCompletionProvider()

    func completions(_ ctx: DocumentContext, prefix: String) async -> [CompletionItem] {
        guard ctx.languageID == LanguageID.vanta.rawValue else { return [] }
        if let f = prefix.first, f.isNumber { return [] }           // typing a number literal
        let svc = LanguageService.shared
        guard svc.state == .ready || svc.state == .starting else { return await fallback.completions(ctx, prefix: prefix) }
        let ns = ctx.text as NSString
        let prev: unichar? = ctx.offset > prefix.utf16.count ? ns.character(at: ctx.offset - prefix.utf16.count - 1) : nil
        // `"` only matters inside import "…"; skip the round trip everywhere else.
        if prefix.isEmpty, prev == 34 {
            let lineStart = ns.lineRange(for: NSRange(location: max(0, ctx.offset - 1), length: 0)).location
            let before = ns.substring(with: NSRange(location: lineStart, length: ctx.offset - lineStart))
            if before.range(of: #"^\s*(import|from)\s+"$"#, options: .regularExpression) == nil { return [] }
        }
        let raw = await svc.completion(ctx)
        if raw.isEmpty && svc.state != .ready { return await fallback.completions(ctx, prefix: prefix) }
        let nextIsParen = ctx.offset < ns.length && ns.character(at: ctx.offset) == 40
        return raw.compactMap { Self.item($0, nextIsParen: nextIsParen) }
    }

    static func item(_ j: [String: Any], nextIsParen: Bool) -> CompletionItem? {
        guard let label = j["label"] as? String else { return nil }
        let k = j["kind"] as? Int ?? 1
        let kind: CompletionKind
        switch k {
        case 2: kind = .method
        case 3: kind = .function
        case 5, 10: kind = .property
        case 6: kind = .variable
        case 7, 13: kind = .type
        case 9: kind = .module
        case 14: kind = .keyword
        case 15: kind = .snippet
        case 17: kind = .file
        case 20, 21: kind = .constant
        default: kind = .text
        }
        var doc: String?
        if let d = j["documentation"] as? [String: Any] { doc = d["value"] as? String } else { doc = j["documentation"] as? String }
        if let d = doc { doc = d.replacingOccurrences(of: "```vanta\n", with: "").replacingOccurrences(of: "```", with: "") }
        var insert: String?
        if let t = j["insertText"] as? String {
            insert = (j["insertTextFormat"] as? Int) == 2 ? snippetToEditor(t) : t
        } else if (kind == .function || kind == .method) && !nextIsParen {
            let detail = j["detail"] as? String ?? ""
            insert = detail.contains("()") ? label + "()$0" : label + "($0)"
        }
        var priority = 0
        if let st = j["sortText"] as? String, let c = st.first, let d = c.wholeNumberValue { priority = 10 - d }
        if kind == .snippet { priority = max(priority, 7) }
        return CompletionItem(label: label, kind: kind, detail: j["detail"] as? String, documentation: doc,
                              insertText: insert, sortPriority: priority)
    }

    /// LSP snippet → the editor's form: placeholders become their text and the caret
    /// ("$0") goes where the first tab stop was.
    static func snippetToEditor(_ s: String) -> String {
        var out = ""
        var caret: (index: Int, rank: Int)?           // rank: tab-stop number (0 is the last)
        let chars = Array(s)
        var i = 0
        func note(_ n: Int) {
            let rank = n == 0 ? Int.max : n
            if caret == nil || rank < caret!.rank { caret = (out.count, rank) }
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count { out.append(chars[i + 1]); i += 2; continue }
            if c == "$", i + 1 < chars.count {
                if chars[i + 1] == "{" {
                    var j = i + 2, num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    if let n = Int(num) {
                        note(n)
                        if j < chars.count, chars[j] == ":" {
                            j += 1
                            var depth = 0
                            while j < chars.count && !(chars[j] == "}" && depth == 0) {
                                if chars[j] == "{" { depth += 1 } else if chars[j] == "}" { depth -= 1 }
                                out.append(chars[j]); j += 1
                            }
                        }
                        while j < chars.count && chars[j] != "}" { j += 1 }
                        i = j + 1
                        continue
                    }
                } else if chars[i + 1].isNumber {
                    var j = i + 1, num = ""
                    while j < chars.count, chars[j].isNumber { num.append(chars[j]); j += 1 }
                    note(Int(num) ?? 0)
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        let at = caret?.index ?? out.count
        let idx = out.index(out.startIndex, offsetBy: at)
        out.insert(contentsOf: "$0", at: idx)
        return out
    }
}

final class LSPHoverProvider: HoverProvider {
    let id = "vanta-lsp"
    func hover(_ ctx: DocumentContext) async -> HoverInfo? {
        guard ctx.languageID == LanguageID.vanta.rawValue, LanguageService.shared.state == .ready else { return nil }
        guard let md = await LanguageService.shared.hover(ctx), !md.isEmpty else { return nil }
        return HoverInfo(markdown: md)
    }
}

final class LSPDefinitionProvider: DefinitionProvider {
    let id = "vanta-lsp"
    func definition(_ ctx: DocumentContext) async -> [Location] {
        guard ctx.languageID == LanguageID.vanta.rawValue, LanguageService.shared.state == .ready else { return [] }
        return await LanguageService.shared.definition(ctx)
    }
}

/// Outline / ⌘⇧O: the server's symbol tree (types with fields and methods, kinds with
/// their values, functions, tests, top-level names); the regex parser as a fallback.
final class LSPSymbolProvider: SymbolProvider {
    let id = "vanta-lsp-symbols"
    func symbols(text: String, uri: URL) async -> [DocumentSymbol] {
        let isVanta = LanguageID.detect(uri.isFileURL ? uri : URL(fileURLWithPath: uri.lastPathComponent)) == .vanta
        if isVanta, LanguageService.shared.state == .ready,
           let s = await LanguageService.shared.documentSymbols(text: text, uri: uri) {
            return s
        }
        return RegexSymbolProvider.parse(text)
    }
}

/// ⌥⇧F: `vanta fmt` through the server (or the CLI when the server is down).
final class VantaFormatter: FormattingProvider {
    let id = "vanta-fmt"
    func format(text: String, uri: URL) async -> String? {
        if LanguageService.shared.state == .ready {
            let out = await LanguageService.shared.format(text: text, uri: uri)
            if out == text { await MainActor.run { Services.shared.flash("Already formatted") } }
            return out == text ? nil : out
        }
        // CLI fallback: format a temp copy
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-fmt-\(UUID().uuidString).va")
        guard (try? text.write(to: tmp, atomically: true, encoding: .utf8)) != nil else { return nil }
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = await VantaRuntime.run(["fmt", tmp.path], cwd: tmp.deletingLastPathComponent(), timeout: 20)
        guard r.code == 0, let out = try? String(contentsOf: tmp, encoding: .utf8) else {
            await MainActor.run { Services.shared.flash("vanta fmt left the file alone (it has a syntax error?)") }
            return nil
        }
        return out == text ? nil : out
    }
}
