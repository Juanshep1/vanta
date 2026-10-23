import AppKit
import SwiftUI
import Combine

/// One editor view of a document: scroll view + gutter + text view + all
/// decorations. Several panes can show the same `Document` (split editor);
/// they share its text storage, undo stack and highlighting, but each pane has
/// its own layout manager, so selection, scroll position and folds are per pane.
///
/// This is the concrete `EditorController` other modules talk to.
final class EditorPane: NSView, EditorController, NSTextViewDelegate, NSLayoutManagerDelegate {
    let document: Document
    let scrollView = NSScrollView()
    let layoutManager = NSLayoutManager()
    let container: NSTextContainer
    let textView: EditorTextView
    private(set) var gutter: GutterView!

    let find = FindModel()
    let completion = CompletionModel()

    private var findHost: NSHostingView<FindBar>?
    private var completionHost: NSHostingView<CompletionList>?
    private var hoverHost: NSHostingView<HoverCard>?
    private var diffBarHost: NSHostingView<InlineDiffBar>?

    private var bag = Set<AnyCancellable>()
    private let selectionSubject = PassthroughSubject<[NSRange], Never>()
    private(set) var lineHeight: CGFloat = 17
    private var baselineOffset: CGFloat = 0
    private var typicalBaseline: CGFloat?

    override var isFlipped: Bool { true }

    // MARK: init

    init(document: Document) {
        self.document = document
        container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 6
        layoutManager.allowsNonContiguousLayout = true
        layoutManager.addTextContainer(container)
        document.storage.addLayoutManager(layoutManager)
        textView = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        layoutManager.delegate = self
        setupTextView()
        setupScrollView()
        observe()
        applySettings()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Detach from the shared storage. Call when the pane is discarded.
    func close() {
        bag.removeAll()
        NotificationCenter.default.removeObserver(self)
        if layoutManager.textStorage != nil { document.storage.removeLayoutManager(layoutManager) }
    }

    deinit { if layoutManager.textStorage != nil { document.storage.removeLayoutManager(layoutManager) } }

    private func setupTextView() {
        let tv = textView
        tv.pane = self
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.allowsUndo = true
        tv.isEditable = !document.isReadOnly
        tv.drawsBackground = true
        tv.backgroundColor = Theme.nbg
        tv.insertionPointColor = Theme.nAccent
        tv.selectedTextAttributes = [.backgroundColor: Theme.nselection]
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.usesFindBar = false
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.typingAttributes = document.highlighter.baseAttributes
    }

    private func setupScrollView() {
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.nbg
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
        gutter = GutterView(pane: self, scrollView: scrollView)
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    private func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing(_:)),
                                               name: NSTextStorage.didProcessEditingNotification, object: document.storage)
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        document.changes.sink { [weak self] _ in self?.documentDidChange() }.store(in: &bag)
        StudioSettings.shared.$prefs.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySettings() }.store(in: &bag)
        DiagnosticsStore.shared.changed.filter { [weak self] in $0 == self?.document.uri }
            .sink { [weak self] _ in self?.reloadDiagnostics() }.store(in: &bag)
        BreakpointStore.shared.changed.filter { [weak self] in $0 == self?.document.uri }
            .sink { [weak self] _ in self?.gutter.needsDisplay = true }.store(in: &bag)
        Publishers.CombineLatest4(find.$query, find.$regex, find.$caseSensitive, find.$wholeWord)
            .dropFirst()
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeFind(selectFirst: true) }.store(in: &bag)
        reloadDiagnostics()
    }

    func applySettings() {
        let s = StudioSettings.shared
        let font = s.editorFont
        if document.highlighter.font != font || abs(document.highlighter.paragraph.minimumLineHeight
                                                     - Highlighter.lineMetrics(font: font, multiple: CGFloat(s.prefs.lineHeight)).height) > 0.1 {
            document.restyle()
        }
        let m = Highlighter.lineMetrics(font: font, multiple: CGFloat(s.prefs.lineHeight))
        lineHeight = m.height
        baselineOffset = m.baselineOffset
        typicalBaseline = nil
        textView.typingAttributes = document.highlighter.baseAttributes
        configureWrap(s.prefs.wordWrap)
        gutter.updateThickness()
        if let appearance = s.nsAppearance { self.appearance = appearance } else { self.appearance = nil }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    private func configureWrap(_ wrap: Bool) {
        if wrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width, .height]
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: document.storage.length), actualCharacterRange: nil)
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        layoutFindBar()
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { document.undoManager }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        !document.isReadOnly
    }

    // MARK: EditorController — document & selection

    var url: URL? { document.url }
    var text: String { document.storage.string }
    private var ns: NSString { document.storage.string as NSString }

    var selections: [NSRange] {
        get { textView.allRanges }
        set { textView.setAllRanges(newValue) }
    }

    var selectedText: String { ns.substring(with: textView.selectedRange()) }
    var cursorPosition: TextPosition { document.lines.position(of: textView.selectedRange().location) }
    func offset(of position: TextPosition) -> Int { document.lines.offset(of: position) }
    func position(of offset: Int) -> TextPosition { document.lines.position(of: offset) }

    // MARK: editing

    func replace(_ range: NSRange, with text: String) { replace(edits: [(range: range, text: text)]) }

    func replace(edits: [(range: NSRange, text: String)]) {
        let len = ns.length
        let sorted = edits
            .map { (range: NSRange(location: min($0.range.location, len), length: min($0.range.length, len - min($0.range.location, len))), text: $0.text) }
            .sorted { $0.range.location < $1.range.location }
        guard !sorted.isEmpty else { return }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: sorted.map { NSValue(range: $0.range) },
                                        replacementStrings: sorted.map { $0.text }) else {
            // read-only fallback: still apply through the document
            for e in sorted.reversed() { document.replace(e.range, with: e.text) }
            return
        }
        document.storage.beginEditing()
        for e in sorted.reversed() { document.storage.replaceCharacters(in: e.range, with: e.text) }
        document.storage.endEditing()
        textView.didChangeText()
        textView.breakUndoCoalescing()
    }

    func insertAtCursor(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    func setText(_ newText: String) {
        let oldNS = ns, newNS = newText as NSString
        let oldLen = oldNS.length, newLen = newNS.length
        var p = 0
        while p < min(oldLen, newLen) && oldNS.character(at: p) == newNS.character(at: p) { p += 1 }
        var s = 0
        while s < min(oldLen, newLen) - p && oldNS.character(at: oldLen - 1 - s) == newNS.character(at: newLen - 1 - s) { s += 1 }
        let range = NSRange(location: p, length: oldLen - p - s)
        let rep = newNS.substring(with: NSRange(location: p, length: newLen - p - s))
        if range.length == 0 && rep.isEmpty { return }
        replace(range, with: rep)
    }

    // MARK: viewport

    func scrollToLine(_ line: Int, select: Bool) {
        let l = max(0, min(line, document.lines.count - 1))
        let start = document.lines.start(of: l)
        unfoldContaining(start)
        if select {
            textView.extraCarets = []
            textView.setSelectedRange(NSRange(location: start, length: 0))
        }
        centerOn(NSRange(location: start, length: 0))
    }

    func reveal(_ range: NSRange) {
        unfoldContaining(range.location)
        centerOn(range)
    }

    private func centerOn(_ range: NSRange) {
        guard ns.length >= range.location else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(NSMaxRange(range) + 1, ns.length)))
        let caret = caretRect(at: range.location)
        let visible = scrollView.contentView.bounds
        var x = visible.minX
        let gutterW = gutter?.ruleThickness ?? 0
        if caret.minX < visible.minX + 4 || caret.maxX > visible.maxX - 20 {
            x = max(0, caret.minX - max(40, (visible.width - gutterW) / 3))
        }
        var y = visible.minY
        if !(caret.minY >= visible.minY + lineHeight && caret.maxY <= visible.maxY - lineHeight * 2) {
            y = max(0, caret.midY - visible.height / 3)
        }
        if x != visible.minX || y != visible.minY {
            scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    var visibleLines: ClosedRange<Int> {
        var first: Int?, last = 0
        forEachVisibleLine { l, _, _ in if first == nil { first = l }; last = l }
        return (first ?? 0)...max(first ?? 0, last)
    }

    func focus() { textView.window?.makeFirstResponder(textView) }

    // MARK: visible-line enumeration (gutter + decorations)

    /// Calls `body(line, fragmentRect, baselineY)` for each visible, unfolded
    /// line. Rects are in text-view coordinates, height = one line.
    func forEachVisibleLine(_ body: (Int, NSRect, CGFloat) -> Void) {
        let lines = document.lines
        let len = ns.length
        let origin = textView.textContainerOrigin
        let visible = scrollView.contentView.bounds
        let containerRect = visible.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var line = lines.line(at: charRange.location)
        let endChar = NSMaxRange(charRange)
        let font = document.highlighter.font
        while line < lines.count {
            let start = lines.start(of: line)
            if start > endChar + 1 && start < len { break }
            if isHidden(start) { line += 1; continue }
            var frag: NSRect
            if start >= len {
                if len == 0 || ns.character(at: len - 1) == 10 {
                    frag = layoutManager.extraLineFragmentRect
                    if frag.height == 0 {
                        frag = NSRect(x: 0, y: layoutManager.usedRect(for: container).maxY, width: 10, height: lineHeight)
                    }
                } else { break }
            } else {
                let gi = layoutManager.glyphIndexForCharacter(at: start)
                frag = layoutManager.lineFragmentRect(forGlyphAt: gi, effectiveRange: nil)
                // learn the baseline from a line with real text (empty lines report it differently)
                if ns.character(at: start) != 10 && typicalBaseline == nil {
                    typicalBaseline = layoutManager.location(forGlyphAt: gi).y
                }
            }
            var baseline = frag.minY + (typicalBaseline ?? (lineHeight - baselineOffset + font.descender))
            frag.size.height = min(frag.height, lineHeight)
            frag = frag.offsetBy(dx: origin.x, dy: origin.y)
            baseline += origin.y
            if frag.minY > visible.maxY { break }
            if frag.maxY >= visible.minY { body(line, frag, baseline) }
            line += 1
            if start >= len { break }
        }
    }

    /// Line at a y position in text-view coordinates.
    func line(atY y: CGFloat) -> Int? {
        let origin = textView.textContainerOrigin
        let used = layoutManager.usedRect(for: container)
        if y - origin.y > used.maxY {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 && y - origin.y <= extra.maxY + 2 { return document.lines.count - 1 }
            return nil
        }
        var frac: CGFloat = 0
        let gi = layoutManager.glyphIndex(for: NSPoint(x: 1, y: max(0, y - origin.y)), in: container, fractionOfDistanceThroughGlyph: &frac)
        let ci = layoutManager.characterIndexForGlyph(at: gi)
        return document.lines.line(at: ci)
    }

    /// Rect (text-view coords) of a character range on a single line.
    private func rects(for range: NSRange) -> [NSRect] {
        var out: [NSRect] = []
        let gr = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textView.textContainerOrigin
        layoutManager.enumerateEnclosingRects(forGlyphRange: gr, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: container) { r, _ in
            var rr = r.offsetBy(dx: origin.x, dy: origin.y)
            rr.size.height = min(rr.height, self.lineHeight)
            out.append(rr)
        }
        return out
    }

    /// Caret rect (text-view coords) for an insertion point.
    func caretRect(at offset: Int) -> NSRect {
        let origin = textView.textContainerOrigin
        let len = ns.length
        if offset >= len && (len == 0 || ns.character(at: len - 1) == 10) {
            var r = layoutManager.extraLineFragmentRect
            if r.height == 0 { r = NSRect(x: 0, y: layoutManager.usedRect(for: container).maxY, width: 0, height: lineHeight) }
            return NSRect(x: r.minX + container.lineFragmentPadding + origin.x, y: r.minY + origin.y, width: 1, height: lineHeight)
        }
        let o = min(offset, len)
        let gi = layoutManager.glyphIndexForCharacter(at: o)
        let frag = layoutManager.lineFragmentRect(forGlyphAt: min(gi, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil)
        var x: CGFloat
        if o >= len {
            let last = layoutManager.boundingRect(forGlyphRange: NSRange(location: max(0, layoutManager.numberOfGlyphs - 1), length: 1), in: container)
            x = last.maxX
        } else {
            x = frag.minX + layoutManager.location(forGlyphAt: gi).x
        }
        return NSRect(x: x + origin.x, y: frag.minY + origin.y, width: 1, height: lineHeight)
    }

    // MARK: storage edits (synchronous, before layout)

    @objc private func storageDidProcessEditing(_ n: Notification) {
        let st = document.storage
        guard st.editedMask.contains(.editedCharacters) else { return }
        let edited = st.editedRange
        let delta = st.changeInLength
        let oldEnd = edited.location + edited.length - delta
        // folds
        if !folds.isEmpty {
            var keep: [NSRange] = []
            var removed: [NSRange] = []
            for f in folds {
                if oldEnd < f.location { keep.append(NSRange(location: f.location + delta, length: f.length)) }
                else if edited.location > NSMaxRange(f) { keep.append(f) }
                else { removed.append(f) }
            }
            folds = keep
            if !removed.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let all = NSRange(location: 0, length: self.document.storage.length)
                    self.layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
                    self.layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
                    self.textView.needsDisplay = true
                    self.gutter.needsDisplay = true
                }
            }
        }
        // ghost text follows the caret; any edit elsewhere clears it
        if ghostText != nil && !settingGhost { clearGhostDeferred() }
        // inline diff: edits inside the range cancel it; edits before shift it
        if var d = inlineDiff {
            if oldEnd <= d.range.location { d.range.location += delta; inlineDiff = d }
            else if edited.location >= NSMaxRange(d.range) { }
            else if !applyingDiff { DispatchQueue.main.async { [weak self] in self?.rejectInlineDiff() } }
        }
        // debugger line / find matches go stale
        if find.visible { DispatchQueue.main.async { [weak self] in self?.recomputeFind(selectFirst: false) } }
    }

    private func documentDidChange() {
        gutter.updateThickness()
        gutter.needsDisplay = true
        foldableCacheVersion = -1
        scheduleMatchUpdate()
    }

    @objc private func didScroll(_ n: Notification) {
        hideHover()
        if completion.isVisible { positionCompletion() }
        positionDiffBar()
        gutter.needsDisplay = true
    }

    // MARK: selection

    func selectionDidChange() {
        textView.needsDisplay = true
        gutter.needsDisplay = true
        scheduleMatchUpdate()
        let rs = textView.allRanges
        selectionSubject.send(rs)
        if completion.isVisible {
            let caret = textView.selectedRange().location
            if caret < completion.replaceRange.location || caret > completion.replaceRange.location + completion.replaceRange.length + 1 {
                hideCompletion()
            }
        }
        Services.shared.editors.cursorMoved(self)
    }

    func didFocus() { Services.shared.editors.focus(pane: self) }

    func selectLines(_ lines: ClosedRange<Int>) {
        let s = document.lines.start(of: lines.lowerBound)
        let e = NSMaxRange(document.lines.range(of: lines.upperBound))
        textView.extraCarets = []
        textView.setSelectedRange(NSRange(location: s, length: e - s))
        focus()
    }

    // MARK: bracket & block matching

    private var matchWork: DispatchWorkItem?
    private var bracketRanges: [NSRange] = []
    private var blockRanges: [NSRange] = []

    private func scheduleMatchUpdate() {
        matchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.updateMatches() }
        matchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: w)
    }

    private func updateMatches() {
        let sel = textView.selectedRange()
        let oldB = bracketRanges, oldK = blockRanges
        bracketRanges = []
        blockRanges = []
        defer { if oldB != bracketRanges || oldK != blockRanges { textView.needsDisplay = true } }
        guard sel.length == 0, textView.extraCarets.isEmpty else { return }
        let s = ns
        let len = s.length
        // brackets: char before caret, then char at caret
        let opens: [unichar: unichar] = [40: 41, 91: 93, 123: 125]
        let closes: [unichar: unichar] = [41: 40, 93: 91, 125: 123]
        for idx in [sel.location - 1, sel.location] where idx >= 0 && idx < len {
            let ch = s.character(at: idx)
            guard opens[ch] != nil || closes[ch] != nil, !document.token(at: idx).isStringOrComment else { continue }
            if let m = matchBracket(at: idx, ch: ch, opens: opens, closes: closes) {
                bracketRanges = [NSRange(location: idx, length: 1), NSRange(location: m, length: 1)]
                break
            }
        }
        // blocks: caret line is an opener / mid / end
        guard document.language == .vanta else { return }
        let line = document.lines.line(at: sel.location)
        let lr = document.lines.contentRange(of: line, in: s)
        let lineText = s.substring(with: NSRange(location: lr.location, length: min(lr.length, 60)))
        if case .none = BlockStructure.role(of: lineText) { return }
        guard let b = document.blocks.first(where: { $0.start == line || $0.end == line || $0.mids.contains(line) }) else { return }
        for l in [b.start] + b.mids + [b.end] {
            let r = document.lines.contentRange(of: l, in: s)
            let t = s.substring(with: r) as NSString
            var i = 0
            while i < t.length && (t.character(at: i) == 32 || t.character(at: i) == 9) { i += 1 }
            var j = i
            while j < t.length && VantaLexer.isIdent(t.character(at: j)) { j += 1 }
            let w = t.substring(with: NSRange(location: i, length: j - i))
            if w == "private" || w == "shared" {     // highlight the real keyword
                var k = j
                while k < t.length && t.character(at: k) == 32 { k += 1 }
                var e = k
                while e < t.length && VantaLexer.isIdent(t.character(at: e)) { e += 1 }
                i = k; j = e
            }
            if j > i { blockRanges.append(NSRange(location: r.location + i, length: j - i)) }
        }
        if blockRanges.count < 2 { blockRanges = [] }
    }

    private func matchBracket(at idx: Int, ch: unichar, opens: [unichar: unichar], closes: [unichar: unichar]) -> Int? {
        let s = ns
        let len = s.length
        var depth = 0
        if let close = opens[ch] {
            var i = idx + 1
            let limit = min(len, idx + 50_000)
            while i < limit {
                let c = s.character(at: i)
                if (c == ch || c == close) && !document.token(at: i).isStringOrComment {
                    if c == ch { depth += 1 } else if depth == 0 { return i } else { depth -= 1 }
                }
                i += 1
            }
        } else if let open = closes[ch] {
            var i = idx - 1
            let limit = max(0, idx - 50_000)
            while i >= limit {
                let c = s.character(at: i)
                if (c == ch || c == open) && !document.token(at: i).isStringOrComment {
                    if c == ch { depth += 1 } else if depth == 0 { return i } else { depth -= 1 }
                }
                i -= 1
            }
        }
        return nil
    }

    // MARK: folding

    /// Hidden character ranges (from the opener line's newline up to the line before `end`).
    private(set) var folds: [NSRange] = []
    private var foldPlaceholderRects: [(NSRect, NSRange)] = []
    private var foldableCache: Set<Int> = []
    private var foldableCacheVersion = -1

    func isHidden(_ offset: Int) -> Bool {
        for f in folds where offset > f.location && offset <= NSMaxRange(f) { return true }
        return false
    }

    var foldedStartLines: Set<Int> { Set(folds.map { document.lines.line(at: $0.location) }) }

    var foldableStarts: Set<Int> {
        if foldableCacheVersion != document.version {
            foldableCache = Set(document.blocks.filter { $0.end > $0.start + 1 }.map(\.start))
            foldableCacheVersion = document.version
        }
        return foldableCache
    }

    private func foldRange(for b: CodeBlock) -> NSRange? {
        let lines = document.lines
        let startNL = NSMaxRange(lines.contentRange(of: b.start, in: ns))
        let endStart = lines.start(of: b.end)
        let length = endStart - 1 - startNL
        return length > 0 ? NSRange(location: startNL, length: length) : nil
    }

    func toggleFold(atLine line: Int) {
        if let i = folds.firstIndex(where: { document.lines.line(at: $0.location) == line }) {
            let r = folds.remove(at: i)
            invalidateFold(r)
            return
        }
        foldBlock(containing: line, exactStart: true)
    }

    /// Fold the block starting at `line` (or the innermost block containing it).
    func foldBlock(containing line: Int, exactStart: Bool = false) {
        let blocks = document.blocks
        let b = blocks.first { $0.start == line && $0.end > $0.start + 1 }
            ?? (exactStart ? nil : blocks.filter { $0.start <= line && $0.end >= line && $0.end > $0.start + 1 }
                .min { ($0.end - $0.start) < ($1.end - $1.start) })
        guard let b, let r = foldRange(for: b), !folds.contains(r) else { return }
        folds.append(r)
        folds.sort { $0.location < $1.location }
        // keep the caret visible
        let sel = textView.selectedRange()
        if isHidden(sel.location) || (sel.location > r.location && sel.location <= NSMaxRange(r)) {
            textView.setSelectedRange(NSRange(location: r.location, length: 0))
        }
        invalidateFold(r)
    }

    func unfold(atLine line: Int) {
        let hits = folds.filter { document.lines.line(at: $0.location) == line || (NSLocationInRange(document.lines.start(of: line), $0)) }
        guard !hits.isEmpty else { return }
        folds.removeAll { hits.contains($0) }
        hits.forEach(invalidateFold)
    }

    func foldAll() {
        let rs = document.blocks.compactMap(foldRange)
        folds = Array(Set(rs)).sorted { $0.location < $1.location }
        invalidateFold(NSRange(location: 0, length: ns.length))
    }

    func unfoldAll() {
        folds = []
        invalidateFold(NSRange(location: 0, length: ns.length))
    }

    private func unfoldContaining(_ offset: Int) {
        let hits = folds.filter { offset > $0.location && offset <= NSMaxRange($0) }
        guard !hits.isEmpty else { return }
        folds.removeAll { hits.contains($0) }
        hits.forEach(invalidateFold)
    }

    private func invalidateFold(_ r: NSRange) {
        let len = ns.length
        let rr = NSRange(location: max(0, r.location - 1), length: min(len - max(0, r.location - 1), r.length + 2))
        layoutManager.invalidateGlyphs(forCharacterRange: rr, changeInLength: 0, actualCharacterRange: nil)
        layoutManager.invalidateLayout(forCharacterRange: rr, actualCharacterRange: nil)
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    func handleFoldPlaceholderClick(at point: NSPoint) -> Bool {
        guard let hit = foldPlaceholderRects.first(where: { $0.0.insetBy(dx: -2, dy: -2).contains(point) }) else { return false }
        folds.removeAll { $0 == hit.1 }
        invalidateFold(hit.1)
        return true
    }

    // NSLayoutManagerDelegate: hide folded glyphs
    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard !folds.isEmpty, glyphRange.length > 0 else { return 0 }
        let first = charIndexes[0], last = charIndexes[glyphRange.length - 1]
        guard folds.contains(where: { $0.location <= last && NSMaxRange($0) >= first }) else { return 0 }
        let newProps = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: glyphRange.length)
        defer { newProps.deallocate() }
        for i in 0..<glyphRange.length {
            let ci = charIndexes[i]
            newProps[i] = folds.contains(where: { ci >= $0.location && ci < NSMaxRange($0) }) ? .null : props[i]
        }
        layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        if !folds.isEmpty && folds.contains(where: { charIndex >= $0.location && charIndex < NSMaxRange($0) }) {
            return .zeroAdvancement
        }
        return action
    }

    // NSLayoutManagerDelegate: room for multi-line ghost text and inline-diff phantom lines
    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingAfterGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard ghostText != nil || inlineDiff != nil else { return 0 }
        let ci = layoutManager.characterIndexForGlyph(at: glyphIndex)
        let line = document.lines.line(at: ci)
        var extra: CGFloat = 0
        if let g = ghostText, line == ghostLine {
            let n = g.components(separatedBy: "\n").count - 1
            extra += CGFloat(n) * lineHeight
        }
        if let d = inlineDiff, let p = d.phantoms[line] { extra += CGFloat(p.count) * lineHeight }
        return extra
    }

    func layoutManager(_ layoutManager: NSLayoutManager, paragraphSpacingBeforeGlyphAt glyphIndex: Int,
                       withProposedLineFragmentRect rect: NSRect) -> CGFloat {
        guard let d = inlineDiff, !d.before.isEmpty else { return 0 }
        let ci = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return document.lines.line(at: ci) == 0 ? CGFloat(d.before.count) * lineHeight : 0
    }

    // MARK: ghost text

    private(set) var ghostText: String?
    private var ghostOffset = 0
    private var ghostLine = -1
    private var settingGhost = false
    private var ghostWork: DispatchWorkItem?
    private var ghostRequestID = 0

    func setGhostText(_ text: String?, at offset: Int?) {
        let oldLine = ghostLine
        let t = (text?.isEmpty ?? true) ? nil : text
        settingGhost = true
        ghostText = t
        ghostOffset = min(offset ?? textView.selectedRange().location, ns.length)
        ghostLine = t == nil ? -1 : document.lines.line(at: ghostOffset)
        settingGhost = false
        for l in Set([oldLine, ghostLine]) where l >= 0 && l < document.lines.count {
            layoutManager.invalidateLayout(forCharacterRange: document.lines.range(of: l), actualCharacterRange: nil)
        }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    func clearGhostIfNeeded() {
        guard ghostText != nil, !settingGhost else { return }
        clearGhostDeferred()
    }

    private func clearGhostDeferred() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.ghostText != nil else { return }
            if self.textView.selectedRange() == NSRange(location: self.ghostOffset, length: 0) && !self.ghostStale { return }
            self.setGhostText(nil, at: nil)
        }
    }
    private var ghostStale: Bool { ghostOffset > ns.length }

    /// Tab: insert the ghost suggestion. Returns false if there was none.
    func acceptGhost() -> Bool {
        guard let g = ghostText else { return false }
        let at = ghostOffset
        setGhostText(nil, at: nil)
        guard at <= ns.length else { return false }
        textView.insertText(g, replacementRange: NSRange(location: at, length: 0))
        return true
    }

    private func scheduleInlineCompletion() {
        ghostWork?.cancel()
        guard let provider = LanguageRegistry.shared.inlineCompletionProvider, provider.isEnabled,
              !textView.isMulti, textView.selectedRange().length == 0, inlineDiff == nil else { return }
        ghostRequestID += 1
        let id = ghostRequestID
        let w = DispatchWorkItem { [weak self] in
            guard let self, id == self.ghostRequestID else { return }
            let loc = self.textView.selectedRange().location
            let full = self.ns
            guard loc <= full.length else { return }
            // only at end of a line, with some context
            if loc < full.length && full.character(at: loc) != 10 { return }
            let prefix = full.substring(to: loc)
            guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let suffix = full.substring(from: loc)
            let uri = self.document.uri
            Task { [weak self] in
                let s = await provider.inlineCompletion(prefix: prefix, suffix: suffix, uri: uri)
                await MainActor.run {
                    guard let self, id == self.ghostRequestID, self.textView.selectedRange().location == loc,
                          let s, !s.isEmpty, !self.completion.isVisible else { return }
                    self.setGhostText(s, at: loc)
                }
            }
        }
        ghostWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    // MARK: inline diff

    private struct InlineDiffState {
        var range: NSRange
        let newText: String
        var removedLines: Set<Int>
        var phantoms: [Int: [String]]
        var before: [String]
        let added: Int
        let removed: Int
        let onAccept: () -> Void
        let onReject: () -> Void
    }
    private var inlineDiff: InlineDiffState?
    private var applyingDiff = false

    var hasInlineDiff: Bool { inlineDiff != nil }

    func showInlineDiff(range: NSRange, newText: String, onAccept: @escaping () -> Void, onReject: @escaping () -> Void) {
        dismissInlineDiff()
        setGhostText(nil, at: nil)
        let len = ns.length
        let r = NSRange(location: min(range.location, len), length: min(range.length, len - min(range.location, len)))
        unfoldContaining(r.location)
        let original = ns.substring(with: r)
        let startLine = document.lines.line(at: r.location)
        var removed = Set<Int>(), phantoms: [Int: [String]] = [:], before: [String] = []
        var orig = startLine - 1
        var addCount = 0, remCount = 0
        // a trailing newline in both would add a phantom empty line; diff the line content
        let a = original.hasSuffix("\n") ? String(original.dropLast()) : original
        let b = newText.hasSuffix("\n") && original.hasSuffix("\n") ? String(newText.dropLast()) : newText
        for d in LineDiff.diff(a, b) {
            switch d.kind {
            case .same: orig += 1
            case .remove: orig += 1; removed.insert(orig); remCount += 1
            case .add:
                addCount += 1
                if orig < 0 { before.append(d.text) } else { phantoms[orig, default: []].append(d.text) }
            }
        }
        inlineDiff = InlineDiffState(range: r, newText: newText, removedLines: removed, phantoms: phantoms, before: before,
                                     added: addCount, removed: remCount, onAccept: onAccept, onReject: onReject)
        invalidateDiffLines()
        let bar = NSHostingView(rootView: InlineDiffBar(added: addCount, removed: remCount,
                                                        onAccept: { [weak self] in self?.acceptInlineDiff() },
                                                        onReject: { [weak self] in self?.rejectInlineDiff() }))
        bar.setFrameSize(bar.fittingSize)
        textView.addSubview(bar)
        diffBarHost = bar
        positionDiffBar()
        reveal(r)
    }

    private func invalidateDiffLines() {
        guard let d = inlineDiff else { return }
        let lines = document.lines
        let s = lines.line(at: d.range.location)
        let e = lines.line(at: NSMaxRange(d.range))
        let from = lines.start(of: max(0, s - 1))
        let to = NSMaxRange(lines.range(of: min(lines.count - 1, e + 1)))
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: from, length: to - from), actualCharacterRange: nil)
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    private func positionDiffBar() {
        guard let bar = diffBarHost, let d = inlineDiff else { return }
        let size = bar.fittingSize
        let first = caretRect(at: document.lines.start(of: document.lines.line(at: d.range.location)))
        let visible = scrollView.contentView.bounds
        var y = first.minY - size.height - 3
        if y < visible.minY { y = first.minY + 2 }
        bar.frame = NSRect(x: visible.maxX - size.width - 18, y: y, width: size.width, height: size.height)
    }

    func acceptInlineDiff() {
        guard let d = inlineDiff else { return }
        clearDiffVisuals()
        applyingDiff = true
        replace(d.range, with: d.newText)
        applyingDiff = false
        let caret = d.range.location + (d.newText as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret, ns.length), length: 0))
        d.onAccept()
    }

    func rejectInlineDiff() {
        guard let d = inlineDiff else { return }
        clearDiffVisuals()
        d.onReject()
    }

    func dismissInlineDiff() { clearDiffVisuals() }

    private func clearDiffVisuals() {
        guard inlineDiff != nil else { return }
        invalidateDiffLines()
        inlineDiff = nil
        invalidateDiffLinesAll()
        diffBarHost?.removeFromSuperview()
        diffBarHost = nil
    }

    private func invalidateDiffLinesAll() {
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: ns.length), actualCharacterRange: nil)
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    // MARK: debugger line

    private(set) var debugLine: Int?
    func highlightLine(_ line: Int?) {
        debugLine = line
        if let line { scrollToLine(line, select: false) }
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    // MARK: breakpoints

    var breakpoints: Set<Int> {
        get { BreakpointStore.shared.lines(for: document.uri) }
        set { BreakpointStore.shared.set(newValue, for: document.uri) }
    }

    func toggleBreakpoint(_ line: Int) { BreakpointStore.shared.toggle(line, in: document.uri) }

    // MARK: diagnostics

    private(set) var diagnostics: [Diagnostic] = []
    private(set) var diagnosticSeverityByLine: [Int: DiagnosticSeverity] = [:]

    func setDiagnostics(_ diagnostics: [Diagnostic]) {
        DiagnosticsStore.shared.publish(diagnostics, for: document.uri, source: "editor")
    }

    private func reloadDiagnostics() {
        diagnostics = DiagnosticsStore.shared.diagnostics(for: document.uri)
        var m: [Int: DiagnosticSeverity] = [:]
        for d in diagnostics { m[d.range.start.line] = min(m[d.range.start.line] ?? .hint, d.severity) }
        diagnosticSeverityByLine = m
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    private func charRange(of d: Diagnostic) -> NSRange {
        let lines = document.lines
        var s = lines.offset(of: d.range.start)
        var e = lines.offset(of: d.range.end)
        if d.range.start.column == 0 {          // whole-line style: start at the code, not the indent
            while s < e && s < ns.length && (ns.character(at: s) == 32 || ns.character(at: s) == 9) { s += 1 }
        }
        if e <= s {
            // zero-width: underline the word at the start (or one char)
            e = s
            while e < ns.length && VantaLexer.isIdent(ns.character(at: e)) { e += 1 }
            if e == s { e = min(ns.length, s + 1) }
        }
        return NSRange(location: s, length: e - s)
    }

    // MARK: drawing

    func drawUnderlays(in rect: NSRect) {
        let prefs = StudioSettings.shared.prefs
        let width = max(textView.bounds.width, scrollView.contentView.bounds.maxX)
        let sel = textView.selectedRange()
        let caretLine = document.lines.line(at: sel.location)
        let spaceW = (" " as NSString).size(withAttributes: [.font: document.highlighter.font]).width
        let padX = textView.textContainerOrigin.x + container.lineFragmentPadding
        var indentByLine: [(Int, NSRect, Int)] = []

        forEachVisibleLine { line, frag, _ in
            let full = NSRect(x: 0, y: frag.minY, width: width, height: frag.height)
            if let d = inlineDiff, d.removedLines.contains(line) {
                Theme.ndiffRemoved.setFill(); full.fill()
            } else if debugLine == line {
                Theme.ndebugLine.setFill(); full.fill()
            } else if prefs.highlightCurrentLine && line == caretLine && sel.length == 0 && textView.extraCarets.isEmpty {
                Theme.ncurrentLine.setFill(); full.fill()
            }
            if prefs.showIndentGuides && document.language == .vanta {
                let lr = document.lines.contentRange(of: line, in: ns)
                var n = 0, blank = true
                let lim = min(lr.length, 200)
                while n < lim {
                    let c = ns.character(at: lr.location + n)
                    if c == 32 { n += 1 } else if c == 9 { n += prefs.tabSize } else { blank = false; break }
                }
                indentByLine.append((line, frag, blank && n == lr.length ? -1 : n))
            }
        }
        // indent guides (blank lines inherit the smaller neighbour's depth)
        if !indentByLine.isEmpty {
            let tab = max(1, prefs.tabSize)
            Theme.nindentGuide.setFill()
            for (i, item) in indentByLine.enumerated() {
                var n = item.2
                if n < 0 {
                    let prev = indentByLine[..<i].last { $0.2 >= 0 }?.2 ?? 0
                    let next = indentByLine[(i + 1)...].first { $0.2 >= 0 }?.2 ?? 0
                    n = min(prev, next)
                }
                for c in stride(from: 0, to: n, by: tab) {
                    let x = floor(padX + CGFloat(c) * spaceW) + 0.5
                    NSRect(x: x, y: item.1.minY, width: 1, height: item.1.height).fill()
                }
            }
        }
        // find matches
        if find.visible && !find.matches.isEmpty {
            let vis = visibleCharRange()
            let lo = find.matches.firstIndex { NSMaxRange($0) >= vis.location } ?? find.matches.count
            var i = lo
            while i < find.matches.count && find.matches[i].location <= NSMaxRange(vis) {
                (i == find.current ? Theme.nfindCurrent : Theme.nfindMatch).setFill()
                for r in rects(for: find.matches[i]) { NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill() }
                i += 1
            }
        }
        // block keywords (to … end)
        for r in blockRanges {
            for rr in rects(for: r) {
                Theme.nwordHighlight.setFill()
                NSBezierPath(roundedRect: rr.insetBy(dx: -1, dy: 1), xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    func drawOverlays(in rect: NSRect) {
        let font = document.highlighter.font
        // bracket match boxes
        for r in bracketRanges {
            for rr in rects(for: r) {
                Theme.nbracket.setStroke()
                let p = NSBezierPath(roundedRect: rr.insetBy(dx: 0.5, dy: 1.5), xRadius: 2, yRadius: 2)
                p.lineWidth = 1
                p.stroke()
            }
        }
        // diagnostics squiggles
        if !diagnostics.isEmpty {
            let vis = visibleLines
            for d in diagnostics where d.range.start.line <= vis.upperBound && d.range.end.line >= vis.lowerBound {
                DiagnosticIcon.nsColor(d.severity).setStroke()
                for r in rects(for: charRange(of: d)) { squiggle(from: r.minX, to: max(r.maxX, r.minX + 6), y: r.maxY - 2) }
            }
        }
        // fold placeholders
        foldPlaceholderRects = []
        for f in folds {
            let line = document.lines.line(at: f.location)
            let lr = document.lines.contentRange(of: line, in: ns)
            let end = caretRect(at: NSMaxRange(lr))
            guard end.maxY >= rect.minY - lineHeight, end.minY <= rect.maxY + lineHeight else { continue }
            let pill = NSRect(x: end.minX + 6, y: end.minY + 2, width: 30, height: lineHeight - 4)
            Theme.nPanel2.setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: font.pointSize - 1, weight: .bold),
                                                        .foregroundColor: Theme.nMuted]
            let s = "⋯" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: pill.midX - sz.width / 2, y: pill.midY - sz.height / 2), withAttributes: attrs)
            foldPlaceholderRects.append((pill, f))
        }
        // inline diff phantom (added) lines
        if let d = inlineDiff {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.nink]
            let width = max(textView.bounds.width, scrollView.contentView.bounds.maxX)
            let padX = textView.textContainerOrigin.x + container.lineFragmentPadding
            func drawPhantoms(_ lines: [String], startY: CGFloat) {
                for (k, t) in lines.enumerated() {
                    let y = startY + CGFloat(k) * lineHeight
                    Theme.ndiffAdded.setFill()
                    NSRect(x: 0, y: y, width: width, height: lineHeight).fill()
                    (t as NSString).draw(at: NSPoint(x: padX, y: y + textTop), withAttributes: attrs)
                }
            }
            if !d.before.isEmpty {
                let first = caretRect(at: 0)
                drawPhantoms(d.before, startY: first.minY - CGFloat(d.before.count) * lineHeight)
            }
            for (line, texts) in d.phantoms {
                guard line < document.lines.count else { continue }
                let r = caretRect(at: document.lines.start(of: line))
                drawPhantoms(texts, startY: r.minY + lineHeight)
            }
        }
        // ghost text
        if let g = ghostText, ghostOffset <= ns.length {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.nghost,
                                                        .baselineOffset: baselineOffset]
            let caret = caretRect(at: ghostOffset)
            let lines = g.components(separatedBy: "\n")
            let textY = caret.minY + textTop
            (lines[0] as NSString).draw(at: NSPoint(x: caret.minX, y: textY), withAttributes: [.font: font, .foregroundColor: Theme.nghost])
            let padX = textView.textContainerOrigin.x + container.lineFragmentPadding
            for (k, ln) in lines.dropFirst().enumerated() {
                (ln as NSString).draw(at: NSPoint(x: padX, y: textY + CGFloat(k + 1) * lineHeight),
                                      withAttributes: [.font: font, .foregroundColor: Theme.nghost])
            }
            _ = attrs
        }
        // extra carets
        if !textView.extraCarets.isEmpty {
            Theme.nAccent.setFill()
            for c in textView.extraCarets {
                let r = caretRect(at: c)
                NSRect(x: r.minX, y: r.minY + 1, width: 2, height: r.height - 2).fill()
            }
        }
    }

    /// Offset from a line's top to where `NSString.draw(at:)` should start so
    /// drawn text sits on the same baseline as the real text.
    private var textTop: CGFloat {
        let font = document.highlighter.font
        return (typicalBaseline ?? (lineHeight - baselineOffset + font.descender)) - font.ascender
    }

    private func squiggle(from x0: CGFloat, to x1: CGFloat, y: CGFloat) {
        let p = NSBezierPath()
        p.lineWidth = 1
        var x = x0
        p.move(to: NSPoint(x: x, y: y))
        var up = true
        while x < x1 {
            x += 2
            p.line(to: NSPoint(x: min(x, x1), y: up ? y - 1.5 : y + 0.5))
            up.toggle()
        }
        p.stroke()
    }

    private func visibleCharRange() -> NSRange {
        let origin = textView.textContainerOrigin
        let r = scrollView.contentView.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let gr = layoutManager.glyphRange(forBoundingRect: r, in: container)
        return layoutManager.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
    }

    // MARK: typing hooks

    func didType(_ s: String) {
        hideHover()
        if s.isEmpty {                                          // deletion
            if completion.isVisible { triggerCompletion(explicit: false) }
        } else if let ch = s.last, s.count == 1 {
            if ch.isLetter || ch.isNumber || ch == "_" {
                triggerCompletion(explicit: false)
            } else if LanguageRegistry.shared.allTriggerCharacters.contains(ch) {
                triggerCompletion(explicit: true)
            } else {
                hideCompletion()
            }
        } else {
            hideCompletion()
        }
        scheduleInlineCompletion()
    }

    /// The indentation an `end`/`otherwise`/`rescue`/`when` line should have.
    func expectedIndent(forLine line: Int, head: String) -> String? {
        let lines = document.lines
        var depth = 0
        var l = line - 1
        let tab = textView.tabString
        while l >= 0 {
            let r = lines.contentRange(of: l, in: ns)
            let t = ns.substring(with: NSRange(location: r.location, length: min(r.length, 80)))
            let indent = String(t.prefix { $0 == " " || $0 == "\t" })
            switch BlockStructure.role(of: t) {
            case .end: depth += 1
            case .mid(let h):
                if depth == 0 && h == "when" && head != "end" { return indent }
            case .opener(let h):
                if depth == 0 {
                    if h == "match" && (head == "when" || head == "otherwise") { return indent + tab }
                    return indent
                }
                depth -= 1
            case .none: break
            }
            l -= 1
        }
        return nil
    }

    // MARK: line operations (used by EditorCommands)

    /// Lines covered by the primary selection.
    var selectedLineRange: ClosedRange<Int> {
        let sel = textView.selectedRange()
        let lines = document.lines
        let a = lines.line(at: sel.location)
        var b = lines.line(at: NSMaxRange(sel))
        if sel.length > 0 && b > a && lines.start(of: b) == NSMaxRange(sel) { b -= 1 }
        return a...b
    }

    func indentLines(by dir: Int) {
        let tab = textView.tabString
        let size = (tab as NSString).length
        let lines = document.lines
        let r = selectedLineRange
        let sel = textView.selectedRange()
        var edits: [(range: NSRange, text: String)] = []
        var firstDelta = 0, total = 0
        for l in r {
            let start = lines.start(of: l)
            let lr = lines.contentRange(of: l, in: ns)
            if dir > 0 {
                if lr.length == 0 && r.count > 1 { continue }
                edits.append((NSRange(location: start, length: 0), tab))
                if l == r.lowerBound { firstDelta = size }
                total += size
            } else {
                var n = 0
                while n < size && n < lr.length && ns.character(at: start + n) == 32 { n += 1 }
                if n == 0 && lr.length > 0 && ns.character(at: start) == 9 { n = 1 }
                if n > 0 {
                    edits.append((NSRange(location: start, length: n), ""))
                    if l == r.lowerBound { firstDelta = -n }
                    total -= n
                }
            }
        }
        guard !edits.isEmpty else { return }
        replace(edits: edits)
        let newLoc = max(lines.start(of: r.lowerBound), sel.location + firstDelta)
        textView.setSelectedRange(NSRange(location: newLoc, length: max(0, sel.length + total - firstDelta)))
    }

    func toggleComment() {
        guard let marker = document.language.lineComment else { return }
        let lines = document.lines
        let r = selectedLineRange
        var contents: [(Int, NSRange, String)] = []
        for l in r {
            let lr = lines.contentRange(of: l, in: ns)
            contents.append((l, lr, ns.substring(with: lr)))
        }
        let nonBlank = contents.filter { !$0.2.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonBlank.isEmpty else { return }
        let allCommented = nonBlank.allSatisfy { $0.2.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
        var edits: [(range: NSRange, text: String)] = []
        if allCommented {
            for (_, lr, t) in nonBlank {
                let lead = t.prefix { $0 == " " || $0 == "\t" }.utf16.count
                var len = (marker as NSString).length
                let after = lr.location + lead + len
                if after < NSMaxRange(lr) && ns.character(at: after) == 32 { len += 1 }
                edits.append((NSRange(location: lr.location + lead, length: len), ""))
            }
        } else {
            let minIndent = nonBlank.map { $0.2.prefix { $0 == " " || $0 == "\t" }.utf16.count }.min() ?? 0
            for (_, lr, _) in nonBlank { edits.append((NSRange(location: lr.location + minIndent, length: 0), marker + " ")) }
        }
        let sel = textView.selectedRange()
        let before = textView.selectedRange().location
        replace(edits: edits)
        // keep the selection over the same lines
        let s = lines.start(of: r.lowerBound)
        let e = NSMaxRange(lines.contentRange(of: r.upperBound, in: ns))
        if sel.length > 0 { textView.setSelectedRange(NSRange(location: s, length: e - s)) }
        else {
            let delta = allCommented ? -edits.first!.range.length : (marker as NSString).length + 1
            textView.setSelectedRange(NSRange(location: max(s, min(e, before + delta)), length: 0))
        }
    }

    func moveLines(_ dir: Int) {
        let lines = document.lines
        let r = selectedLineRange
        let sel = textView.selectedRange()
        if dir < 0 && r.lowerBound == 0 { return }
        if dir > 0 && r.upperBound >= lines.count - 1 { return }
        let blockStart = lines.start(of: r.lowerBound)
        let blockEnd = NSMaxRange(lines.range(of: r.upperBound))
        var block = ns.substring(with: NSRange(location: blockStart, length: blockEnd - blockStart))
        if dir < 0 {
            let prev = lines.range(of: r.lowerBound - 1)
            var prevText = ns.substring(with: prev)
            if !block.hasSuffix("\n") { block += "\n"; prevText = String(prevText.dropLast()) }
            replace(NSRange(location: prev.location, length: blockEnd - prev.location), with: block + prevText)
            textView.setSelectedRange(NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            let next = lines.range(of: r.upperBound + 1)
            var nextText = ns.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; block = String(block.dropLast()) }
            replace(NSRange(location: blockStart, length: NSMaxRange(next) - blockStart), with: nextText + block)
            textView.setSelectedRange(NSRange(location: sel.location + (nextText as NSString).length, length: sel.length))
        }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    func duplicateLines() {
        let lines = document.lines
        let r = selectedLineRange
        let sel = textView.selectedRange()
        let s = lines.start(of: r.lowerBound)
        let e = NSMaxRange(lines.range(of: r.upperBound))
        var block = ns.substring(with: NSRange(location: s, length: e - s))
        var insertAt = e
        if !block.hasSuffix("\n") { block = "\n" + block; insertAt = e }
        replace(NSRange(location: insertAt, length: 0), with: block)
        textView.setSelectedRange(NSRange(location: sel.location + (block as NSString).length, length: sel.length))
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    /// ⌘D: select the word, or add the next occurrence of the selection.
    func selectNextOccurrence() {
        let ranges = textView.allRanges
        guard let last = ranges.last else { return }
        if last.length == 0 {
            let w = wordRange(at: last.location)
            if w.length > 0 { textView.setAllRanges(ranges.dropLast() + [w], primary: ranges.count - 1) }
            return
        }
        let needle = ns.substring(with: last)
        let len = ns.length
        var found = ns.range(of: needle, options: [.literal], range: NSRange(location: NSMaxRange(last), length: len - NSMaxRange(last)))
        if found.location == NSNotFound { found = ns.range(of: needle, options: [.literal], range: NSRange(location: 0, length: last.location)) }
        guard found.location != NSNotFound, !ranges.contains(found) else { NSSound.beep(); return }
        var rs = ranges
        rs.append(found)
        textView.setAllRanges(rs, primary: rs.count - 1)
        textView.scrollRangeToVisible(found)
    }

    func selectAllOccurrences() {
        var sel = textView.selectedRange()
        if sel.length == 0 { sel = wordRange(at: sel.location) }
        guard sel.length > 0 else { return }
        let needle = ns.substring(with: sel)
        var out: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            out.append(r); from = NSMaxRange(r)
            if out.count > 2000 { break }
        }
        textView.setAllRanges(out)
    }

    func addCursor(_ dir: Int) {
        var rs = textView.allRanges
        guard let edge = dir < 0 ? rs.first : rs.last else { return }
        let p = document.lines.position(of: edge.location)
        let nl = p.line + dir
        guard nl >= 0, nl < document.lines.count else { return }
        let o = document.lines.offset(of: TextPosition(line: nl, column: p.column))
        rs.append(NSRange(location: o, length: 0))
        textView.setAllRanges(rs, primary: rs.count - 1)
    }

    func wordRange(at offset: Int) -> NSRange {
        let s = ns
        var a = offset, b = offset
        while a > 0 && VantaLexer.isIdent(s.character(at: a - 1)) { a -= 1 }
        while b < s.length && VantaLexer.isIdent(s.character(at: b)) { b += 1 }
        return NSRange(location: a, length: b - a)
    }

    // MARK: find

    func showFind(replace: Bool) {
        let sel = textView.selectedRange()
        if sel.length > 0 && sel.length < 200 {
            let t = ns.substring(with: sel)
            if !t.contains("\n") { find.query = t }
        }
        find.showReplace = replace || find.showReplace && find.visible
        if replace { find.showReplace = true }
        find.visible = true
        if findHost == nil {
            let host = NSHostingView(rootView: FindBar(model: find,
                onNext: { [weak self] in self?.findNext(1) },
                onPrev: { [weak self] in self?.findNext(-1) },
                onReplace: { [weak self] in self?.replaceCurrent() },
                onReplaceAll: { [weak self] in self?.replaceAllMatches() },
                onClose: { [weak self] in self?.closeFind() }))
            addSubview(host)
            findHost = host
        }
        findHost?.isHidden = false
        layoutFindBar()
        find.focusToken += 1
        recomputeFind(selectFirst: false)
    }

    private func layoutFindBar() {
        guard let h = findHost, find.visible else { return }
        let size = h.fittingSize
        h.frame = NSRect(x: max(4, bounds.width - size.width - 22), y: 6, width: size.width, height: size.height)
    }

    func closeFind() {
        find.visible = false
        findHost?.isHidden = true
        textView.needsDisplay = true
        focus()
    }

    func recomputeFind(selectFirst: Bool) {
        guard find.visible else { return }
        find.compute(in: text)
        if selectFirst, let i = find.index(after: textView.selectedRange().location) {
            find.current = i
            textView.scrollRangeToVisible(find.matches[i])
        } else if find.current < 0 || find.current >= find.matches.count {
            find.current = find.index(after: textView.selectedRange().location) ?? -1
        }
        layoutFindBar()
        textView.needsDisplay = true
    }

    func findNext(_ dir: Int) {
        if !find.visible { showFind(replace: false) }
        guard !find.matches.isEmpty else { NSSound.beep(); return }
        let sel = textView.selectedRange()
        var i: Int
        if dir > 0 {
            i = find.matches.firstIndex { $0.location > sel.location || ($0.location == sel.location && sel.length == 0) } ?? 0
            if find.matches[i] == sel { i = (i + 1) % find.matches.count }
        } else {
            i = find.matches.lastIndex { $0.location < sel.location } ?? find.matches.count - 1
        }
        find.current = i
        let r = find.matches[i]
        unfoldContaining(r.location)
        textView.extraCarets = []
        textView.setSelectedRange(r)
        reveal(r)
        textView.needsDisplay = true
    }

    func replaceCurrent() {
        guard find.current >= 0, find.current < find.matches.count, let re = find.regexObject() else { findNext(1); return }
        let r = find.matches[find.current]
        let sub = ns.substring(with: r)
        let rep: String
        if find.regex, let m = re.firstMatch(in: sub, range: NSRange(location: 0, length: (sub as NSString).length)) {
            rep = re.replacementString(for: m, in: sub, offset: 0, template: find.replacement)
        } else { rep = find.replacement }
        replace(r, with: rep)
        textView.setSelectedRange(NSRange(location: r.location + (rep as NSString).length, length: 0))
        recomputeFind(selectFirst: false)
        findNext(1)
    }

    func replaceAllMatches() {
        guard let re = find.regexObject(), !find.matches.isEmpty else { return }
        let t = text
        var edits: [(range: NSRange, text: String)] = []
        for r in find.matches {
            let rep: String
            if find.regex, let m = re.firstMatch(in: t, range: r) {
                rep = re.replacementString(for: m, in: t, offset: 0, template: find.replacement)
            } else { rep = find.replacement }
            edits.append((r, rep))
        }
        replace(edits: edits)
        Services.shared.flash("Replaced \(edits.count) occurrence\(edits.count == 1 ? "" : "s")")
        recomputeFind(selectFirst: false)
    }

    // MARK: completion popup

    private var completionRequest = 0

    func triggerCompletion(explicit: Bool) {
        let providers = LanguageRegistry.shared.completionProviders
        guard !providers.isEmpty, !textView.isMulti else { hideCompletion(); return }
        let caret = textView.selectedRange().location
        var a = caret
        while a > 0 && VantaLexer.isIdent(ns.character(at: a - 1)) { a -= 1 }
        let prefix = ns.substring(with: NSRange(location: a, length: caret - a))
        if !explicit && prefix.isEmpty { hideCompletion(); return }
        if !explicit && document.token(at: max(0, caret - 1)).isStringOrComment { hideCompletion(); return }
        completionRequest += 1
        let id = completionRequest
        let ctx = DocumentContext(uri: document.uri, text: text, languageID: document.language.rawValue,
                                  offset: caret, position: document.lines.position(of: caret))
        Task { [weak self] in
            var all: [CompletionItem] = []
            for p in providers { all += await p.completions(ctx, prefix: prefix) }
            await MainActor.run {
                guard let self, id == self.completionRequest else { return }
                self.showCompletion(all, prefix: prefix, range: NSRange(location: a, length: caret - a))
            }
        }
    }

    private func showCompletion(_ items: [CompletionItem], prefix: String, range: NSRange) {
        var seen = Set<String>()
        var scored: [(CompletionItem, Int, [Int])] = []
        for it in items where !seen.contains(it.label) {
            seen.insert(it.label)
            if prefix.isEmpty { scored.append((it, 0, [])); continue }
            if it.label == prefix { continue }
            if let m = Fuzzy.match(prefix, it.label) { scored.append((it, m.score, m.indices)) }
        }
        scored.sort { ($0.1, $0.0.sortPriority, $1.0.label) > ($1.1, $1.0.sortPriority, $0.0.label) }
        let top = Array(scored.prefix(60))
        guard !top.isEmpty else { hideCompletion(); return }
        completion.items = top.map { $0.0 }
        completion.matchIndices = Dictionary(uniqueKeysWithValues: top.map { ($0.0.id, $0.2) })
        completion.selected = 0
        completion.replaceRange = range
        completion.isVisible = true
        if completionHost == nil {
            let host = NSHostingView(rootView: CompletionList(model: completion, onPick: { [weak self] i in
                self?.completion.selected = i
                self?.acceptCompletion()
            }))
            addSubview(host)
            completionHost = host
        }
        completionHost?.isHidden = false
        setGhostText(nil, at: nil)
        positionCompletion()
    }

    private func positionCompletion() {
        guard let host = completionHost, completion.isVisible else { return }
        let caret = convert(caretRect(at: completion.replaceRange.location), from: textView)
        let size = host.fittingSize
        var y = caret.maxY + 2
        if y + size.height > bounds.height - 4 { y = caret.minY - size.height - 2 }
        let x = min(max(4, caret.minX - 22), bounds.width - size.width - 4)
        host.frame = NSRect(x: x, y: max(2, y), width: size.width, height: size.height)
    }

    func hideCompletion() {
        guard completion.isVisible else { return }
        completion.isVisible = false
        completionHost?.isHidden = true
        completionRequest += 1
    }

    func acceptCompletion() {
        guard let item = completion.current else { hideCompletion(); return }
        let caret = textView.selectedRange().location
        let range = NSRange(location: completion.replaceRange.location, length: max(0, caret - completion.replaceRange.location))
        var insert = item.insertText ?? item.label
        var cursorOffset: Int?
        if let r = insert.range(of: "$0") {
            cursorOffset = insert[..<r.lowerBound].utf16.count
            insert.removeSubrange(r)
        }
        hideCompletion()
        textView.insertText(insert, replacementRange: range)
        if let c = cursorOffset { textView.setSelectedRange(NSRange(location: range.location + c, length: 0)) }
    }

    // MARK: hover

    private var hoverWork: DispatchWorkItem?
    private var hoverAnchor: NSPoint?

    func mouseMoved(to point: NSPoint) {
        if let a = hoverAnchor, hoverHost?.isHidden == false {
            if abs(point.x - a.x) > 24 || abs(point.y - a.y) > lineHeight { hideHover() } else { return }
        }
        hoverWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.showHover(at: point) }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    func mouseExited() { hoverWork?.cancel() }

    private func showHover(at point: NSPoint) {
        let origin = textView.textContainerOrigin
        let cp = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var frac: CGFloat = 0
        let gi = layoutManager.glyphIndex(for: cp, in: container, fractionOfDistanceThroughGlyph: &frac)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: gi, length: 1), in: container)
        guard glyphRect.insetBy(dx: -2, dy: 0).contains(cp) else { return }
        let idx = layoutManager.characterIndexForGlyph(at: gi)
        var entries: [HoverCard.Entry] = []
        for d in diagnostics where NSLocationInRange(idx, charRange(of: d)) || (charRange(of: d).length <= 1 && document.lines.line(at: idx) == d.range.start.line) {
            entries.append(.init(severity: d.severity, text: d.message + (d.source.isEmpty ? "" : "  ·  \(d.source)")))
        }
        let ctx = DocumentContext(uri: document.uri, text: text, languageID: document.language.rawValue,
                                  offset: idx, position: document.lines.position(of: idx))
        let providers = LanguageRegistry.shared.hoverProviders
        Task { [weak self] in
            var more: [HoverCard.Entry] = []
            for p in providers { if let h = await p.hover(ctx) { more.append(.init(severity: nil, text: h.markdown)) } }
            await MainActor.run {
                guard let self else { return }
                let all = entries + more
                guard !all.isEmpty else { return }
                self.presentHover(all, at: point)
            }
        }
    }

    private func presentHover(_ entries: [HoverCard.Entry], at point: NSPoint) {
        hoverHost?.removeFromSuperview()
        let host = NSHostingView(rootView: HoverCard(entries: entries))
        let size = host.fittingSize
        let p = convert(point, from: textView)
        let lineTop = p.y - lineHeight / 2
        var y = lineTop - size.height - 4
        if y < 4 { y = lineTop + lineHeight + 4 }
        host.frame = NSRect(x: min(max(4, p.x - 20), bounds.width - size.width - 8), y: y, width: size.width, height: size.height)
        addSubview(host)
        hoverHost = host
        hoverAnchor = point
    }

    @discardableResult
    func hideHover() -> Bool {
        hoverWork?.cancel()
        guard let h = hoverHost else { return false }
        h.removeFromSuperview()
        hoverHost = nil
        hoverAnchor = nil
        return true
    }

    // MARK: go to definition

    func goToDefinition(at offset: Int? = nil) {
        let idx = offset ?? textView.selectedRange().location
        let ctx = DocumentContext(uri: document.uri, text: text, languageID: document.language.rawValue,
                                  offset: idx, position: document.lines.position(of: idx))
        let word = ns.substring(with: wordRange(at: idx))
        let providers = LanguageRegistry.shared.definitionProviders
        let symbols = LanguageRegistry.shared.symbolProvider
        let uri = document.uri
        let t = text
        Task { [weak self] in
            var locs: [Location] = []
            for p in providers { locs += await p.definition(ctx) }
            if locs.isEmpty, !word.isEmpty, let sp = symbols {
                func flat(_ s: [DocumentSymbol]) -> [DocumentSymbol] { s.flatMap { [$0] + flat($0.children) } }
                let syms = flat(await sp.symbols(text: t, uri: uri))
                if let s = syms.first(where: { $0.name == word }) {
                    locs = [Location(uri: uri, range: TextRange(start: TextPosition(line: s.line, column: 0), end: TextPosition(line: s.line, column: 0)))]
                }
            }
            await MainActor.run {
                guard let loc = locs.first else { Services.shared.flash("No definition found for “\(word)”"); return }
                if loc.uri == self?.document.uri, let self {
                    self.scrollToLine(loc.range.start.line, select: true)
                    let o = self.offset(of: loc.range.start)
                    if loc.range.start.column > 0 { self.textView.setSelectedRange(NSRange(location: o, length: 0)) }
                } else {
                    Services.shared.editors.open(location: loc)
                }
            }
        }
    }

    // MARK: format

    func formatDocument() {
        guard let f = LanguageRegistry.shared.formattingProvider else { Services.shared.flash("No formatter registered"); return }
        let t = text, uri = document.uri
        Task { [weak self] in
            let out = await f.format(text: t, uri: uri)
            await MainActor.run {
                guard let self, let out, self.text == t else { return }
                self.setText(out)
            }
        }
    }

    // MARK: events

    var textChanges: AnyPublisher<TextChange, Never> { document.changes.eraseToAnyPublisher() }
    var selectionChanges: AnyPublisher<[NSRange], Never> { selectionSubject.eraseToAnyPublisher() }
}
