import AppKit

/// The Console's styled text. One `NSTextStorage` lives here for the whole app
/// session; the Console panel's text view attaches to it whenever it's shown, so
/// output keeps flowing while the panel is hidden. ANSI colours are rendered,
/// `\r` rewrites the current line, and `file.va:12` / `file.va line 12` /
/// Python `File "…", line 12` become clickable links.
final class ConsoleBuffer {
    let storage = NSTextStorage()
    private var parser = ANSIParser()
    /// Folder relative paths in tracebacks are resolved against (the run's cwd).
    var baseDirectory: URL?
    weak var textView: NSTextView?
    /// Keep at most this many characters (old output is dropped from the top).
    var limit = 1_500_000

    static let linkScheme = "vanta-loc"

    var font: NSFont {
        let size = max(10, CGFloat(StudioSettings.shared.prefs.fontSize) - 0.5)
        let name = StudioSettings.shared.prefs.fontName
        if !name.isEmpty, let f = NSFont(name: name, size: size) { return f }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Start of the line being written (for `\r` rewrites).
    private var lineStart = 0

    var string: String { storage.string }
    var isEmpty: Bool { storage.length == 0 }

    func clear() {
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString())
        storage.endEditing()
        parser.reset()
        lineStart = 0
    }

    /// Replace everything with plain text (used when someone sets `console` directly).
    func setPlain(_ text: String) {
        clear()
        append(text)
    }

    /// Append program output. Returns the plain text that was added (for the mirror).
    @discardableResult
    func append(_ chunk: String) -> String {
        let wasAtBottom = isScrolledToBottom
        let pieces = parser.feed(chunk)
        let f = font
        var plain = ""
        let linkStart = (storage.string as NSString).lineRange(for: NSRange(location: storage.length, length: 0)).location
        storage.beginEditing()
        for piece in pieces {
            switch piece {
            case .carriageReturn:
                // overwrite the current line from its start
                let cut = NSRange(location: lineStart, length: storage.length - lineStart)
                if cut.length > 0 { storage.deleteCharacters(in: cut) }
            case .text(let t, let style):
                storage.append(NSAttributedString(string: t, attributes: ANSIColours.attributes(style, font: f, base: Theme.nInk)))
                plain += t
                if let nl = t.lastIndex(of: "\n") {
                    lineStart = storage.length - t[t.index(after: nl)...].utf16.count
                }
            }
        }
        linkify(from: min(linkStart, storage.length))
        trimIfNeeded()
        storage.endEditing()
        if wasAtBottom { scrollToEnd() }
        return plain
    }

    /// A system line (run banner / exit footer) in a given colour.
    func appendNote(_ text: String, colour: NSColor = Theme.nMuted, bold: Bool = false) {
        let wasAtBottom = isScrolledToBottom
        var f = font
        if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        var s = text
        if storage.length > 0 && !storage.string.hasSuffix("\n") { s = "\n" + s }
        storage.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: colour]))
        lineStart = storage.length
        parser.reset()
        if wasAtBottom { scrollToEnd() }
    }

    private func trimIfNeeded() {
        guard storage.length > limit else { return }
        let ns = storage.string as NSString
        let target = storage.length - limit * 2 / 3
        let cut = ns.lineRange(for: NSRange(location: target, length: 0))
        storage.deleteCharacters(in: NSRange(location: 0, length: NSMaxRange(cut)))
        lineStart = max(0, lineStart - NSMaxRange(cut))
    }

    // MARK: links

    private static let patterns: [NSRegularExpression] = [
        // Python: File "/x/y.va", line 12
        try! NSRegularExpression(pattern: #"File "([^"]+)", line (\d+)"#),
        // vanta call stack: shop.va line 7, at the top level
        try! NSRegularExpression(pattern: #"((?:[~/\w.\-]+/)?[\w.\-]+\.va) line (\d+)"#),
        // path.va:12 or path.va:12:5 (also "--> shop.va:3")
        try! NSRegularExpression(pattern: #"((?:[~/\w.\-]+/)?[\w.\-]+\.(?:va|py|c|json)):(\d+)(?::(\d+))?"#),
    ]

    private func linkify(from start: Int) {
        let ns = storage.string as NSString
        let range = NSRange(location: start, length: ns.length - start)
        guard range.length > 0 else { return }
        for re in Self.patterns {
            for m in re.matches(in: storage.string, range: range) {
                if storage.attribute(.link, at: m.range.location, effectiveRange: nil) != nil { continue }
                let path = ns.substring(with: m.range(at: 1))
                guard let line = Int(ns.substring(with: m.range(at: 2))) else { continue }
                var col = 0
                if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound { col = Int(ns.substring(with: m.range(at: 3))) ?? 0 }
                guard let url = resolve(path) else { continue }
                storage.addAttribute(.link, value: Self.link(url, line: line, column: col), range: m.range)
            }
        }
    }

    func resolve(_ path: String) -> URL? {
        let fm = FileManager.default
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return fm.fileExists(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil }
        for base in [baseDirectory, Services.shared.workspace.root].compactMap({ $0 }) {
            let u = base.appendingPathComponent(expanded).standardizedFileURL
            if fm.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func link(_ url: URL, line: Int, column: Int = 0) -> URL {
        var c = URLComponents()
        c.scheme = linkScheme
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "path", value: url.path), URLQueryItem(name: "line", value: "\(line)"),
                        URLQueryItem(name: "col", value: "\(column)")]
        return c.url!
    }

    /// Open a `vanta-loc:` link in the editor (1-based line in the link).
    @discardableResult
    static func open(_ link: Any) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        guard let url, url.scheme == linkScheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value else { return false }
        let line = max(1, Int(items.first { $0.name == "line" }?.value ?? "1") ?? 1)
        let col = max(0, (Int(items.first { $0.name == "col" }?.value ?? "0") ?? 0) - 1)
        let pos = TextPosition(line: line - 1, column: col)
        Services.shared.editors.open(location: Location(uri: URL(fileURLWithPath: path), range: TextRange(start: pos, end: pos)))
        return true
    }

    // MARK: scrolling

    private var isScrolledToBottom: Bool {
        guard let sv = textView?.enclosingScrollView else { return true }
        let visible = sv.contentView.bounds
        return visible.maxY >= (sv.documentView?.bounds.height ?? 0) - 24
    }

    func scrollToEnd() {
        guard let tv = textView else { return }
        tv.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }
}
