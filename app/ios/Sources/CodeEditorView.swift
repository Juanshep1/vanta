import SwiftUI
import UIKit

// The code editor: a UITextView tuned for writing code on a phone —
// no autocorrect, live syntax highlighting, a line-number gutter,
// auto-indent, and a keyboard accessory bar with the characters and
// keywords Vanta uses most. Pass `errorLine` to paint a failing line red.
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 15
    var errorLine: Int? = nil

    func makeUIView(context: Context) -> LineNumberTextView {
        let tv = LineNumberTextView()
        tv.backgroundColor = Theme.ubg
        tv.font = Theme.codeFont(fontSize)
        tv.textColor = Theme.uink
        tv.tintColor = Theme.uaccent
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardAppearance = .dark
        tv.keyboardDismissMode = .interactive
        tv.alwaysBounceVertical = true
        tv.delegate = context.coordinator
        tv.inputAccessoryView = context.coordinator.makeAccessoryBar(for: tv)
        tv.text = text
        context.coordinator.highlight(tv)
        return tv
    }

    func updateUIView(_ tv: LineNumberTextView, context: Context) {
        context.coordinator.parent = self
        var needsHighlight = false
        if tv.text != text {
            tv.text = text
            needsHighlight = true
        }
        if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
            tv.font = Theme.codeFont(fontSize)
            needsHighlight = true
        }
        if tv.errorLine != errorLine {
            tv.errorLine = errorLine
            needsHighlight = true
        }
        if needsHighlight { context.coordinator.highlight(tv) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        private var pendingHighlight = false

        init(_ parent: CodeEditorView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            scheduleHighlight(tv)
        }

        func highlight(_ tv: UITextView) {
            let selected = tv.selectedRange
            VantaSyntax.highlight(tv.textStorage, font: Theme.codeFont(parent.fontSize))
            if let lineTV = tv as? LineNumberTextView { lineTV.paintErrorLine() }
            tv.selectedRange = selected
            (tv as? LineNumberTextView)?.refreshGutter()
        }

        private func scheduleHighlight(_ tv: UITextView) {
            if pendingHighlight { return }
            pendingHighlight = true
            DispatchQueue.main.async { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.pendingHighlight = false
                self.highlight(tv)
            }
        }

        // Auto-indent: a new line copies the previous line's indentation and
        // goes one level deeper after a block opener (if / while / to / ...).
        func textView(_ tv: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText replacement: String) -> Bool {
            guard replacement == "\n" else { return true }
            let ns = tv.text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let line = ns.substring(with: NSRange(location: lineRange.location,
                                                  length: max(0, range.location - lineRange.location)))
            var indent = String(line.prefix(while: { $0 == " " }))
            let word = line.trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").first ?? ""
            let openers: Set<String> = ["if", "while", "repeat", "for", "to", "type",
                                        "attempt", "match", "otherwise", "rescue", "when"]
            if openers.contains(word) { indent += "    " }
            let insert = "\n" + indent
            if let textRange = tv.selectedTextRange {
                tv.replace(textRange, withText: insert)
            }
            parent.text = tv.text
            scheduleHighlight(tv)
            return false
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? LineNumberTextView)?.refreshGutter()
        }

        // The accessory bar above the keyboard: tab, the symbols Vanta needs,
        // and one-tap keywords.
        func makeAccessoryBar(for tv: UITextView) -> UIView {
            let bar = UIScrollView(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            bar.backgroundColor = UIColor(red: 0.08, green: 0.075, blue: 0.13, alpha: 1)
            bar.showsHorizontalScrollIndicator = false

            let stack = UIStackView()
            stack.axis = .horizontal
            stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bar.contentLayoutGuide.leadingAnchor, constant: 8),
                stack.trailingAnchor.constraint(equalTo: bar.contentLayoutGuide.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: bar.contentLayoutGuide.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: bar.contentLayoutGuide.bottomAnchor, constant: -6),
                stack.heightAnchor.constraint(equalToConstant: 32),
            ])

            let keys: [(String, String)] = [
                ("⇥", "    "), ("\"", "\""), ("{", "{"), ("}", "}"),
                ("[", "["), ("]", "]"), ("(", "("), (")", ")"),
                ("let", "let "), ("be", "be "), ("say", "say "),
                ("if", "if "), ("end", "end"), ("to", "to "),
                ("for each", "for each "), ("give back", "give back "),
                ("+", "+"), ("-", "-"), ("*", "*"), ("/", "/"), ("#", "# "),
            ]
            for (label, insert) in keys {
                let b = UIButton(type: .system)
                b.setTitle(label, for: .normal)
                b.titleLabel?.font = Theme.codeFont(14)
                b.setTitleColor(Theme.uink, for: .normal)
                b.backgroundColor = UIColor(red: 0.13, green: 0.12, blue: 0.2, alpha: 1)
                b.layer.cornerRadius = 7
                b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
                b.addAction(UIAction { [weak tv, weak self] _ in
                    guard let tv else { return }
                    tv.insertText(insert)
                    if let self { self.scheduleHighlight(tv) }
                }, for: .touchUpInside)
                stack.addArrangedSubview(b)
            }

            let dismiss = UIButton(type: .system)
            dismiss.setTitle("⌄", for: .normal)
            dismiss.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
            dismiss.setTitleColor(Theme.uaccent, for: .normal)
            dismiss.addAction(UIAction { [weak tv] _ in tv?.resignFirstResponder() }, for: .touchUpInside)
            stack.addArrangedSubview(dismiss)
            return bar
        }
    }
}

// A UITextView with a line-number gutter drawn in a subview that scrolls
// with the text, plus an optional red-painted error line.
final class LineNumberTextView: UITextView {
    static let gutterWidth: CGFloat = 40
    private let gutter = GutterView()
    var errorLine: Int?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setUpGutter()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpGutter()
    }

    private func setUpGutter() {
        textContainerInset = UIEdgeInsets(top: 14, left: Self.gutterWidth + 6,
                                          bottom: 120, right: 10)
        gutter.textView = self
        gutter.backgroundColor = .clear
        gutter.isUserInteractionEnabled = false
        gutter.contentMode = .redraw
        addSubview(gutter)
    }

    override var text: String! {
        didSet { refreshGutter() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshGutter()
    }

    func refreshGutter() {
        let height = max(contentSize.height, bounds.height) + 200
        let frame = CGRect(x: 0, y: 0, width: Self.gutterWidth, height: height)
        if gutter.frame != frame { gutter.frame = frame }
        gutter.setNeedsDisplay()
    }

    // Paint the failing line's background (called after syntax highlighting,
    // which resets attributes).
    func paintErrorLine() {
        guard let errorLine, errorLine >= 1 else { return }
        let ns = text as NSString
        var index = 0, line = 1
        while index < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            if line == errorLine {
                textStorage.addAttribute(.backgroundColor,
                                         value: UIColor(red: 0.45, green: 0.10, blue: 0.16, alpha: 0.55),
                                         range: lineRange)
                return
            }
            index = NSMaxRange(lineRange)
            line += 1
        }
    }
}

// Draws the line numbers. Lives inside the text view so it scrolls for free;
// wrapped lines get one number at their first fragment.
private final class GutterView: UIView {
    weak var textView: LineNumberTextView?

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let lm = tv.layoutManager
        let inset = tv.textContainerInset
        let font = Theme.codeFont(max(10, (tv.font?.pointSize ?? 15) - 3))
        let numberColor = UIColor(red: 0.36, green: 0.34, blue: 0.50, alpha: 1)
        let errorColor = UIColor(red: 1.0, green: 0.42, blue: 0.5, alpha: 1)

        // subtle gutter panel + separator
        UIColor(red: 0.055, green: 0.052, blue: 0.088, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: rect.minY, width: LineNumberTextView.gutterWidth, height: rect.height))
        UIColor(red: 0.14, green: 0.13, blue: 0.21, alpha: 1).setFill()
        UIRectFill(CGRect(x: LineNumberTextView.gutterWidth - 1, y: rect.minY, width: 1, height: rect.height))

        func drawNumber(_ line: Int, atY y: CGFloat, lineHeight: CGFloat) {
            let str = "\(line)" as NSString
            let color = (line == tv.errorLine) ? errorColor : numberColor
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let size = str.size(withAttributes: attrs)
            str.draw(at: CGPoint(x: LineNumberTextView.gutterWidth - 8 - size.width,
                                 y: y + (lineHeight - size.height) / 2),
                     withAttributes: attrs)
        }

        let ns = (tv.text ?? "") as NSString
        lm.ensureLayout(for: tv.textContainer)
        var index = 0, line = 1
        while index < ns.length && lm.numberOfGlyphs > 0 {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = lm.glyphIndexForCharacter(at: lineRange.location)
            var fragRange = NSRange(location: 0, length: 0)
            let frag = lm.lineFragmentRect(forGlyphAt: min(glyphIndex, max(0, lm.numberOfGlyphs - 1)),
                                           effectiveRange: &fragRange)
            drawNumber(line, atY: frag.minY + inset.top, lineHeight: frag.height)
            index = NSMaxRange(lineRange)
            line += 1
        }
        // the empty last line (or an empty document)
        if ns.length == 0 || ns.hasSuffix("\n") {
            let extra = lm.extraLineFragmentRect
            let height = extra.height > 0 ? extra.height : (tv.font?.lineHeight ?? 18)
            drawNumber(line, atY: extra.minY + inset.top, lineHeight: height)
        }
    }
}
