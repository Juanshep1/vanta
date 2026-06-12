import SwiftUI
import AppKit

// NSTextView subclass with the Cursor-style superpowers: ⌘K inline edit,
// AI ghost-text autocomplete, and Tab-to-accept.
final class VantaTextView: NSTextView {
    var onCmdK: ((NSRange, String) -> Void)?
    var onTyped: (() -> Void)?
    var ghost: String? { didSet { needsDisplay = true } }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            let range = selectedRange()
            let sel = (string as NSString).substring(with: range)
            onCmdK?(range, sel)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func insertTab(_ sender: Any?) {
        if let g = ghost, !g.isEmpty {
            insertText(g, replacementRange: selectedRange())
            ghost = nil
            return
        }
        super.insertTab(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if ghost != nil { ghost = nil; return }
        super.cancelOperation(sender)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if ghost != nil { ghost = nil }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let g = ghost, !g.isEmpty, let lm = layoutManager, let tc = textContainer else { return }
        let loc = selectedRange().location
        let s = string as NSString
        var origin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
        if loc > 0 && loc <= s.length {
            let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: loc - 1, length: 1), actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            origin = NSPoint(x: r.maxX + textContainerInset.width, y: r.minY + textContainerInset.height)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.systemGray.withAlphaComponent(0.55),
        ]
        // draw only the first line of the suggestion inline; rest below
        let lines = g.components(separatedBy: "\n")
        (lines[0] as NSString).draw(at: origin, withAttributes: attrs)
        if lines.count > 1 {
            let lineH = (font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)).boundingRectForFont.height
            for (k, ln) in lines.dropFirst().enumerated() {
                let p = NSPoint(x: textContainerInset.width, y: origin.y + CGFloat(k + 1) * lineH)
                (ln as NSString).draw(at: p, withAttributes: attrs)
            }
        }
    }
}

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var onInlineEdit: (NSRange, String) -> Void = { _, _ in }
    var requestCompletion: ((String, String, @escaping (String?) -> Void) -> Void)?
    var autocompleteEnabled: Bool = false

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = VantaTextView(frame: .zero, textContainer: container)
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Self.font
        tv.backgroundColor = Theme.nbg
        tv.drawsBackground = true
        tv.textColor = Theme.nink
        tv.insertionPointColor = Theme.naccent
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = .width
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.onCmdK = { range, sel in onInlineEdit(range, sel) }
        tv.onTyped = { [weak coordinator = context.coordinator] in coordinator?.scheduleCompletion() }
        VantaSyntax.highlight(tv.textStorage!, font: Self.font)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.nbg
        scroll.borderType = .noBorder

        let ruler = LineNumberRuler(textView: tv)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        context.coordinator.textView = tv
        context.coordinator.ruler = ruler
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            VantaSyntax.highlight(tv.textStorage!, font: Self.font)
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: VantaTextView?
        weak var ruler: LineNumberRuler?
        private var pending: DispatchWorkItem?

        init(_ p: CodeEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            VantaSyntax.highlight(tv.textStorage!, font: CodeEditor.font)
            ruler?.needsDisplay = true
            scheduleCompletion()
        }

        func scheduleCompletion() {
            pending?.cancel()
            guard parent.autocompleteEnabled, parent.requestCompletion != nil else { return }
            let work = DispatchWorkItem { [weak self] in self?.fetchCompletion() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
        }

        private func fetchCompletion() {
            guard let tv = textView, let req = parent.requestCompletion else { return }
            let loc = tv.selectedRange().location
            let full = tv.string as NSString
            guard loc <= full.length else { return }
            let prefix = full.substring(to: loc)
            let suffix = full.substring(from: loc)
            // only suggest when at end of a line with some context
            guard !prefix.isEmpty, suffix.first.map({ $0 == "\n" }) ?? true else { return }
            req(prefix, suffix) { [weak self] suggestion in
                guard let self, let tv = self.textView else { return }
                // only show if the cursor hasn't moved
                if tv.selectedRange().location == loc, let s = suggestion, !s.isEmpty {
                    tv.ghost = s
                }
            }
        }
    }
}

// Line-number gutter.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 42
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let layout = tv.layoutManager, let container = tv.textContainer else { return }
        Theme.nbg.setFill()
        bounds.fill()

        let text = tv.string as NSString
        let visible = tv.visibleRect
        let inset = tv.textContainerInset.height
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.nline,
        ]
        var lineNumber = 1
        var charIndex = 0
        let length = text.length
        while charIndex <= length {
            let safe = min(charIndex, max(length - 1, 0))
            let lineRange = text.lineRange(for: NSRange(location: safe, length: 0))
            let glyphRange = layout.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layout.boundingRect(forGlyphRange: glyphRange, in: container)
            lineRect.origin.y += inset
            if lineRect.maxY >= visible.minY && lineRect.minY <= visible.maxY {
                let y = lineRect.minY - visible.minY
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attrs)
                label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y), withAttributes: attrs)
            }
            lineNumber += 1
            let next = NSMaxRange(lineRange)
            if next <= charIndex { break }
            charIndex = next
        }
    }
}
