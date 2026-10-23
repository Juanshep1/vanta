import AppKit

/// Headless checks of the language features against the real `vanta lsp` and
/// `vanta test` (run by `--selftest`). Builds a small two-file workspace in a temp
/// folder, opens it, and exercises every feature end to end.
enum LanguageSelfTest {
    static let geo = """
    ## Area of a circle.
    to area(r: number) -> number
        give back pi * r * r
    end

    type Circle
        has radius: number
        to grow(by_amount)
            change me.radius to me.radius + by_amount
        end
    end

    """
    static let main = """
    import "geo" as g
    from "geo" use area

    to add(a: number, b: number) -> number
        let s be a + b
        let unused be 3
        give back s
    end

    let c be new g.Circle(2)
    c.grow(1)
    say area(2) + add(1, 2)
    say lenght("x")
    let total be add(1, 2)
    say total

    """
    static let tests = """
    to double(x)
        give back x * 2
    end

    test "doubles"
        expect double(2) is 4
    end

    test "fails on purpose"
        say "debug output"
        expect double(2) is 5
    end

    """

    static func run() -> Bool {
        let s = Services.shared
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
            if cond { print("PASS  lang: \(name)") } else { ok = false; print("FAIL  lang: \(name)  \(detail())") }
        }
        func spin(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        }
        func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if cond() { return true }
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return cond()
        }
        func await_<T>(_ timeout: Double = 15, _ body: @escaping () async -> T) -> T? {
            var out: T?
            Task { let v = await body(); await MainActor.run { out = v } }
            _ = wait(timeout) { out != nil }
            return out
        }

        // pure: snippet conversion
        check("snippet → editor text", LSPCompletionProvider.snippetToEditor("to ${1:name}(${2})\n    $0\nend") == "to $0name()\n    \nend",
              LSPCompletionProvider.snippetToEditor("to ${1:name}(${2})\n    $0\nend"))
        check("test discovery regex", TestModel.tests(in: tests).map(\.0) == ["doubles", "fails on purpose"])

        // workspace
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-lang-selftest-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let geoURL = dir.appendingPathComponent("geo.va"), mainURL = dir.appendingPathComponent("main.va")
        let testURL = dir.appendingPathComponent("math_test.va")
        try? geo.write(to: geoURL, atomically: true, encoding: .utf8)
        try? main.write(to: mainURL, atomically: true, encoding: .utf8)
        try? tests.write(to: testURL, atomically: true, encoding: .utf8)
        s.workspace.open(dir)
        spin(0.2)
        guard wait(15, { LanguageService.shared.state == .ready }) else {
            check("language server starts", false, "\(LanguageService.shared.state)")
            return false
        }
        check("language server starts", true)

        guard let doc = s.documents.open(mainURL) else { check("open main.va", false); return false }
        let uri = doc.uri
        _ = wait(10) { s.diagnostics.diagnostics(for: uri).contains { $0.source == "vanta check" } }
        let diags = s.diagnostics.diagnostics(for: uri)
        let typo = diags.first { $0.message.contains("lenght") }
        check("diagnostic for a typo, exact range", typo?.range == TextRange(start: TextPosition(line: 12, column: 4), end: TextPosition(line: 12, column: 10)),
              "\(diags.map { "\($0.range) \($0.message)" })")
        check("unused-variable warning", diags.contains { $0.severity == .warning && $0.message == "'unused' is never used" })

        func ctx(_ line: Int, _ col: Int) -> DocumentContext {
            let ns = doc.text as NSString
            var li = LineIndex(); li.rebuild(ns)
            let p = TextPosition(line: line, column: col)
            return DocumentContext(uri: uri, text: doc.text, languageID: "vanta", offset: li.offset(of: p), position: p)
        }

        // completion: members of an instance of an imported type
        let members = await_ { await LSPCompletionProvider().completions(ctx(10, 2), prefix: "") } ?? []
        check("member completion after `c.`", members.map(\.label) == ["radius", "grow"], "\(members.map(\.label))")
        let general = await_ { await LSPCompletionProvider().completions(ctx(4, 14), prefix: "") } ?? []
        check("scope completion has params, builtins, snippets",
              ["a", "b", "length", "for each"].allSatisfy { l in general.contains { $0.label == l } } &&
              general.first { $0.label == "length" }?.documentation?.isEmpty == false)

        // hover with inferred type, doc comments across files
        let h1 = await_ { await LanguageService.shared.hover(ctx(14, 5)) } ?? nil
        check("hover shows inferred type", h1?.contains("let total: number") == true, h1 ?? "nil")
        let h2 = await_ { await LanguageService.shared.hover(ctx(11, 5)) } ?? nil
        check("hover shows signature + doc from another file",
              h2?.contains("to area(r: number) -> number") == true && h2?.contains("Area of a circle.") == true, h2 ?? "nil")

        // definition across files
        let def = await_ { await LanguageService.shared.definition(ctx(10, 3)) } ?? []
        check("go to definition into the imported file",
              def.first?.uri.lastPathComponent == "geo.va" && def.first?.range.start.line == 7, "\(def)")

        // references across files
        let refs = await_ { await LanguageService.shared.references(uri: uri, text: doc.text, position: TextPosition(line: 3, column: 4)) } ?? []
        check("find all references", refs.count == 3, "\(refs.map { "\($0.uri.lastPathComponent):\($0.range.start.line)" })")
        let refsArea = await_ { await LanguageService.shared.references(uri: uri, text: doc.text, position: TextPosition(line: 11, column: 5)) } ?? []
        check("references across files", Set(refsArea.map(\.uri.lastPathComponent)) == ["geo.va", "main.va"], "\(refsArea)")

        // signature help
        let sig = await_ { await LanguageService.shared.signatureHelp(uri: uri, text: doc.text, position: TextPosition(line: 11, column: 21)) } ?? nil
        check("signature help + active parameter", sig?.label.hasPrefix("add(a: number, b: number)") == true && sig?.active == 1,
              "\(String(describing: sig))")

        // symbols
        let syms = await_ { await LSPSymbolProvider().symbols(text: geo, uri: geoURL) } ?? []
        check("symbol tree", syms.map { "\($0.kind.rawValue):\($0.name)\($0.children.map { "/" + $0.name }.joined())" }
            .joined(separator: ",") == "function:area,type:Circle/radius/grow",
              syms.map { "\($0.kind.rawValue):\($0.name)" }.joined(separator: ","))

        // quick fix
        let fixes = await_ { await LanguageService.shared.quickFixes(uri: uri, text: doc.text, range: TextRange.line(12)) } ?? []
        check("quick fix offered", fixes.first?.title == "Change to 'length'", "\(fixes.map(\.title))")
        if let f = fixes.first { LanguageService.shared.apply(f.edits) }
        check("quick fix applied", doc.text.contains("say length(\"x\")"))

        // rename across files (geo.va isn't open: rewritten on disk)
        let ren = await_ { await LanguageService.shared.rename(uri: uri, text: doc.text, position: TextPosition(line: 11, column: 5), to: "circle_area") }
        if case .success(let edits)? = ren {
            check("rename edits both files", Set(edits.keys.map(\.lastPathComponent)) == ["geo.va", "main.va"], "\(edits.keys)")
            LanguageService.shared.apply(edits)
            let onDisk = (try? String(contentsOf: geoURL, encoding: .utf8)) ?? ""
            check("rename applied", onDisk.contains("to circle_area(") && doc.text.contains("from \"geo\" use circle_area") &&
                  doc.text.contains("say circle_area(2)"))
        } else {
            check("rename edits both files", false, "\(String(describing: ren))")
        }
        let bad = await_ { await LanguageService.shared.rename(uri: uri, text: doc.text, position: TextPosition(line: 3, column: 4), to: "total") }
        if case .failure(let e)? = bad { check("rename refuses a clash", e.message.contains("already exists"), e.message) }
        else { check("rename refuses a clash", false) }

        // formatting
        let messy = "to f(x)\nsay x+1\nend\n"
        let formatted = await_ { await VantaFormatter().format(text: messy, uri: uri) } ?? nil
        check("format document", formatted == "to f(x)\n    say x + 1\nend\n", formatted ?? "nil")

        // tests: discovery + run with results, timings and failure lines
        let model = TestModel.shared
        model.discover()
        _ = wait(5) { !model.tests(for: testURL).isEmpty }
        check("tests discovered", model.tests(for: testURL).map(\.name) == ["doubles", "fails on purpose"])
        model.run(.file(testURL))
        _ = wait(20) { !model.running }
        let results = model.tests(for: testURL)
        let pass = results.first { $0.name == "doubles" }, fail = results.first { $0.name == "fails on purpose" }
        check("passing test", pass?.status == .passed && pass?.ms != nil)
        check("failing test with message, line and output", fail?.status == .failed && fail?.failLine == 10 &&
              fail?.message?.contains("expected 5, got 4") == true && fail?.output == "debug output\n",
              "\(String(describing: fail))")
        let tdiags = s.diagnostics.diagnostics(for: testURL).filter { $0.source == TestModel.diagnosticSource }
        check("failure shown as a diagnostic on the expect line", tdiags.first?.range.start.line == 10, "\(tdiags)")
        model.run(.test(testURL, "doubles"))
        _ = wait(20) { !model.running }
        check("run a single test", model.lastRun?.passed == 1 && model.lastRun?.failed == 0, "\(String(describing: model.lastRun))")

        // didChange keeps the server in sync (debounced)
        doc.replace(NSRange(location: 0, length: 0), with: "say nope_x\n")
        _ = wait(6) { s.diagnostics.diagnostics(for: uri).contains { $0.message.contains("nope_x") } }
        check("diagnostics follow edits", s.diagnostics.diagnostics(for: uri).contains { $0.message.contains("nope_x") })
        s.documents.remove(doc)
        s.workspace.close()
        return ok
    }
}
