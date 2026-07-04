import SwiftUI
import UIKit

// The code editor: a UITextView tuned for writing code on a phone —
// no autocorrect, live syntax highlighting, auto-indent, and a keyboard
// accessory bar with the characters and keywords Vanta uses most.
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 15

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
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
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 10, bottom: 120, right: 10)
        tv.delegate = context.coordinator
        tv.inputAccessoryView = context.coordinator.makeAccessoryBar(for: tv)
        tv.text = text
        context.coordinator.highlight(tv)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text {
            tv.text = text
            context.coordinator.highlight(tv)
        }
        if let font = tv.font, abs(font.pointSize - fontSize) > 0.5 {
            tv.font = Theme.codeFont(fontSize)
            context.coordinator.highlight(tv)
        }
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
            tv.selectedRange = selected
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
