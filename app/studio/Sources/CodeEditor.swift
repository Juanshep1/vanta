import SwiftUI
import AppKit

// A native code editor: a TextKit-1 NSTextView with Vanta syntax highlighting
// and a line-number ruler, wrapped for SwiftUI.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
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
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            tv.string = text
            VantaSyntax.highlight(tv.textStorage!, font: Self.font)
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeEditor
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        init(_ p: CodeEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            VantaSyntax.highlight(tv.textStorage!, font: CodeEditor.font)
            ruler?.needsDisplay = true
        }
    }
}

// A simple line-number gutter for the editor.
final class LineNumberRuler: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView,
              let layout = tv.layoutManager,
              let container = tv.textContainer else { return }

        Theme.nbg.setFill()
        rect.fill()

        let text = tv.string as NSString
        let visible = tv.visibleRect
        let inset = tv.textContainerInset.height
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.nline,
        ]

        // Walk each line, draw its number at its glyph y-position.
        var lineNumber = 1
        var charIndex = 0
        let length = text.length
        while charIndex <= length {
            let lineRange = text.lineRange(for: NSRange(location: min(charIndex, max(length - 1, 0)), length: 0))
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
