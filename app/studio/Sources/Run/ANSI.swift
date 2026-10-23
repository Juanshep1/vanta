import AppKit

/// Text style carried by SGR escape codes.
struct ANSIStyle: Equatable {
    enum Colour: Equatable { case none, palette(Int), rgb(UInt8, UInt8, UInt8) }
    var fg: Colour = .none
    var bg: Colour = .none
    var bold = false, dim = false, italic = false, underline = false, inverse = false, strike = false

    var isPlain: Bool { self == ANSIStyle() }
}

/// Incremental parser for program output: SGR colours (16 / 256 / truecolor),
/// bold/dim/italic/underline/inverse/strike; other CSI and OSC sequences are
/// dropped. Escape sequences split across chunks are carried over. `\r` that
/// isn't part of `\r\n` is reported so the console can rewrite the line
/// (progress bars).
struct ANSIParser {
    enum Piece: Equatable {
        case text(String, ANSIStyle)
        case carriageReturn
    }

    private(set) var style = ANSIStyle()
    private var carry = ""          // an unfinished escape sequence from the previous chunk
    private var pendingCR = false

    mutating func reset() { style = ANSIStyle(); carry = ""; pendingCR = false }

    mutating func feed(_ chunk: String) -> [Piece] {
        var out: [Piece] = []
        var text = ""
        func flush() { if !text.isEmpty { out.append(.text(text, style)); text = "" } }
        let scalars = Array((carry + chunk).unicodeScalars)
        carry = ""
        var i = 0
        let n = scalars.count
        while i < n {
            let c = scalars[i]
            if pendingCR {
                pendingCR = false
                if c != "\n" { flush(); out.append(.carriageReturn) }
            }
            if c == "\u{1B}" {
                guard i + 1 < n else { carry = String(String.UnicodeScalarView(scalars[i...])); break }
                let k = scalars[i + 1]
                if k == "[" {
                    // CSI: params then a final byte 0x40–0x7E
                    var j = i + 2
                    while j < n, !(0x40...0x7E).contains(scalars[j].value) { j += 1 }
                    guard j < n else { carry = String(String.UnicodeScalarView(scalars[i...])); break }
                    if scalars[j] == "m" {
                        flush()
                        let params = String(String.UnicodeScalarView(scalars[(i + 2)..<j]))
                        applySGR(params)
                    } else if scalars[j] == "K" || scalars[j] == "J" {
                        // erase line/screen: ignore (we only append)
                    }
                    i = j + 1
                    continue
                } else if k == "]" {
                    // OSC: until BEL or ESC \
                    var j = i + 2
                    var end = -1
                    while j < n {
                        if scalars[j] == "\u{07}" { end = j + 1; break }
                        if scalars[j] == "\u{1B}", j + 1 < n, scalars[j + 1] == "\\" { end = j + 2; break }
                        j += 1
                    }
                    guard end > 0 else {
                        if n - i < 4096 { carry = String(String.UnicodeScalarView(scalars[i...])) }
                        break
                    }
                    i = end
                    continue
                } else if k == "(" || k == ")" {
                    i = min(n, i + 3); continue          // charset designation
                } else {
                    i += 2; continue                       // ESC 7, ESC 8, ESC = …
                }
            }
            if c == "\r" {
                if i + 1 < n { if scalars[i + 1] != "\n" { flush(); out.append(.carriageReturn) } }
                else { pendingCR = true }
                i += 1
                continue
            }
            if c == "\u{08}" {                              // backspace
                if !text.isEmpty { text.removeLast() }
                i += 1; continue
            }
            if c.value < 0x20 && c != "\n" && c != "\t" { i += 1; continue }
            text.unicodeScalars.append(c)
            i += 1
        }
        flush()
        return out
    }

    /// Strip escape sequences entirely (for the plain-text mirror).
    static func strip(_ s: String) -> String {
        var p = ANSIParser()
        var out = ""
        for piece in p.feed(s) { if case .text(let t, _) = piece { out += t } }
        return out
    }

    private mutating func applySGR(_ params: String) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var i = 0
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: style = ANSIStyle()
            case 1: style.bold = true
            case 2: style.dim = true
            case 3: style.italic = true
            case 4: style.underline = true
            case 7: style.inverse = true
            case 9: style.strike = true
            case 21, 22: style.bold = false; style.dim = false
            case 23: style.italic = false
            case 24: style.underline = false
            case 27: style.inverse = false
            case 29: style.strike = false
            case 30...37: style.fg = .palette(c - 30)
            case 39: style.fg = .none
            case 40...47: style.bg = .palette(c - 40)
            case 49: style.bg = .none
            case 90...97: style.fg = .palette(c - 90 + 8)
            case 100...107: style.bg = .palette(c - 100 + 8)
            case 38, 48:
                var colour: ANSIStyle.Colour?
                if i + 2 < codes.count, codes[i + 1] == 5 {
                    colour = .palette(max(0, min(255, codes[i + 2]))); i += 2
                } else if i + 4 < codes.count, codes[i + 1] == 2 {
                    colour = .rgb(UInt8(clamping: codes[i + 2]), UInt8(clamping: codes[i + 3]), UInt8(clamping: codes[i + 4])); i += 4
                }
                if let colour { if c == 38 { style.fg = colour } else { style.bg = colour } }
            default: break
            }
            i += 1
        }
    }
}

/// Maps ANSI colours onto the Vanta palette (dark/light aware).
enum ANSIColours {
    // black red green yellow blue magenta cyan white, then the bright set
    static let dark: [UInt32] = [0x2a2340, 0xe5486b, 0x19b38a, 0xffb547, 0x6fa8ff, 0xb48cff, 0x4fd1c5, 0xd8d3ea,
                                 0x605a7d, 0xff7a93, 0x4fd1a5, 0xffcf7a, 0x9cc0ff, 0xc3abff, 0x7ae6dc, 0xffffff]
    static let light: [UInt32] = [0x1d1730, 0xc3304f, 0x0f8f6c, 0xa3600a, 0x2f63d0, 0x7a4fe8, 0x0f7f8a, 0x8a85a8,
                                  0x6e6890, 0xd23a5a, 0x0f9f78, 0xb7740a, 0x1f4fc0, 0x6d3df5, 0x138f99, 0x3a3258]

    static func colour(_ c: ANSIStyle.Colour) -> NSColor? {
        switch c {
        case .none: return nil
        case .rgb(let r, let g, let b): return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .palette(let i):
            if i < 16 { return Theme.dyn(dark[i], light[i]) }
            if i < 232 {
                let v = i - 16
                let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return NSColor(srgbRed: steps[v / 36] / 255, green: steps[(v / 6) % 6] / 255, blue: steps[v % 6] / 255, alpha: 1)
            }
            let g = CGFloat(8 + (i - 232) * 10) / 255
            return NSColor(srgbRed: g, green: g, blue: g, alpha: 1)
        }
    }

    static func attributes(_ s: ANSIStyle, font: NSFont, base: NSColor) -> [NSAttributedString.Key: Any] {
        var fg = colour(s.fg) ?? base
        var bg = colour(s.bg)
        if s.inverse { let f = fg; fg = bg ?? Theme.nbg; bg = f }
        if s.dim { fg = fg.withAlphaComponent(0.6) }
        var f = font
        if s.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if s.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: fg]
        if let bg { a[.backgroundColor] = bg }
        if s.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }
}
