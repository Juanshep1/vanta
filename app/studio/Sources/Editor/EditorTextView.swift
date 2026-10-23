import AppKit

/// The NSTextView behind every editor pane. Adds multiple cursors, smart Vanta
/// indentation, bracket/quote auto-pairing, ghost-text acceptance, completion
/// popup keyboard navigation, ⌥-click carets and decoration drawing hooks.
/// All decorations themselves are owned and drawn by `EditorPane`.
final class EditorTextView: NSTextView {
    weak var pane: EditorPane?

    /// Additional zero-length carets (absolute offsets) beyond `selectedRanges`.
    var extraCarets: [Int] = [] { didSet { if extraCarets != oldValue { needsDisplay = true } } }
    private var internalSelectionChange = false

    var tabString: String { String(repeating: " ", count: max(1, StudioSettings.shared.prefs.tabSize)) }
    private var ns: NSString { string as NSString }

    // MARK: selections

    /// Every selection + caret, sorted, merged.
    var allRanges: [NSRange] {
        var rs = selectedRanges.map { $0.rangeValue } + extraCarets.map { NSRange(location: $0, length: 0) }
        rs.sort { $0.location < $1.location }
        var out: [NSRange] = []
        for r in rs {
            if let last = out.last {
                if r == last { continue }
                if r.location < NSMaxRange(last) || (r.length == 0 && r.location == NSMaxRange(last) && last.length > 0) {
                    out[out.count - 1] = NSUnionRange(last, r); continue
                }
            }
            out.append(r)
        }
        return out
    }

    var isMulti: Bool { allRanges.count > 1 }

    /// Set every selection/caret. Non-empty ranges become real selections,
    /// zero-length ones (other than the primary) become extra carets.
    func setAllRanges(_ ranges: [NSRange], primary: Int? = nil) {
        let len = ns.length
        let clamped = ranges.map { r -> NSRange in
            let loc = max(0, min(r.location, len))
            return NSRange(location: loc, length: max(0, min(r.length, len - loc)))
        }
        guard !clamped.isEmpty else { return }
        let nonEmpty = clamped.filter { $0.length > 0 }
        internalSelectionChange = true
        if nonEmpty.isEmpty {
            let p = primary.map { min(max(0, $0), clamped.count - 1) } ?? 0
            super.setSelectedRanges([NSValue(range: clamped[p])], affinity: .downstream, stillSelecting: false)
            extraCarets = clamped.enumerated().filter { $0.offset != p }.map { $0.element.location }
        } else {
            super.setSelectedRanges(nonEmpty.map { NSValue(range: $0) }, affinity: .downstream, stillSelecting: false)
            extraCarets = clamped.filter { $0.length == 0 }.map(\.location)
        }
        internalSelectionChange = false
        pane?.selectionDidChange()
    }

    func collapseToPrimary() {
        extraCarets = []
        let first = selectedRange()
        setSelectedRange(first)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        pane?.clearGhostIfNeeded()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !internalSelectionChange && !stillSelecting { pane?.selectionDidChange() }
    }

    // MARK: focus

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { pane?.didFocus() }
        return ok
    }

    // MARK: key routing

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        if let p = pane, p.hasInlineDiff {
            if KeyShortcut("return", [.cmd]).matches(event) { p.acceptInlineDiff(); return true }
            if KeyShortcut("delete", [.cmd]).matches(event) { p.rejectInlineDiff(); return true }
        }
        if let c = CommandRegistry.shared.command(matching: event, editorKeysOnly: true) {
            CommandRegistry.shared.run(c.id); return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let p = pane {
            if p.completion.isVisible {
                switch event.keyCode {
                case 125: p.completion.move(1); return              // down
                case 126: p.completion.move(-1); return             // up
                case 121: p.completion.move(8); return              // page down
                case 116: p.completion.move(-8); return             // page up
                case 36, 76, 48:                                    // return / enter / tab
                    if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                        p.acceptCompletion(); return
                    }
                case 53: p.hideCompletion(); return                 // esc
                default: break
                }
            }
            if event.keyCode == 53 {                               // esc
                if p.hasInlineDiff { p.rejectInlineDiff(); return }
                if p.ghostText != nil { p.setGhostText(nil, at: nil); return }
                if !extraCarets.isEmpty || selectedRanges.count > 1 { collapseToPrimary(); return }
                if p.find.visible { p.closeFind(); return }
                if p.hideHover() { return }
                return              // don't open AppKit's word-completion menu
            }
            if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .control {
                p.triggerCompletion(explicit: true); return           // ⌃Space
            }
        }
        if let c = CommandRegistry.shared.command(matching: event, editorKeysOnly: true) {
            CommandRegistry.shared.run(c.id); return
        }
        super.keyDown(with: event)
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pane?.hideHover()
        pane?.hideCompletion()
        if let p = pane, p.handleFoldPlaceholderClick(at: point) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .option && event.clickCount == 1 {
            let idx = characterIndexForInsertion(at: point)
            var rs = allRanges
            if let i = rs.firstIndex(where: { $0.length == 0 && $0.location == idx }), rs.count > 1 { rs.remove(at: i) }
            else { rs.append(NSRange(location: idx, length: 0)) }
            setAllRanges(rs, primary: rs.count - 1)
            return
        }
        if flags == .command && event.clickCount == 1 {
            let idx = characterIndexForInsertion(at: point)
            super.mouseDown(with: event)
            setSelectedRange(NSRange(location: idx, length: 0))
            pane?.goToDefinition(at: idx)
            return
        }
        extraCarets = []
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        pane?.mouseMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pane?.mouseExited()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self && t.userInfo?["vanta"] != nil { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["vanta": true]))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let reg = CommandRegistry.shared
        var items: [NSMenuItem] = []
        for id in ["editor.goToDefinition", "ai.inlineEdit", "editor.toggleComment", "editor.format", "editor.fold", "editor.unfold"] {
            guard let c = reg.command(id) else { continue }
            let item = NSMenuItem(title: c.title, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            items.append(item)
        }
        if !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() { menu.insertItem(item, at: 0) }
        }
        return menu
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { CommandRegistry.shared.run(id) }
    }

    // MARK: drawing hooks

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        pane?.drawUnderlays(in: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        pane?.drawOverlays(in: dirtyRect)
    }

    // MARK: multi-cursor editing primitive

    /// Apply one edit per range (computed by `make`) as a single undo step and
    /// put a caret/selection where each edit asks. `make` returns
    /// (range to replace, replacement, selection relative to the replacement start).
    func multiEdit(_ make: (NSRange) -> (NSRange, String, NSRange)?) {
        let ranges = allRanges
        var edits: [(NSRange, String, NSRange)] = []
        for r in ranges { if let e = make(r) { edits.append(e) } }
        guard !edits.isEmpty else { return }
        edits.sort { $0.0.location < $1.0.location }
        // drop overlaps
        var clean: [(NSRange, String, NSRange)] = []
        for e in edits {
            if let last = clean.last, e.0.location < NSMaxRange(last.0) { continue }
            clean.append(e)
        }
        breakUndoCoalescing()
        let vals = clean.map { NSValue(range: $0.0) }
        let strs = clean.map { $0.1 }
        guard shouldChangeText(inRanges: vals, replacementStrings: strs), let ts = textStorage else { return }
        ts.beginEditing()
        for e in clean.reversed() { ts.replaceCharacters(in: e.0, with: e.1) }
        ts.endEditing()
        didChangeText()
        var delta = 0
        var newSel: [NSRange] = []
        for e in clean {
            let start = e.0.location + delta
            newSel.append(NSRange(location: start + e.2.location, length: e.2.length))
            delta += (e.1 as NSString).length - e.0.length
        }
        setAllRanges(newSel, primary: newSel.count - 1)
        scrollRangeToVisible(newSel.last ?? NSRange(location: 0, length: 0))
    }

    // MARK: typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if pane?.hasInlineDiff == true && replacementRange.location == NSNotFound { pane?.rejectInlineDiff() }
        if isMulti && replacementRange.location == NSNotFound && !hasMarkedText() {
            let len = (s as NSString).length
            multiEdit { r in (r, s, NSRange(location: len, length: 0)) }
            return
        }
        guard replacementRange.location == NSNotFound, !hasMarkedText(), (s as NSString).length == 1,
              StudioSettings.shared.prefs.autoCloseBrackets, let pane else {
            super.insertText(string, replacementRange: replacementRange)
            afterTyping(s)
            return
        }
        let sel = selectedRange()
        let next: unichar? = NSMaxRange(sel) < ns.length ? ns.character(at: NSMaxRange(sel)) : nil
        let prev: unichar? = sel.location > 0 ? ns.character(at: sel.location - 1) : nil
        let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\""]
        let closers: Set<String> = [")", "]", "}", "\""]
        let inString = pane.document.token(at: max(0, sel.location - 1)).isStringOrComment && s != "\""

        // over-type a closer that we (probably) inserted
        if sel.length == 0, closers.contains(s), let n = next, String(utf16CodeUnits: [n], count: 1) == s {
            if s != "\"" || pane.document.token(at: sel.location) == .string {
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                return
            }
        }
        if let close = pairs[s], !inString {
            if sel.length > 0 {                                  // wrap the selection
                let inner = ns.substring(with: sel)
                insertText(s + inner + close, replacementRange: sel)
                setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
                return
            }
            let nextOK = next == nil || next == 10 || next == 32 || next == 9 || [41, 93, 125, 44].contains(next!)
            var ok = nextOK
            if s == "\"" {
                let prevIsWord = prev.map { VantaLexer.isIdent($0) || $0 == 34 } ?? false
                ok = nextOK && !prevIsWord
            }
            if ok {
                super.insertText(s + close, replacementRange: replacementRange)
                setSelectedRange(NSRange(location: sel.location + 1, length: 0))
                afterTyping(s)
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
        afterTyping(s)
    }

    /// Auto-dedent `end` / `otherwise` / `rescue` / `when` as soon as the word is typed.
    private func afterTyping(_ s: String) {
        guard let pane, pane.document.language == .vanta, s.count == 1, let ch = s.first, ch.isLetter || ch == " " else {
            pane?.didType(s); return
        }
        let caret = selectedRange().location
        let lines = pane.document.lines
        let l = lines.line(at: caret)
        let r = lines.contentRange(of: l, in: ns)
        let lineText = ns.substring(with: r)
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        let caretAtEnd = caret == NSMaxRange(r)
        let exact = ["end", "otherwise", "rescue"].contains(trimmed) && ch.isLetter
        let whenLine = trimmed == "when" && ch == "n"
        if caretAtEnd && (exact || whenLine), let want = pane.expectedIndent(forLine: l, head: trimmed) {
            let current = String(lineText.prefix { $0 == " " || $0 == "\t" })
            if current != want {
                let cr = NSRange(location: r.location, length: (current as NSString).length)
                if shouldChangeText(in: cr, replacementString: want) {
                    textStorage?.replaceCharacters(in: cr, with: want)
                    didChangeText()
                    setSelectedRange(NSRange(location: r.location + (want as NSString).length + (trimmed as NSString).length, length: 0))
                }
            }
        }
        pane.didType(s)
    }

    override func insertNewline(_ sender: Any?) {
        if pane?.hasInlineDiff == true { pane?.rejectInlineDiff() }
        let lines = pane?.document.lines
        let isVanta = pane?.document.language == .vanta
        let tab = tabString
        let make: (NSRange) -> (NSRange, String, NSRange)? = { [weak self] r in
            guard let self, let lines else { return (r, "\n", NSRange(location: 1, length: 0)) }
            let ns = self.ns
            let l = lines.line(at: r.location)
            let lr = lines.contentRange(of: l, in: ns)
            let before = ns.substring(with: NSRange(location: lr.location, length: r.location - lr.location))
            var indent = String(before.prefix { $0 == " " || $0 == "\t" })
            if before.trimmingCharacters(in: .whitespaces).isEmpty {
                // blank-ish line: keep the indentation of the whole line
                let full = ns.substring(with: lr)
                indent = String(full.prefix { $0 == " " || $0 == "\t" })
                if (indent as NSString).length > (before as NSString).length { indent = before }
            }
            let opens = isVanta ? BlockStructure.opensIndent(before) : before.trimmingCharacters(in: .whitespaces).last.map { "([{".contains($0) } ?? false
            let next: unichar? = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : nil
            let prev: unichar? = r.location > 0 ? ns.character(at: r.location - 1) : nil
            if let p = prev, let n = next, (p == 40 && n == 41) || (p == 91 && n == 93) || (p == 123 && n == 125) {
                let ins = "\n" + indent + tab + "\n" + indent
                return (r, ins, NSRange(location: 1 + (indent as NSString).length + (tab as NSString).length, length: 0))
            }
            let ins = "\n" + indent + (opens ? tab : "")
            return (r, ins, NSRange(location: (ins as NSString).length, length: 0))
        }
        if isMulti { multiEdit(make); return }
        let r = selectedRange()
        guard let (range, text, sel) = make(r) else { super.insertNewline(sender); return }
        if shouldChangeText(in: range, replacementString: text) {
            textStorage?.replaceCharacters(in: range, with: text)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + sel.location, length: 0))
            scrollRangeToVisible(selectedRange())
        }
        pane?.didType("\n")
    }

    override func insertTab(_ sender: Any?) {
        if let p = pane {
            if p.completion.isVisible { p.acceptCompletion(); return }
            if p.acceptGhost() { return }
        }
        if isMulti {
            let tab = tabString
            multiEdit { r in (r, tab, NSRange(location: (tab as NSString).length, length: 0)) }
            return
        }
        let sel = selectedRange()
        if sel.length > 0, ns.substring(with: sel).contains("\n") {
            pane?.indentLines(by: 1); return
        }
        // soft tab to the next tab stop
        let lines = pane?.document.lines
        let col = lines.map { sel.location - $0.start(of: $0.line(at: sel.location)) } ?? 0
        let size = max(1, StudioSettings.shared.prefs.tabSize)
        let n = size - (col % size)
        insertText(String(repeating: " ", count: n), replacementRange: sel)
    }

    override func insertBacktab(_ sender: Any?) { pane?.indentLines(by: -1) }

    override func deleteBackward(_ sender: Any?) {
        if pane?.hasInlineDiff == true { pane?.rejectInlineDiff() }
        let ns = self.ns
        let make: (NSRange) -> (NSRange, String, NSRange)? = { [weak self] r in
            guard let self else { return nil }
            if r.length > 0 { return (r, "", NSRange(location: 0, length: 0)) }
            guard r.location > 0 else { return nil }
            // soft-tab: delete back to the previous tab stop inside leading spaces
            if let lines = self.pane?.document.lines {
                let ls = lines.start(of: lines.line(at: r.location))
                let before = ns.substring(with: NSRange(location: ls, length: r.location - ls))
                if !before.isEmpty && before.allSatisfy({ $0 == " " }) {
                    let size = max(1, StudioSettings.shared.prefs.tabSize)
                    let n = (before.count - 1) % size + 1
                    return (NSRange(location: r.location - n, length: n), "", NSRange(location: 0, length: 0))
                }
            }
            // delete an empty auto-pair: (|)
            if r.location < ns.length {
                let p = ns.character(at: r.location - 1), n = ns.character(at: r.location)
                if (p == 40 && n == 41) || (p == 91 && n == 93) || (p == 123 && n == 125) || (p == 34 && n == 34) {
                    return (NSRange(location: r.location - 1, length: 2), "", NSRange(location: 0, length: 0))
                }
            }
            let cr = ns.rangeOfComposedCharacterSequence(at: r.location - 1)
            return (cr, "", NSRange(location: 0, length: 0))
        }
        if isMulti { multiEdit(make); return }
        let r = selectedRange()
        if r.length == 0, let (range, text, _) = make(r), range.length > 1 || text != "" {
            if shouldChangeText(in: range, replacementString: text) {
                textStorage?.replaceCharacters(in: range, with: text)
                didChangeText()
                setSelectedRange(NSRange(location: range.location, length: 0))
            }
            pane?.didType("")
            return
        }
        super.deleteBackward(sender)
        pane?.didType("")
    }

    override func deleteForward(_ sender: Any?) {
        if isMulti {
            let ns = self.ns
            multiEdit { r in
                if r.length > 0 { return (r, "", NSRange(location: 0, length: 0)) }
                guard r.location < ns.length else { return nil }
                return (ns.rangeOfComposedCharacterSequence(at: r.location), "", NSRange(location: 0, length: 0))
            }
            return
        }
        super.deleteForward(sender)
    }

    // MARK: multi-caret movement

    private func moveAll(_ f: (NSRange) -> Int) {
        let rs = allRanges.map { NSRange(location: f($0), length: 0) }
        setAllRanges(rs, primary: rs.count - 1)
    }

    private func verticalMove(_ r: NSRange, _ dir: Int) -> Int {
        guard let lines = pane?.document.lines else { return r.location }
        let p = lines.position(of: r.location)
        let nl = p.line + dir
        if nl < 0 { return 0 }
        if nl >= lines.count { return ns.length }
        return lines.offset(of: TextPosition(line: nl, column: p.column))
    }

    override func moveLeft(_ sender: Any?) {
        guard isMulti else { super.moveLeft(sender); return }
        moveAll { $0.length > 0 ? $0.location : max(0, $0.location - 1) }
    }
    override func moveRight(_ sender: Any?) {
        guard isMulti else { super.moveRight(sender); return }
        let len = ns.length
        moveAll { $0.length > 0 ? NSMaxRange($0) : min(len, $0.location + 1) }
    }
    override func moveUp(_ sender: Any?) {
        guard isMulti else { super.moveUp(sender); return }
        moveAll { verticalMove($0, -1) }
    }
    override func moveDown(_ sender: Any?) {
        guard isMulti else { super.moveDown(sender); return }
        moveAll { verticalMove($0, 1) }
    }
    override func moveToBeginningOfLine(_ sender: Any?) {
        guard isMulti, let lines = pane?.document.lines else { super.moveToBeginningOfLine(sender); return }
        moveAll { lines.start(of: lines.line(at: $0.location)) }
    }
    override func moveToEndOfLine(_ sender: Any?) {
        guard isMulti, let lines = pane?.document.lines else { super.moveToEndOfLine(sender); return }
        let ns = self.ns
        moveAll { NSMaxRange(lines.contentRange(of: lines.line(at: $0.location), in: ns)) }
    }
    override func moveToLeftEndOfLine(_ sender: Any?) { isMulti ? moveToBeginningOfLine(sender) : super.moveToLeftEndOfLine(sender) }
    override func moveToRightEndOfLine(_ sender: Any?) { isMulti ? moveToEndOfLine(sender) : super.moveToRightEndOfLine(sender) }

    // Paste into multiple carets: one line per caret when counts match.
    override func paste(_ sender: Any?) {
        guard isMulti, let s = NSPasteboard.general.string(forType: .string) else { super.paste(sender); return }
        let parts = s.components(separatedBy: "\n")
        let count = allRanges.count
        var i = 0
        multiEdit { r in
            let piece = parts.count == count ? parts[i] : s
            i += 1
            return (r, piece, NSRange(location: (piece as NSString).length, length: 0))
        }
    }
}
