import AppKit

/// Hidden commands that put the language UI into a visible state for headless
/// `--snapshot … --run language.demo.<name>` checks (never in menus or the palette).
enum LanguageDemos {
    static func register(_ s: Services) {
        func add(_ name: String, _ body: @escaping () -> Void) {
            s.commands.register(id: "language.demo.\(name)", title: "Demo \(name)", category: .help,
                                inMenu: false, inPalette: false) { whenReady(body) }
        }
        add("hover") {
            guard let p = s.editors.activePane, let o = firstMatch(p, #"\blet\s+(\w+)\s+be\b"#, group: 1) else { return }
            // hover a later use of that name if there is one
            let name = (p.text as NSString).substring(with: o)
            let use = firstMatch(p, "\\b\(name)\\b", after: NSMaxRange(o)) ?? o
            hover(p, at: use.location + 1)
        }
        add("hoverFunction") {
            guard let p = s.editors.activePane, let o = firstMatch(p, #"(?m)^to\s+(\w+)"#, group: 1) else { return }
            let name = (p.text as NSString).substring(with: o)
            let use = firstMatch(p, "\\b\(name)\\(", after: NSMaxRange(o)) ?? o
            hover(p, at: use.location + 1)
        }
        add("memberCompletion") {
            guard let p = s.editors.activePane, let r = firstMatch(p, #"\b[a-z_]\w*\.(?=\w)"#) else { return }
            p.textView.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
            p.triggerCompletion(explicit: true)
        }
        add("completion") {
            guard let p = s.editors.activePane else { return }
            let end = (p.text as NSString).length
            p.textView.setSelectedRange(NSRange(location: end, length: 0))
            for ch in "\nsay ad" { p.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        add("signature") {
            guard let p = s.editors.activePane, let r = firstMatch(p, #"(?m)^to\s+(\w+)\(\w"#, group: 1) else { return }
            let name = (p.text as NSString).substring(with: r)
            let end = (p.text as NSString).length
            p.textView.setSelectedRange(NSRange(location: end, length: 0))
            for ch in "\nsay \(name)(1, " {
                p.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        add("rename") {
            guard let p = s.editors.activePane, let r = firstMatch(p, #"(?m)^to\s+(\w+)"#, group: 1) else { return }
            let name = (p.text as NSString).substring(with: r)
            p.textView.setSelectedRange(NSRange(location: r.location + 1, length: 0))
            RenameModel.shared.begin(newName: name + "_numbers")
        }
        add("references") {
            guard let p = s.editors.activePane, let r = firstMatch(p, #"(?m)^to\s+(\w+)"#, group: 1) else { return }
            p.textView.setSelectedRange(NSRange(location: r.location + 1, length: 0))
            ReferencesModel.shared.findAtCursor()
        }
        add("runTests") {
            s.layout.showSidebar(PanelID.tests)
            s.layout.showBottom(PanelID.testResults)
            TestModel.shared.run(.all)
        }
        add("problems") { s.layout.showBottom(PanelID.problems) }
        add("outline") { s.layout.showSidebar(PanelID.outline) }
    }

    /// Wait for the language server (and a first round of diagnostics) before acting.
    static func whenReady(_ body: @escaping () -> Void) {
        let svc = LanguageService.shared
        let deadline = Date().addingTimeInterval(8)
        func poll() {
            if svc.state == .ready || Date() > deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { body() }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
    }

    static func firstMatch(_ p: EditorPane, _ pattern: String, group: Int = 0, after: Int = 0) -> NSRange? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = p.text as NSString
        guard after < ns.length,
              let m = re.firstMatch(in: p.text, range: NSRange(location: after, length: ns.length - after)) else { return nil }
        return m.range(at: group)
    }

    static func hover(_ p: EditorPane, at offset: Int) {
        p.scrollToLine(p.position(of: offset).line, select: false)
        let r = p.caretRect(at: offset)
        p.mouseMoved(to: NSPoint(x: r.minX + 4, y: r.midY))
    }
}
