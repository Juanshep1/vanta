import AppKit
import Combine

/// An open file (or untitled buffer). Owns the single NSTextStorage that every
/// editor pane showing this file shares (so split views stay in sync), the undo
/// stack, the line index and the syntax highlighter.
final class Document: NSObject, ObservableObject, Identifiable, NSTextStorageDelegate {
    let id = UUID()
    @Published private(set) var url: URL?
    @Published private(set) var name: String
    @Published private(set) var isDirty = false
    /// The file changed on disk while we had unsaved edits.
    @Published var hasExternalChange = false
    @Published private(set) var language: LanguageID
    var isReadOnly = false

    let storage = NSTextStorage()
    let undoManager = UndoManager()
    private(set) var lines = LineIndex()
    private(set) var highlighter: Highlighter
    private(set) var version = 0
    /// Blocks (`to…end` etc.), recomputed lazily after edits.
    private var blocksCache: [CodeBlock]?
    private var savedText: String = ""
    private var fileModDate: Date?
    /// Set while we replace text programmatically from disk (doesn't dirty the doc).
    private var loading = false

    let changes = PassthroughSubject<TextChange, Never>()

    /// Stable identifier used for diagnostics/breakpoints: the file URL, or
    /// `untitled:<id>/<name>` for unsaved buffers.
    var uri: URL {
        if let url { return url }
        let safe = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "untitled"
        return URL(string: "untitled:\(id.uuidString)/\(safe)") ?? URL(fileURLWithPath: "/untitled/\(id.uuidString)")
    }

    var text: String { storage.string }

    init(url: URL?, name: String? = nil, text: String) {
        self.url = url
        self.name = name ?? url?.lastPathComponent ?? "untitled.va"
        let lang = LanguageID.detect(url ?? URL(fileURLWithPath: name ?? "untitled.va"))
        self.language = lang
        let s = StudioSettings.shared
        highlighter = Highlighter(language: lang, font: s.editorFont, lineHeight: CGFloat(s.prefs.lineHeight))
        super.init()
        storage.delegate = self
        loadText(text)
        savedText = text
        if let url { fileModDate = Self.modDate(url) }
    }

    static func load(_ url: URL) -> Document? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return Document(url: url, text: text)
    }

    private func loadText(_ text: String) {
        loading = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        lines.rebuild(storage.string as NSString)
        highlighter.highlightAll(storage, lines: lines)
        blocksCache = nil
        loading = false
    }

    /// Re-apply fonts/colours (font or line-height setting changed).
    func restyle() {
        let s = StudioSettings.shared
        highlighter.configure(font: s.editorFont, lineHeight: CGFloat(s.prefs.lineHeight))
        highlighter.highlightAll(storage, lines: lines)
    }

    // MARK: NSTextStorageDelegate — incremental line index + highlighting

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !loading else { return }
        let ns = textStorage.string as NSString
        let oldEnd = editedRange.location + editedRange.length - delta
        let first = lines.line(at: editedRange.location)
        let oldLast = lines.line(at: max(editedRange.location, oldEnd))
        let oldLineCount = lines.count
        lines.apply(editedRange: editedRange, delta: delta, in: ns)
        let newLast = lines.line(at: NSMaxRange(editedRange))
        highlighter.didEdit(textStorage, lines: lines, first: first, oldLast: oldLast, newLast: newLast)
        blocksCache = nil
        version += 1

        let lineDelta = lines.count - oldLineCount
        if lineDelta != 0 { BreakpointStore.shared.shift(uri: uri, afterLine: first, by: lineDelta) }

        let change = TextChange(uri: uri, range: editedRange, delta: delta, version: version)
        // Publish after the storage finishes processing (layout may not be ready yet).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.changes.send(change)
            self.updateDirty()
        }
    }

    private func updateDirty() {
        let dirty = storage.length != (savedText as NSString).length || storage.string != savedText
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: structure

    var blocks: [CodeBlock] {
        if let b = blocksCache { return b }
        guard language == .vanta else { blocksCache = []; return [] }
        let hl = highlighter
        let b = BlockStructure.analyze(storage.string as NSString, lines: lines) { l in l > 0 && hl.state(endingLine: l - 1) == 1 }
        blocksCache = b
        return b
    }

    func token(at offset: Int) -> TokenKind {
        guard offset >= 0, offset < storage.length,
              let raw = storage.attribute(Highlighter.tokenKey, at: offset, effectiveRange: nil) as? UInt8 else { return .plain }
        return TokenKind(rawValue: raw) ?? .plain
    }

    // MARK: saving / loading

    static func modDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    @discardableResult
    func save() -> Bool {
        guard let url else { return false }
        return write(to: url)
    }

    @discardableResult
    func saveAs(_ newURL: URL) -> Bool {
        guard write(to: newURL) else { return false }
        url = newURL
        name = newURL.lastPathComponent
        let lang = LanguageID.detect(newURL)
        if lang != language {
            language = lang
            let s = StudioSettings.shared
            highlighter = Highlighter(language: lang, font: s.editorFont, lineHeight: CGFloat(s.prefs.lineHeight))
            highlighter.highlightAll(storage, lines: lines)
        }
        return true
    }

    private func write(to url: URL) -> Bool {
        if StudioSettings.shared.prefs.trimTrailingWhitespace { trimTrailingWhitespace() }
        let text = storage.string
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Services.shared.flash("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        savedText = text
        isDirty = false
        hasExternalChange = false
        fileModDate = Self.modDate(url)
        return true
    }

    private func trimTrailingWhitespace() {
        let ns = storage.string as NSString
        guard let re = try? NSRegularExpression(pattern: "[ \\t]+$", options: [.anchorsMatchLines]) else { return }
        let matches = re.matches(in: storage.string, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return }
        storage.beginEditing()
        for m in matches.reversed() { storage.replaceCharacters(in: m.range, with: "") }
        storage.endEditing()
    }

    /// Was the file modified on disk since we loaded/saved it?
    var changedOnDisk: Bool {
        guard let url, let d = Self.modDate(url) else { return false }
        guard let mine = fileModDate else { return true }
        return d.timeIntervalSince(mine) > 0.0001
    }

    var existsOnDisk: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    /// Reload from disk. Keeps unchanged lines in place (minimal edit) so the
    /// scroll position and folds survive, and registers as one undoable step.
    func reloadFromDisk() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        applyMinimalEdit(to: text, undoable: true)
        savedText = text
        isDirty = false
        hasExternalChange = false
        fileModDate = Self.modDate(url)
    }

    /// The file was renamed/moved on disk (by our explorer).
    func didMove(to newURL: URL) {
        url = newURL
        name = newURL.lastPathComponent
    }

    /// Replace only the span that differs between the current text and `newText`.
    func applyMinimalEdit(to newText: String, undoable: Bool) {
        let oldNS = storage.string as NSString
        let newNS = newText as NSString
        let oldLen = oldNS.length, newLen = newNS.length
        var p = 0
        let maxP = min(oldLen, newLen)
        while p < maxP && oldNS.character(at: p) == newNS.character(at: p) { p += 1 }
        var s = 0
        let maxS = min(oldLen, newLen) - p
        while s < maxS && oldNS.character(at: oldLen - 1 - s) == newNS.character(at: newLen - 1 - s) { s += 1 }
        func isLow(_ u: unichar) -> Bool { u >= 0xDC00 && u <= 0xDFFF }
        if p > 0, p < oldLen, isLow(oldNS.character(at: p)) { p -= 1 }
        if s > 0, oldLen - s < oldLen, isLow(oldNS.character(at: oldLen - s)) { s -= 1 }
        let range = NSRange(location: p, length: oldLen - p - s)
        let replacement = newNS.substring(with: NSRange(location: p, length: newLen - p - s))
        if range.length == 0 && replacement.isEmpty { return }
        replace(range, with: replacement, undoable: undoable)
    }

    /// Low-level undoable replace on the shared storage (no text view needed).
    func replace(_ range: NSRange, with text: String, undoable: Bool = true) {
        let old = (storage.string as NSString).substring(with: range)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: text)
        storage.endEditing()
        if undoable {
            let newRange = NSRange(location: range.location, length: (text as NSString).length)
            undoManager.registerUndo(withTarget: self) { doc in doc.replace(newRange, with: old, undoable: true) }
        }
    }
}
