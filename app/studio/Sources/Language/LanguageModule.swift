import SwiftUI
import Combine

/// Language features for Vanta 6.0, backed by the real tools in the bundled runtime:
/// `vanta lsp` (diagnostics, completion, hover, definition, references, rename,
/// signature help, symbols, quick fixes, formatting) and `vanta test --json`.
/// The Phase-1 providers below stay as fallbacks for when python isn't available.
enum LanguageModule {
    static let formatOnSaveKey = "vanta-studio.formatOnSave"
    static var formatOnSave: Bool {
        get { UserDefaults.standard.bool(forKey: formatOnSaveKey) }
        set { if !Services.shared.isSnapshot { UserDefaults.standard.set(newValue, forKey: formatOnSaveKey) } }
    }

    static func register(_ s: Services) {
        let svc = LanguageService.shared
        s.register(svc)
        s.register(TestModel.shared)

        // providers
        s.language.symbolProvider = LSPSymbolProvider()
        s.language.formattingProvider = VantaFormatter()
        s.language.removeCompletionProvider(id: "keywords")
        s.language.register(completion: LSPCompletionProvider())
        s.language.register(hover: LSPHoverProvider())
        s.language.register(definition: LSPDefinitionProvider())

        // panels
        s.panels.register(id: PanelID.tests, title: "Testing", icon: "checkmark.seal", location: .sidebar, order: 50,
                          badge: { let n = TestModel.shared.failedCount; return n > 0 ? "\(n)" : nil }) { TestsSidebar() }
        s.panels.register(id: PanelID.testResults, title: "Tests", icon: "checkmark.seal", location: .bottom, order: 30,
                          badge: { let n = TestModel.shared.failedCount; return n > 0 ? "\(n)" : nil }) { TestResultsPanel() }
        s.panels.register(id: ReferencesModel.panelID, title: "References", icon: "arrow.triangle.branch", location: .bottom, order: 25,
                          badge: { let n = ReferencesModel.shared.count; return n > 0 ? "\(n)" : nil }) { ReferencesPanel() }
        s.panels.register(id: PanelID.problems, title: "Problems", icon: "exclamationmark.triangle", location: .bottom, order: 20,
                          badge: { let n = s.diagnostics.errorCount + s.diagnostics.warningCount; return n > 0 ? "\(n)" : nil }) {
            LanguageProblemsView()
        }
        s.panels.registerOverlay(id: "language.rename") { RenameOverlay() }
        s.panels.registerSettingsSection(id: "settings.language", title: "Language", icon: "curlybraces", order: 40) {
            LanguageSettingsView()
        }
        s.statusBar.register(id: "status.tests", alignment: .left, priority: 70) { TestsStatusItem() }
        s.statusBar.register(id: "status.lsp", alignment: .right, priority: 40) { LanguageServerStatus() }

        registerCommands(s)

        // services start once the app has finished registering everything
        DispatchQueue.main.async {
            svc.start(s)
            TestModel.shared.start(s)
            SignatureHelpController.shared.start(s)
            s.activeEditorChanged.receive(on: DispatchQueue.main).sink { _ in attachGutters(s) }.store(in: &bag)
            attachGutters(s)
        }
    }

    private static var bag = Set<AnyCancellable>()

    static func attachGutters(_ s: Services) {
        for g in s.editors.groups {
            for t in g.tabs { if let p = g.existingPane(for: t.document) { TestGutterOverlay.attach(to: p) } }
        }
        if let p = s.editors.activePane { TestGutterOverlay.attach(to: p) }
    }

    private static func registerCommands(_ s: Services) {
        let c = s.commands
        func vantaEditor() -> Bool { s.editor?.document.language == .vanta }

        c.register(id: "editor.findReferences", title: "Find All References", category: .go,
                   shortcut: KeyShortcut("f12", [.shift]), group: 1, order: 1, editorKey: true, isEnabled: vantaEditor) {
            ReferencesModel.shared.findAtCursor()
        }
        c.register(id: "editor.rename", title: "Rename Symbol", category: .edit, shortcut: KeyShortcut("f2", []),
                   group: 10, order: 4, editorKey: true, isEnabled: vantaEditor) { RenameModel.shared.begin() }
        c.register(id: "editor.quickFix", title: "Quick Fix…", category: .edit, shortcut: KeyShortcut("return", [.opt]),
                   group: 10, order: 5, editorKey: true, isEnabled: vantaEditor) { QuickFixes.atCursor() }
        c.register(id: "editor.signatureHelp", title: "Show Parameter Hints", category: .edit,
                   shortcut: KeyShortcut("space", [.cmd, .shift]), group: 40, order: 1, editorKey: true,
                   isEnabled: vantaEditor) { SignatureHelpController.shared.trigger() }
        c.register(id: "editor.nextReference", title: "Next Reference", category: .go, inMenu: false, group: 1, order: 2) {
            ReferencesModel.shared.step(1)
        }
        c.register(id: "editor.toggleFormatOnSave", title: "Toggle Format on Save", category: .edit, group: 10, order: 6) {
            formatOnSave.toggle()
            s.flash("Format on save is \(formatOnSave ? "on" : "off")")
        }
        c.register(id: "language.restartServer", title: "Restart Vanta Language Server", category: .view, inMenu: false) {
            LanguageService.shared.restart()
        }

        // format on save: wrap the shell's Save
        if let save = c.command("file.save") {
            let original = save.action
            c.register(id: save.id, title: save.title, category: save.category, shortcut: save.shortcut, inMenu: save.inMenu,
                       inPalette: save.inPalette, group: save.group, order: save.order, editorKey: save.editorKey,
                       isEnabled: save.isEnabled) {
                guard formatOnSave, let ed = s.editor, ed.document.language == .vanta,
                      let f = s.language.formattingProvider else { original(); return }
                let text = ed.text, uri = ed.document.uri, doc = ed.document
                var done = false
                func finish() { guard !done else { return }; done = true; original() }
                Task {
                    let out = await f.format(text: text, uri: uri)
                    await MainActor.run {
                        if let out, doc.text == text, s.editor?.document === doc { s.editor?.setText(out) }
                        finish()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }     // never hold a save hostage
            }
        }

        // Test menu
        let t = TestModel.shared
        c.register(id: "test.runAll", title: "Run All Tests", category: .test, group: 0, order: 0,
                   isEnabled: { !t.running }) { t.run(.all) }
        c.register(id: "test.runFile", title: "Run Tests in Current File", category: .test, group: 0, order: 1,
                   isEnabled: { !t.running && s.editor?.url != nil && vantaEditor() }) {
            if let u = s.editor?.url { if s.editor?.document.isDirty == true { s.editor?.document.save() }; t.run(.file(u)) }
        }
        c.register(id: "test.runAtCursor", title: "Run Test at Cursor", category: .test, group: 0, order: 2,
                   isEnabled: { !t.running && vantaEditor() }) {
            if let tc = t.testAtCursor() { t.run(.test(tc.file, tc.name)) } else { s.flash("The cursor isn't inside a test block") }
        }
        c.register(id: "test.rerunFailed", title: "Run Failed Tests", category: .test, group: 0, order: 3,
                   isEnabled: { !t.running }) { t.run(.failed) }
        c.register(id: "test.stop", title: "Stop Tests", category: .test, group: 1, order: 0,
                   isEnabled: { t.running }) { t.stop() }
        c.register(id: "test.showResults", title: "Show Test Results", category: .test, group: 2, order: 0) {
            s.layout.showBottom(PanelID.testResults)
        }
        c.register(id: "test.showSidebar", title: "Show Testing", category: .test, group: 2, order: 1) {
            s.layout.showSidebar(PanelID.tests)
        }
        LanguageDemos.register(s)
    }
}

struct LanguageServerStatus: View {
    @ObservedObject var svc = LanguageService.shared
    var body: some View {
        switch svc.state {
        case .starting:
            StatusLabel(icon: "hourglass", text: "Vanta LSP", help: "Starting the Vanta language server…")
        case .failed(let why):
            StatusLabel(icon: "exclamationmark.triangle", text: "Vanta LSP", color: Theme.amber,
                        help: "\(why) — click to restart", action: { svc.restart() })
        default:
            EmptyView()
        }
    }
}

struct LanguageSettingsView: View {
    @State private var formatOnSave = LanguageModule.formatOnSave
    @ObservedObject var svc = LanguageService.shared

    var body: some View {
        Form {
            Section("Formatting") {
                Toggle("Format Vanta files on save (vanta fmt)", isOn: $formatOnSave)
                    .onChange(of: formatOnSave) { _, v in LanguageModule.formatOnSave = v }
                Text("⌥⇧F formats the current file at any time.").font(.caption).foregroundColor(Theme.muted)
            }
            Section("Language server") {
                HStack {
                    Text(statusText)
                    Spacer()
                    Button("Restart") { svc.restart() }
                }
                Text("Diagnostics, completion, hover, go to definition (F12), references (⇧F12), rename (F2), quick fixes (⌥↩) and parameter hints come from `vanta lsp` in the bundled runtime.")
                    .font(.caption).foregroundColor(Theme.muted)
            }
        }
        .formStyle(.grouped)
    }

    var statusText: String {
        switch svc.state {
        case .ready: return "Running"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let w): return "Not running: \(w)"
        }
    }
}

/// Top-level declarations: `to name(…)`, `type Name`, `kind Name`, `test "…"`,
/// `let`/`fix` at column 0, plus methods nested in types.
final class RegexSymbolProvider: SymbolProvider {
    let id = "regex-symbols"
    private static let re = try! NSRegularExpression(pattern:
        #"^([ \t]*)(?:(?:private|shared)[ \t]+)?(?:(to)[ \t]+([A-Za-z_]\w*)[ \t]*(\([^)\n]*\))?|(type)[ \t]+([A-Za-z_]\w*)(?:[ \t]+from[ \t]+([A-Za-z_]\w*))?|(kind)[ \t]+([A-Za-z_]\w*)|(test)[ \t]+"([^"\n]*)"|(let|fix)[ \t]+([A-Za-z_]\w*)[ \t]+be\b)"#,
        options: [.anchorsMatchLines])

    func symbols(text: String, uri: URL) async -> [DocumentSymbol] { Self.parse(text) }

    static func parse(_ text: String) -> [DocumentSymbol] {
        let ns = text as NSString
        var lines = LineIndex()
        lines.rebuild(ns)
        let blocks = BlockStructure.analyze(ns, lines: lines) { _ in false }
        let endOf = Dictionary(blocks.map { ($0.start, $0.end) }, uniquingKeysWith: { a, _ in a })
        var top: [DocumentSymbol] = []
        var openType: (index: Int, end: Int)?
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let line = lines.line(at: m.range.location)
            let indent = (g(m, 1) ?? "").count
            if let t = openType, line > t.end { openType = nil }
            var sym: DocumentSymbol?
            if g(m, 2) != nil, let name = g(m, 3) {
                sym = DocumentSymbol(name: name, kind: openType != nil && indent > 0 ? .method : .function,
                                     detail: g(m, 4) ?? "", line: line, endLine: endOf[line])
            } else if g(m, 5) != nil, let name = g(m, 6) {
                sym = DocumentSymbol(name: name, kind: .type, detail: g(m, 7).map { "from \($0)" } ?? "", line: line, endLine: endOf[line])
            } else if g(m, 8) != nil, let name = g(m, 9) {
                sym = DocumentSymbol(name: name, kind: .kind, line: line, endLine: endOf[line])
            } else if g(m, 10) != nil, let name = g(m, 11) {
                sym = DocumentSymbol(name: name, kind: .test, line: line, endLine: endOf[line])
            } else if let kw = g(m, 12), let name = g(m, 13), indent == 0 {
                sym = DocumentSymbol(name: name, kind: kw == "fix" ? .constant : .variable, line: line)
            }
            guard let s = sym else { return }
            if let t = openType, indent > 0, s.kind == .method {
                top[t.index].children.append(s)
            } else if indent == 0 || openType == nil {
                if indent > 0 && s.kind == .variable { return }
                top.append(s)
                if s.kind == .type, let e = s.endLine { openType = (top.count - 1, e) }
            }
        }
        return top
    }
}

/// Keywords, builtins, snippets and identifiers from the current file.
final class KeywordCompletionProvider: CompletionProvider {
    let id = "keywords"
    let triggerCharacters: Set<Character> = []

    private static let snippets: [CompletionItem] = [
        CompletionItem(label: "to", kind: .snippet, detail: "function", insertText: "to $0()\n    \nend", sortPriority: 3),
        CompletionItem(label: "if", kind: .snippet, detail: "if … end", insertText: "if $0\n    \nend", sortPriority: 3),
        CompletionItem(label: "for each", kind: .snippet, detail: "loop", insertText: "for each $0 in \n    \nend", sortPriority: 3),
        CompletionItem(label: "repeat", kind: .snippet, detail: "repeat N times", insertText: "repeat $0 times\n    \nend", sortPriority: 3),
        CompletionItem(label: "while", kind: .snippet, detail: "loop", insertText: "while $0\n    \nend", sortPriority: 3),
        CompletionItem(label: "type", kind: .snippet, detail: "type … end", insertText: "type $0\n    has \nend", sortPriority: 3),
        CompletionItem(label: "attempt", kind: .snippet, detail: "attempt / rescue", insertText: "attempt\n    $0\nrescue e\n    say e\nend", sortPriority: 3),
        CompletionItem(label: "match", kind: .snippet, detail: "match / when", insertText: "match $0\n    when \n        \n    otherwise\n        \nend", sortPriority: 3),
        CompletionItem(label: "test", kind: .snippet, detail: "test \"…\"", insertText: "test \"$0\"\n    expect \nend", sortPriority: 3),
    ]

    func completions(_ ctx: DocumentContext, prefix: String) async -> [CompletionItem] {
        var out: [CompletionItem] = []
        guard ctx.languageID == LanguageID.vanta.rawValue else { return [] }
        out += Self.snippets
        for k in VantaLexer.keywords { out.append(CompletionItem(label: k, kind: .keyword, sortPriority: 2)) }
        for k in VantaLexer.constants where k.first?.isLowercase == true { out.append(CompletionItem(label: k, kind: .constant, sortPriority: 1)) }
        for b in VantaLexer.builtins { out.append(CompletionItem(label: b, kind: .function, detail: "builtin", insertText: b + "($0)")) }
        // identifiers in this file
        let ns = ctx.text as NSString
        var words = Set<String>()
        let symbols = RegexSymbolProvider.parse(ctx.text)
        func flat(_ s: [DocumentSymbol]) -> [DocumentSymbol] { s.flatMap { [$0] + flat($0.children) } }
        for s in flat(symbols) {
            words.insert(s.name)
            let kind: CompletionKind = s.kind == .type || s.kind == .kind ? .type : (s.kind == .function || s.kind == .method ? .function : .variable)
            out.append(CompletionItem(label: s.name, kind: kind, detail: "line \(s.line + 1)",
                                      insertText: kind == .function ? s.name + "($0)" : nil, sortPriority: 4))
        }
        if let re = try? NSRegularExpression(pattern: "\\b[A-Za-z_][A-Za-z0-9_]{2,}\\b") {
            re.enumerateMatches(in: ctx.text, range: NSRange(location: 0, length: min(ns.length, 400_000))) { m, _, stop in
                guard let m else { return }
                if NSMaxRange(m.range) == ctx.offset { return }        // the word being typed
                words.insert(ns.substring(with: m.range))
                if words.count > 3000 { stop.pointee = true }
            }
        }
        let known = Set(out.map(\.label))
        for w in words where !known.contains(w) { out.append(CompletionItem(label: w, kind: .text)) }
        return out
    }
}
