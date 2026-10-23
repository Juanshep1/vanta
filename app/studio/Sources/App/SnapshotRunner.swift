import AppKit
import SwiftUI

/// Headless test hook:
///
///     VantaStudio --snapshot out.png [--workspace DIR] [--open FILE]… [--size 1440x900]
///                 [--appearance dark|light] [--run COMMAND_ID]… [--line N] [--settle SECONDS]
///     VantaStudio --bench FILE        (times highlighting / layout of a big file, prints ms)
///
/// Builds the main window's view in a window that is never ordered on screen,
/// renders it with cacheDisplay, writes a PNG and exits. Nothing is persisted.
enum SnapshotRunner {
    static func run(_ args: [String]) {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        func values(_ flag: String) -> [String] {
            var out: [String] = []
            for (i, a) in args.enumerated() where a == flag && i + 1 < args.count { out.append(args[i + 1]) }
            return out
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let s = Services.shared
        s.isSnapshot = true
        s.settings.persist = false
        s.layout.applyDefaults()
        if let a = value("--appearance") { s.settings.prefs.appearance = a == "light" ? .light : .dark }

        if let bench = value("--bench") { runBench(URL(fileURLWithPath: bench)); exit(0) }
        if args.contains("--selftest") { exit(selfTest() ? 0 : 1) }

        guard let out = value("--snapshot") else { print("usage: --snapshot out.png"); exit(2) }
        var size = NSSize(width: 1440, height: 900)
        if let sz = value("--size") {
            let p = sz.lowercased().split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { size = NSSize(width: p[0], height: p[1]) }
        }
        let ws = value("--workspace").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let files = values("--open").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        Bootstrap.start(workspace: ws, files: files, restoreLast: false)
        if let first = files.last { s.editors.open(first, focus: true) }

        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = s.settings.nsAppearance ?? NSAppearance(named: .darkAqua)
        let host: NSView = args.contains("--settings")
            ? NSHostingView(rootView: SettingsView().frame(width: size.width, height: size.height))
            : NSHostingView(rootView: MainWindowView())
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        // never orderFront / makeKey: the window stays off screen

        let settle = Double(value("--settle") ?? "") ?? 1.0
        spin(0.4)
        if let pane = s.editors.activePane { window.makeFirstResponder(pane.textView) }
        if let l = value("--line").flatMap(Int.init), let ed = s.editor { ed.scrollToLine(max(0, l - 1), select: true) }
        for d in values("--demo") { demo(d); spin(0.2) }
        for cmd in values("--run") {
            s.commands.run(cmd)
            spin(0.25)
        }
        spin(settle)
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { print("no bitmap"); exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { print("png failed"); exit(1) }
        do {
            try png.write(to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
            print("wrote \(out) (\(Int(size.width))x\(Int(size.height)))")
        } catch {
            print("write failed: \(error)"); exit(1)
        }
        exit(0)
    }

    /// Exercise editor decorations for visual checks.
    static func demo(_ name: String) {
        guard let ed = Services.shared.editors.activePane else { return }
        let lines = ed.document.lines
        switch name {
        case "decorations":
            let n = lines.count
            ed.setDiagnostics([
                Diagnostic(range: TextRange(start: TextPosition(line: min(4, n - 1), column: 4), end: TextPosition(line: min(4, n - 1), column: 9)),
                           severity: .error, message: "Unknown name `greet`", source: "demo"),
                Diagnostic(line: min(7, n - 1), severity: .warning, message: "Unused variable", source: "demo"),
            ])
            ed.breakpoints = [min(9, n - 1), min(12, n - 1)]
            ed.highlightLine(min(12, n - 1))
            ed.scrollToLine(0, select: false)
            let l = min(17, n - 1)
            let end = NSMaxRange(lines.contentRange(of: l, in: ed.text as NSString))
            ed.textView.setSelectedRange(NSRange(location: end, length: 0))
            ed.setGhostText("\nsay \"ghost line two\"\nsay \"and three\"", at: end)
        case "fold":
            if let b = ed.document.blocks.first(where: { $0.end > $0.start + 1 }) { ed.toggleFold(atLine: b.start) }
        case "diff":
            if let b = ed.document.blocks.first(where: { $0.end > $0.start + 1 }) {
                let s = lines.start(of: b.start), e = NSMaxRange(lines.range(of: b.end))
                let old = (ed.text as NSString).substring(with: NSRange(location: s, length: e - s))
                var new = old.replacingOccurrences(of: "give back", with: "return")
                new = "# rewritten by Vee\n" + new
                ed.showInlineDiff(range: NSRange(location: s, length: e - s), newText: new, onAccept: {}, onReject: {})
            }
        case "multicursor":
            ed.textView.setSelectedRange(NSRange(location: lines.start(of: 4), length: 3))
            ed.selectNextOccurrence(); ed.selectNextOccurrence()
            ed.addCursor(1)
        case "completion":
            let l = min(5, lines.count - 1)
            let end = NSMaxRange(lines.contentRange(of: l, in: ed.text as NSString))
            ed.textView.setSelectedRange(NSRange(location: end, length: 0))
            ed.textView.insertNewline(nil)
            for ch in ["s", "q"] { ed.textView.insertText(ch, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        case "find":
            ed.find.query = "say"
            ed.showFind(replace: true)
        default: break
        }
    }

    static func spin(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    /// Headless checks of editing behaviour. Prints PASS/FAIL per case.
    static func selfTest() -> Bool {
        Modules.registerAll()
        var ok = true
        func make(_ text: String) -> EditorPane {
            let d = Document(url: nil, name: "t.va", text: text)
            let p = EditorPane(document: d)
            p.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            w.contentView = p
            w.makeFirstResponder(p.textView)
            return p
        }
        func check(_ name: String, _ got: String, _ want: String) {
            if got == want { print("PASS  \(name)") } else {
                ok = false
                print("FAIL  \(name)\n  got:  \(got.debugDescription)\n  want: \(want.debugDescription)")
            }
        }
        func type(_ p: EditorPane, _ s: String) {
            for ch in s {
                if ch == "\n" { p.textView.insertNewline(nil) }
                else { p.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
        }
        StudioSettings.shared.prefs.autoCloseBrackets = true

        var p = make("")
        type(p, "to f(x)\nsay x\nend")
        check("indent after `to`, dedent on `end`", p.text, "to f(x)\n    say x\nend")

        p = make("")
        type(p, "if a\nsay 1\notherwise\nsay 2\nend")
        check("otherwise dedents", p.text, "if a\n    say 1\notherwise\n    say 2\nend")

        p = make("")
        type(p, "match x\nwhen 1\nsay 1\nend")
        check("match/when indentation", p.text, "match x\n    when 1\n        say 1\nend")

        p = make("")
        type(p, "say (\"hi")
        check("auto-close brackets and quotes", p.text, "say (\"hi\")")
        type(p, "\")")
        check("over-type closers", p.text, "say (\"hi\")")

        p = make("let a be 1\nlet b be 2\n")
        p.textView.setSelectedRange(NSRange(location: 0, length: 15))
        p.toggleComment()
        check("toggle comment on", p.text, "# let a be 1\n# let b be 2\n")
        p.toggleComment()
        check("toggle comment off", p.text, "let a be 1\nlet b be 2\n")

        p = make("one\ntwo\nthree\n")
        p.textView.setSelectedRange(NSRange(location: 5, length: 0))
        p.moveLines(-1)
        check("move line up", p.text, "two\none\nthree\n")
        p.moveLines(1); p.moveLines(1)
        check("move line down twice", p.text, "one\nthree\ntwo\n")
        p.duplicateLines()
        check("duplicate line", p.text, "one\nthree\ntwo\ntwo\n")

        p = make("x = 1\nx = 2\nx = 3\n")
        p.textView.setSelectedRange(NSRange(location: 0, length: 1))
        p.selectNextOccurrence(); p.selectNextOccurrence()
        type(p, "y")
        check("⌘D ×2 then type at 3 cursors", p.text, "y = 1\ny = 2\ny = 3\n")
        p.textView.undoManager?.undo()
        check("multi-cursor edit undoes in one step", p.text, "x = 1\nx = 2\nx = 3\n")

        p = make("ab\ncd\n")
        p.textView.setAllRanges([NSRange(location: 2, length: 0), NSRange(location: 5, length: 0)])
        p.textView.deleteBackward(nil)
        check("backspace at 2 carets", p.text, "a\nc\n")

        p = make("    say 1\n")
        p.textView.setSelectedRange(NSRange(location: 0, length: 9))
        p.indentLines(by: -1)
        check("outdent", p.text, "say 1\n")
        p.indentLines(by: 1)
        check("indent", p.text, "    say 1\n")

        p = make("to f()\n    say 1\n    say 2\nend\nsay 3\n")
        p.toggleFold(atLine: 0)
        check("fold hides block lines", "\(p.folds.count) \(p.isHidden(p.document.lines.start(of: 1)))", "1 true")
        p.textView.setSelectedRange(NSRange(location: p.text.utf16.count, length: 0))
        type(p, "x")
        check("edit after fold keeps fold", "\(p.folds.count)", "1")

        p = make("say 1\nsay 2\n")
        p.showInlineDiff(range: NSRange(location: 0, length: 6), newText: "say 100\n", onAccept: {}, onReject: {})
        p.acceptInlineDiff()
        check("inline diff accept", p.text, "say 100\nsay 2\n")
        p.textView.undoManager?.undo()
        check("inline diff undo", p.text, "say 1\nsay 2\n")

        p = make("say 1\n")
        p.setGhostText(" + 1", at: 5)
        _ = p.acceptGhost()
        check("ghost text accept", p.text, "say 1 + 1\n")

        let syms = RegexSymbolProvider.parse("type A\n    to m()\n    end\nend\nto f(x)\nend\nlet k be 1\ntest \"t\"\nend\n")
        check("symbols", syms.map { "\($0.kind.rawValue):\($0.name)\($0.children.map { "/" + $0.name }.joined())" }.joined(separator: ","),
              "type:A/m,function:f,variable:k,test:t")
        if !LanguageSelfTest.run() { ok = false }     // Language/: LSP, completion, rename, tests…
        print(ok ? "ALL PASS" : "SOME FAILED")
        return ok
    }

    /// Performance check for big files: load + highlight + edits.
    static func runBench(_ url: URL) {
        Modules.registerAll()
        func ms(_ t: Date) -> String { String(format: "%.1f ms", Date().timeIntervalSince(t) * 1000) }
        var t = Date()
        guard let doc = Document.load(url) else { print("can't read \(url.path)"); return }
        print("load+highlight \(doc.lines.count) lines: \(ms(t))")
        let pane = EditorPane(document: doc)
        pane.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        t = Date()
        pane.layoutSubtreeIfNeeded()
        pane.scrollToLine(doc.lines.count / 2, select: true)
        pane.textView.display()
        print("first layout+draw (middle of file): \(ms(t))")
        // typing in the middle: 200 single-character edits
        t = Date()
        let mid = doc.lines.start(of: doc.lines.count / 2)
        for i in 0..<200 {
            pane.textView.setSelectedRange(NSRange(location: mid + i, length: 0))
            pane.textView.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        print("200 keystrokes (incremental highlight): \(ms(t)) total, \(String(format: "%.2f", Date().timeIntervalSince(t) * 5)) ms each")
        t = Date()
        pane.textView.insertText("\"\"\"", replacementRange: NSRange(location: mid, length: 0))
        print("open a triple-quote (re-highlights the rest): \(ms(t))")
        t = Date()
        _ = doc.blocks
        print("block analysis: \(ms(t)) (\(doc.blocks.count) blocks)")
        t = Date()
        pane.gutter.display()
        pane.textView.display()
        print("redraw gutter + text: \(ms(t))")
    }
}
