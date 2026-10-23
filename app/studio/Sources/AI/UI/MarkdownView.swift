import SwiftUI
import AppKit

// MARK: - Vanta syntax colouring for SwiftUI Text

enum CodeHighlighter {
    static func isVanta(_ lang: String) -> Bool { ["", "va", "vanta"].contains(lang.lowercased()) }

    static func attributed(_ code: String, lang: String) -> AttributedString {
        var out = AttributedString()
        guard isVanta(lang) else {
            var a = AttributedString(code)
            a.foregroundColor = Color(nsColor: Theme.nink)
            return a
        }
        var state: UInt8 = 0
        var tokens: [Token] = []
        let lines = code.components(separatedBy: "\n")
        for (li, line) in lines.enumerated() {
            let units = Array(line.utf16)
            tokens.removeAll(keepingCapacity: true)
            state = units.withUnsafeBufferPointer { VantaLexer.lexLine($0, state: state, into: &tokens) }
            let ns = line as NSString
            var pos = 0
            for t in tokens.sorted(by: { $0.start < $1.start }) where t.length > 0 && t.start >= pos {
                if t.start > pos { out += piece(ns.substring(with: NSRange(location: pos, length: t.start - pos)), .plain) }
                let len = min(t.length, ns.length - t.start)
                if len > 0 { out += piece(ns.substring(with: NSRange(location: t.start, length: len)), t.kind) }
                pos = t.start + max(0, len)
            }
            if pos < ns.length { out += piece(ns.substring(from: pos), .plain) }
            if li < lines.count - 1 { out += AttributedString("\n") }
        }
        return out
    }

    private static func piece(_ s: String, _ k: TokenKind) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = Color(nsColor: color(k))
        if k == .comment || k == .docComment { a.font = .system(size: 12, design: .monospaced).italic() }
        if k == .decl || k == .funcDef { a.font = .system(size: 12, weight: .semibold, design: .monospaced) }
        return a
    }

    static func color(_ k: TokenKind) -> NSColor {
        switch k {
        case .keyword: return Theme.nkw
        case .decl: return Theme.ndecl
        case .opword: return Theme.nopword
        case .constant: return Theme.nconst
        case .pseudo: return Theme.npseudo
        case .builtin: return Theme.nbuiltin
        case .function: return Theme.nfn
        case .funcDef: return Theme.nfnDef
        case .typeName, .typeAnno: return Theme.ntype
        case .number: return Theme.nnum
        case .string, .docString, .code: return Theme.nstr
        case .escape, .interp: return Theme.nescape
        case .comment: return Theme.ncom
        case .docComment: return Theme.ndoc
        case .op: return Theme.nop
        case .punct: return Theme.npunct
        case .heading: return Theme.nheading
        case .link: return Theme.nfn
        default: return Theme.nink
        }
    }
}

// MARK: - Block markdown

enum MDBlock: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case list([MDListItem])
    case code(lang: String, code: String, fileHint: String?, closed: Bool)
    case quote(String)
    case rule
    case table([[String]])
}

struct MDListItem: Hashable { let indent: Int; let marker: String; let text: String }

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var para: [String] = []
        var list: [MDListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        var fence: (lang: String, lines: [String], hint: String?)?
        var lastProse = ""

        func flushPara() { if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !list.isEmpty { out.append(.list(list)); list = [] } }
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        func flushAll() { flushPara(); flushList(); flushQuote(); flushTable() }

        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if var f = fence {
                if t.hasPrefix("```") {
                    out.append(.code(lang: f.lang, code: f.lines.joined(separator: "\n"), fileHint: f.hint, closed: true))
                    fence = nil
                } else { f.lines.append(raw); fence = f }
                continue
            }
            if t.hasPrefix("```") {
                flushAll()
                let info = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                let lang = info.split(whereSeparator: { $0 == " " || $0 == ":" }).first.map(String.init) ?? ""
                fence = (lang, [], MarkdownBlocks.fileName(in: info) ?? MarkdownBlocks.fileName(in: lastProse))
                continue
            }
            if t.isEmpty { flushAll(); continue }
            lastProse = t
            if t.hasPrefix("#"), let sp = t.firstIndex(of: " "), t[..<sp].allSatisfy({ $0 == "#" }) {
                flushAll()
                out.append(.heading(t.distance(from: t.startIndex, to: sp), String(t[t.index(after: sp)...])))
                continue
            }
            if t == "---" || t == "***" || t == "___" { flushAll(); out.append(.rule); continue }
            if t.hasPrefix("|") && t.hasSuffix("|") {
                flushPara(); flushList(); flushQuote()
                let cells = t.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            if t.hasPrefix(">") { flushPara(); flushList(); flushTable(); quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)); continue }
            let indent = raw.prefix { $0 == " " }.count / 2
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                flushPara(); flushQuote(); flushTable()
                list.append(MDListItem(indent: indent, marker: "•", text: String(t.dropFirst(2))))
                continue
            }
            if let dot = t.firstIndex(of: "."), t[..<dot].allSatisfy(\.isNumber), !t[..<dot].isEmpty,
               t.index(after: dot) < t.endIndex, t[t.index(after: dot)] == " " {
                flushPara(); flushQuote(); flushTable()
                list.append(MDListItem(indent: indent, marker: String(t[...dot]), text: String(t[t.index(dot, offsetBy: 2)...])))
                continue
            }
            if !list.isEmpty && raw.hasPrefix("  ") {
                let last = list.removeLast()
                list.append(MDListItem(indent: last.indent, marker: last.marker, text: last.text + " " + t))
                continue
            }
            flushList(); flushQuote(); flushTable()
            para.append(t)
        }
        if let f = fence { flushAll(); out.append(.code(lang: f.lang, code: f.lines.joined(separator: "\n"), fileHint: f.hint, closed: false)) }
        flushAll()
        return out
    }

    static func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return a }
        return AttributedString(s)
    }
}

/// Renders an assistant reply: headings, paragraphs, lists, tables, quotes and
/// highlighted code blocks with Apply / Insert / Copy / New file.
struct MarkdownView: View {
    let text: String
    var codeActions = true
    var fontSize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    func blockView(_ b: MDBlock) -> some View {
        switch b {
        case let .heading(level, t):
            Text(MarkdownParser.inline(t))
                .font(.system(size: level <= 1 ? fontSize + 4 : level == 2 ? fontSize + 2 : fontSize + 1, weight: .bold))
                .padding(.top, 2)
        case let .paragraph(t):
            Text(MarkdownParser.inline(t)).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case let .list(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.marker).font(.system(size: fontSize, weight: .semibold)).foregroundColor(Theme.accent)
                            .frame(minWidth: 10, alignment: .trailing)
                        Text(MarkdownParser.inline(it.text)).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, CGFloat(it.indent) * 14)
                }
            }
        case let .code(lang, code, hint, closed):
            CodeBlockView(code: code, lang: lang, fileHint: hint, streaming: !closed, showActions: codeActions)
        case let .quote(t):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                Text(MarkdownParser.inline(t)).font(.system(size: fontSize)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1)
        case let .table(rows):
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        HStack(spacing: 0) {
                            ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                                Text(MarkdownParser.inline(c)).font(.system(size: fontSize - 1, weight: i == 0 ? .semibold : .regular))
                                    .frame(minWidth: 70, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 3)
                            }
                        }
                        .background(i == 0 ? Theme.panel2.opacity(0.6) : .clear)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            }
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let lang: String
    let fileHint: String?
    var streaming = false
    var showActions = true
    @ObservedObject var vee = VeeAssistant.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(fileHint ?? (lang.isEmpty ? "vanta" : lang)).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                Spacer()
                if showActions && !streaming {
                    if CodeHighlighter.isVanta(lang) {
                        action("Apply", "checkmark", help: "Merge into \(fileHint ?? "the current file") and review as an inline diff") {
                            vee.applyBlock(code, fileHint: fileHint)
                        }
                        action("Insert", "text.insert", help: "Insert at the cursor") { vee.insertBlock(code) }
                    }
                    action(copied ? "Copied" : "Copy", copied ? "checkmark.circle" : "doc.on.doc", help: "Copy to the clipboard") {
                        vee.copyBlock(code); copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    if CodeHighlighter.isVanta(lang) {
                        action("New file", "doc.badge.plus", help: "Open in a new editor tab") { vee.newFile(code, nameHint: fileHint) }
                    }
                } else if streaming {
                    ProgressView().controlSize(.mini)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Theme.panel2.opacity(0.55))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.attributed(code, lang: lang))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editorBg))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    func action(_ title: String, _ icon: String, help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(title == "Apply" ? Theme.accentDim : Theme.panel))
            .foregroundColor(title == "Apply" ? .white : Theme.ink)
        }
        .buttonStyle(.plain).help(help)
    }
}
