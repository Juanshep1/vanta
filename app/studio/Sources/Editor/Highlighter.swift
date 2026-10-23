import AppKit

enum LanguageID: String {
    case vanta, markdown, plain

    static func detect(_ url: URL?) -> LanguageID {
        switch url?.pathExtension.lowercased() ?? "va" {
        case "va", "vanta": return .vanta
        case "md", "markdown": return .markdown
        default: return .plain
        }
    }

    var displayName: String {
        switch self {
        case .vanta: return "Vanta"
        case .markdown: return "Markdown"
        case .plain: return "Plain Text"
        }
    }

    var lineComment: String? { self == .vanta ? "#" : nil }
}

/// Incremental syntax highlighter. Lives on a `Document` and paints its shared
/// NSTextStorage, so every split view of the file is coloured once.
///
/// Only the edited lines are re-lexed; lexing continues past them only while a
/// line's end state (inside a triple-quoted string or not) differs from before.
/// Each token also gets a `Highlighter.tokenKey` attribute (its `TokenKind`) so
/// bracket matching / auto-pairing can tell code from strings and comments.
final class Highlighter {
    static let tokenKey = NSAttributedString.Key("vanta.token")

    let language: LanguageID
    private(set) var lineStates: [UInt8] = []          // end state of each line
    private var table: [[NSAttributedString.Key: Any]] = []
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    private(set) var font: NSFont
    private(set) var paragraph = NSParagraphStyle()
    private var tokens: [Token] = []
    private var buffer: [unichar] = []

    init(language: LanguageID, font: NSFont, lineHeight: CGFloat) {
        self.language = language
        self.font = font
        configure(font: font, lineHeight: lineHeight)
    }

    /// Line metrics shared with the editor so the caret/gutter line up.
    static func lineMetrics(font: NSFont, multiple: CGFloat) -> (height: CGFloat, baselineOffset: CGFloat) {
        let natural = ceil(font.ascender - font.descender + font.leading)
        let h = ceil(natural * max(1, multiple))
        return (h, floor((h - natural) / 2))
    }

    func configure(font: NSFont, lineHeight: CGFloat) {
        self.font = font
        let m = Self.lineMetrics(font: font, multiple: lineHeight)
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = m.height
        p.maximumLineHeight = m.height
        p.lineBreakMode = .byWordWrapping
        // Tab stops every 4 spaces (tabs are rare in Vanta but must align).
        let spaceW = (" " as NSString).size(withAttributes: [.font: font]).width
        p.defaultTabInterval = spaceW * 4
        p.tabStops = []
        paragraph = p
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let bold = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        let boldFont = font.fontName.contains("SFMono") || font.fontName.hasPrefix(".") ? bold
            : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        func attrs(_ color: NSColor, _ f: NSFont? = nil, _ kind: TokenKind) -> [NSAttributedString.Key: Any] {
            [.font: f ?? font, .foregroundColor: color, .paragraphStyle: p,
             .baselineOffset: m.baselineOffset, Self.tokenKey: kind.rawValue]
        }
        baseAttributes = attrs(Theme.nink, nil, .plain)
        var t = [[NSAttributedString.Key: Any]](repeating: baseAttributes, count: 24)
        t[Int(TokenKind.keyword.rawValue)] = attrs(Theme.nkw, nil, .keyword)
        t[Int(TokenKind.decl.rawValue)] = attrs(Theme.ndecl, boldFont, .decl)
        t[Int(TokenKind.opword.rawValue)] = attrs(Theme.nopword, nil, .opword)
        t[Int(TokenKind.constant.rawValue)] = attrs(Theme.nconst, nil, .constant)
        t[Int(TokenKind.pseudo.rawValue)] = attrs(Theme.npseudo, italic, .pseudo)
        t[Int(TokenKind.builtin.rawValue)] = attrs(Theme.nbuiltin, nil, .builtin)
        t[Int(TokenKind.function.rawValue)] = attrs(Theme.nfn, nil, .function)
        t[Int(TokenKind.funcDef.rawValue)] = attrs(Theme.nfnDef, boldFont, .funcDef)
        t[Int(TokenKind.typeName.rawValue)] = attrs(Theme.ntype, nil, .typeName)
        t[Int(TokenKind.typeAnno.rawValue)] = attrs(Theme.ntype, italic, .typeAnno)
        t[Int(TokenKind.number.rawValue)] = attrs(Theme.nnum, nil, .number)
        t[Int(TokenKind.string.rawValue)] = attrs(Theme.nstr, nil, .string)
        t[Int(TokenKind.escape.rawValue)] = attrs(Theme.nescape, nil, .escape)
        t[Int(TokenKind.interp.rawValue)] = attrs(Theme.nescape, nil, .interp)
        t[Int(TokenKind.docString.rawValue)] = attrs(Theme.nstr, nil, .docString)
        t[Int(TokenKind.comment.rawValue)] = attrs(Theme.ncom, italic, .comment)
        t[Int(TokenKind.docComment.rawValue)] = attrs(Theme.ndoc, italic, .docComment)
        t[Int(TokenKind.op.rawValue)] = attrs(Theme.nop, nil, .op)
        t[Int(TokenKind.punct.rawValue)] = attrs(Theme.npunct, nil, .punct)
        t[Int(TokenKind.heading.rawValue)] = attrs(Theme.nheading, boldFont, .heading)
        t[Int(TokenKind.emphasis.rawValue)] = attrs(Theme.nink, boldFont, .emphasis)
        t[Int(TokenKind.code.rawValue)] = attrs(Theme.nstr, nil, .code)
        t[Int(TokenKind.link.rawValue)] = attrs(Theme.nfn, nil, .link)
        table = t
    }

    private func lex(_ p: UnsafeBufferPointer<UInt16>, _ state: UInt8) -> UInt8 {
        tokens.removeAll(keepingCapacity: true)
        switch language {
        case .vanta: return VantaLexer.lexLine(p, state: state, into: &tokens)
        case .markdown: return MarkdownLexer.lexLine(p, state: state, into: &tokens)
        case .plain: return 0
        }
    }

    private func paint(_ storage: NSTextStorage, lineRange: NSRange, contentStart: Int) {
        storage.setAttributes(baseAttributes, range: lineRange)
        for t in tokens where t.kind != .plain && t.length > 0 {
            storage.setAttributes(table[Int(t.kind.rawValue)], range: NSRange(location: contentStart + t.start, length: t.length))
        }
    }

    /// Re-colour the whole document (initial load, font/theme change).
    func highlightAll(_ storage: NSTextStorage, lines: LineIndex) {
        let ns = storage.string as NSString
        let len = ns.length
        lineStates = [UInt8](repeating: 0, count: lines.count)
        storage.beginEditing()
        if len > 0 {
            var all = [unichar](repeating: 0, count: len)
            ns.getCharacters(&all, range: NSRange(location: 0, length: len))
            all.withUnsafeBufferPointer { buf in
                var state: UInt8 = 0
                for l in 0..<lines.count {
                    let r = lines.range(of: l)
                    var contentLen = r.length
                    if contentLen > 0 && buf[r.location + contentLen - 1] == 10 { contentLen -= 1 }
                    let slice = UnsafeBufferPointer(rebasing: buf[r.location..<(r.location + contentLen)])
                    state = lex(slice, state)
                    lineStates[l] = state
                    if r.length > 0 { paint(storage, lineRange: r, contentStart: r.location) }
                }
            }
        }
        storage.endEditing()
    }

    /// Call from `didProcessEditing` after `lines` has been updated.
    /// `first...oldLast` were the affected lines before the edit, `first...newLast` after.
    func didEdit(_ storage: NSTextStorage, lines: LineIndex, first: Int, oldLast: Int, newLast: Int) {
        guard first < lineStates.count || lineStates.isEmpty else { highlightAll(storage, lines: lines); return }
        let oldCount = lineStates.count
        let lo = min(first, oldCount), hi = min(oldLast + 1, oldCount)
        lineStates.replaceSubrange(lo..<hi, with: [UInt8](repeating: 255, count: newLast - first + 1))
        if lineStates.count != lines.count {          // safety net: never desync
            highlightAll(storage, lines: lines); return
        }
        let ns = storage.string as NSString
        var l = first
        while l < lines.count {
            let r = lines.range(of: l)
            var contentLen = r.length
            if contentLen > 0 && ns.character(at: r.location + contentLen - 1) == 10 { contentLen -= 1 }
            if buffer.count < contentLen { buffer = [unichar](repeating: 0, count: max(contentLen, 256)) }
            if contentLen > 0 { ns.getCharacters(&buffer, range: NSRange(location: r.location, length: contentLen)) }
            let start: UInt8 = l == 0 ? 0 : lineStates[l - 1]
            let st = buffer.withUnsafeBufferPointer { lex(UnsafeBufferPointer(rebasing: $0[0..<contentLen]), start) }
            if r.length > 0 { paint(storage, lineRange: r, contentStart: r.location) }
            let previous = lineStates[l]
            lineStates[l] = st
            if l >= newLast && previous == st { break }
            l += 1
        }
    }

    func state(endingLine l: Int) -> UInt8 { l >= 0 && l < lineStates.count ? lineStates[l] : 0 }
}
