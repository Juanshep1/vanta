import AppKit
import SwiftTerm

/// Headless checks for the Run module. Run with
///
///     "Vanta Studio" --snapshot /dev/null --run run.selftest
///
/// (set VANTA_SELFTEST_DIR to choose the scratch folder). Prints PASS/FAIL per
/// case and exits 0 when everything passed. Never shows a window; programs it
/// runs are plain console programs.
enum RunSelfTest {
    private static var ok = true
    /// `--run run.demo.inline` before `run.demo.diff`: show the diff inline.
    static var inlineDiffDemo = false

    static func waitPublic(_ timeout: Double, _ cond: () -> Bool) { wait(timeout, cond) }

    private static func check(_ name: String, _ cond: Bool, _ detail: @autoclosure () -> String = "") {
        if cond { print("PASS  \(name)") } else { ok = false; print("FAIL  \(name)\n      \(detail())") }
        fflush(stdout)
    }

    /// Spin the run loop until `cond` holds (or the timeout passes).
    @discardableResult
    private static func wait(_ timeout: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return cond()
    }

    static func run() -> Bool {
        let base = ProcessInfo.processInfo.environment["VANTA_SELFTEST_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("run-selftest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        print("Run module self-test in \(dir.path)")

        parsing()
        consoleAndProblems(dir)
        runs(dir)
        terminal()
        debugger(dir)
        git(dir)

        print(ok ? "ALL PASS" : "SOME FAILED")
        return ok
    }

    // MARK: pure parsing

    static func parsing() {
        var p = ANSIParser()
        let pieces = p.feed("plain \u{1B}[1;31mred\u{1B}[0m \u{1B}[38;5;208mo\u{1B}[38;2;10;20;30mt\u{1B}[0m")
        let texts = pieces.compactMap { if case .text(let t, let s) = $0 { return (t, s) }; return nil }
        check("ansi: text split by style", texts.map(\.0) == ["plain ", "red", " ", "o", "t"], "\(texts.map(\.0))")
        check("ansi: bold red", texts.count > 1 && texts[1].1.bold && texts[1].1.fg == .palette(1))
        check("ansi: 256 colour", texts.count > 3 && texts[3].1.fg == .palette(208))
        check("ansi: truecolor", texts.count > 4 && texts[4].1.fg == .rgb(10, 20, 30))
        var q = ANSIParser()
        let a = q.feed("x\u{1B}[3"), b = q.feed("2mgreen")
        check("ansi: escape split across chunks", a == [.text("x", ANSIStyle())] && b.first == .text("green", { var s = ANSIStyle(); s.fg = .palette(2); return s }()), "\(a) \(b)")
        var r = ANSIParser()
        check("ansi: carriage return rewrites", r.feed("10%\r20%\r\n") == [.text("10%", ANSIStyle()), .carriageReturn, .text("20%\n", ANSIStyle())])
        check("ansi: strip OSC + cursor moves", ANSIParser.strip("\u{1B}]0;title\u{07}a\u{1B}[2Kb\u{1B}[10;5Hc") == "abc")

        check("shell words", ShellWords.split(#"one "two words" 'it''s' a\ b"#) == ["one", "two words", "its", "a b"],
              "\(ShellWords.split(#"one "two words" 'it''s' a\ b"#))")
        var cfg = RunConfiguration(name: "t")
        cfg.environment = "A=1\n# note\nB = \"x y\"\n"
        check("run config env", cfg.parsedEnvironment == ["A": "1", "B": "x y"], "\(cfg.parsedEnvironment)")

        let a1 = ["a", "b", "c", "d"], b1 = ["a", "B", "c", "d", "e"]
        check("diff markers", LineDiffer.markers(old: a1, new: b1) == [1: .modified, 4: .added], "\(LineDiffer.markers(old: a1, new: b1))")
        check("diff markers: deletion", LineDiffer.markers(old: ["a", "b", "c"], new: ["a", "c"]) == [1: .deletedAbove])
        let rows = LineDiffer.rows(Array(repeating: "same", count: 30) + ["old"], Array(repeating: "same", count: 30) + ["new"])
        check("diff rows fold unchanged runs", rows.first?.kind == .fold && rows.last?.kind == .changed, "\(rows.map(\.kind))")
        let big = (0..<3000).map { "line \($0)" }
        var big2 = big; big2.remove(at: 1500); big2.insert("inserted", at: 10)
        let t0 = Date()
        let m = LineDiffer.markers(old: big, new: big2)
        check("diff 3000 lines", m == [10: .added, 1501: .deletedAbove] && Date().timeIntervalSince(t0) < 1, "\(m)")

        let status = GitClient.parseStatus(Data(("# branch.oid abc\0# branch.head main\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
            + "1 M. N... 100644 100644 100644 h1 h2 src/a.va\0" + "1 .M N... 100644 100644 100644 h1 h2 b.va\0"
            + "2 R. N... 100644 100644 100644 h1 h2 R100 new.va\0old.va\0" + "? notes.txt\0").utf8))
        check("git status parse", status.branch == "main" && status.ahead == 2 && status.behind == 1
              && status.changes.map { "\($0.area.rawValue):\($0.code):\($0.path)" } == ["staged:M:src/a.va", "unstaged:M:b.va", "staged:R:new.va", "untracked:?:notes.txt"]
              && status.changes[2].origPath == "old.va", "\(status)")
    }

    // MARK: console + problem matcher

    static func consoleAndProblems(_ dir: URL) {
        let f = dir.appendingPathComponent("shop.va")
        try? "say 1\nsay 2\nsay totl\n".write(to: f, atomically: true, encoding: .utf8)
        let out = "Oops! line 3: I don't know what 'totl' is yet\n  --> shop.va:3\n   |\n 3 | say totl\n   |     ^^^^\n   = hint: did you mean 'total'?\n"
        let buf = ConsoleBuffer()
        buf.baseDirectory = dir
        buf.append("\u{1B}[32mok\u{1B}[0m\n" + out)
        var links = 0
        buf.storage.enumerateAttribute(.link, in: NSRange(location: 0, length: buf.storage.length)) { v, _, _ in if v != nil { links += 1 } }
        check("console links file:line", links == 1, "links=\(links) in \(buf.string.debugDescription)")
        check("console strips ANSI", buf.string.hasPrefix("ok\n"))
        let probs = ProblemMatcher.match(out, resolve: { buf.resolve($0) }, mainFile: nil)
        check("problem matcher", probs.count == 1 && probs[0].line == 3 && probs[0].column == 4
              && probs[0].file.lastPathComponent == "shop.va" && probs[0].message.contains("totl"), "\(probs)")
    }

    // MARK: running programs

    static func runs(_ dir: URL) {
        let run = RunController.shared
        guard let rt = run.runtime else { check("vanta runtime found", false); return }
        print("      runtime: Vanta \(rt.version) at \(rt.home.path) (\(rt.source))")

        var result: RunController.RunResult?
        Task { @MainActor in result = await run.runAndCapture("say \"hello\"\nsay 6 * 7\n", timeout: 20) }
        wait(25) { result != nil }
        check("runAndCapture: output + exit 0", result?.output == "hello\n42\n" && result?.failed == false, "\(String(describing: result))")

        result = nil
        Task { @MainActor in result = await run.runAndCapture("say 1 / 0\n", timeout: 20) }
        wait(25) { result != nil }
        check("runAndCapture: failure", result?.failed == true && (result?.output.contains("Oops!") ?? false), "\(String(describing: result))")

        result = nil
        Task { @MainActor in result = await run.runAndCapture("ask \"name?\" into n\nsay n\n", timeout: 20) }
        wait(25) { result != nil }
        check("runAndCapture: ask gets EOF instead of hanging", result != nil && result?.timedOut == false, "\(String(describing: result))")

        result = nil
        let t0 = Date()
        Task { @MainActor in result = await run.runAndCapture("while yes\n    let x be 1\nend\n", timeout: 1.5) }
        wait(10) { result != nil }
        check("runAndCapture: timeout stops a busy loop", result?.timedOut == true && Date().timeIntervalSince(t0) < 5, "\(String(describing: result))")

        // a full run through the Console with a configuration
        let prog = dir.appendingPathComponent("prog.va")
        try? "let a be join(arguments(), \",\")\nsay \"args: {a}\"\nask \"name?\" into who\nsay \"hi {who}\"\nsay 1 / 0\n".write(to: prog, atomically: true, encoding: .utf8)
        var cfg = RunConfiguration(name: "test")
        cfg.target = .file(prog.path)
        cfg.arguments = "one \"two words\""
        run.run(configuration: cfg)
        check("run: started", run.isRunning)
        wait(10) { run.console.contains("name?") }
        run.sendInput("Ada")
        wait(15) { !run.isRunning }
        let text = run.console
        check("run: args reach the program", text.contains("args: one,two words"), text)
        check("run: ask input", text.contains("hi Ada"), text)
        check("run: exit code + timing footer", run.lastExitCode == 1 && text.contains("exited with code 1") && run.lastDuration != nil, text)
        let diags = DiagnosticsStore.shared.diagnostics(for: prog.standardizedFileURL).filter { $0.source == "run" }
        check("run: runtime error → Problems (source run)", diags.count == 1 && diags.first?.range.start.line == 4, "\(diags)")

        // stop
        let loop = dir.appendingPathComponent("loop.va")
        try? "say \"start\"\nwhile yes\n    let x be 1\nend\n".write(to: loop, atomically: true, encoding: .utf8)
        cfg.target = .file(loop.path); cfg.arguments = ""
        run.run(configuration: cfg)
        wait(10) { run.console.contains("start") }
        run.stop()
        check("run: stop", !run.isRunning && run.console.contains("stopped"), run.console)
        ProblemMatcher.publish([])
    }

    // MARK: terminal

    final class NullDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    static func terminal() {
        let d = NullDelegate()
        let t = Terminal(delegate: d, options: TerminalOptions(cols: 40, rows: 10))
        t.feed(text: "ab\u{1B}[31mR\u{1B}[0m\u{1B}[38;5;200mP\u{1B}[38;2;1;2;3mT\u{1B}[0m")
        func line(_ r: Int) -> String {
            (0..<t.cols).map { String(t.getCharacter(col: $0, row: r) ?? " ") }.joined().replacingOccurrences(of: "\u{0}", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        check("vt: plain text", line(0) == "abRPT", line(0))
        check("vt: 16-colour fg", t.getCharData(col: 2, row: 0)?.attribute.fg == .ansi256(code: 1))
        check("vt: 256-colour fg", t.getCharData(col: 3, row: 0)?.attribute.fg == .ansi256(code: 200))
        check("vt: truecolor fg", t.getCharData(col: 4, row: 0)?.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        t.feed(text: "\u{1B}[5;10HZ")
        check("vt: cursor addressing", t.getCharacter(col: 9, row: 4) == "Z")
        t.feed(text: "\u{1B}[?1049h\u{1B}[2J\u{1B}[Halt")
        check("vt: alternate screen", t.isCurrentBufferAlternate && line(0) == "alt", line(0))
        t.feed(text: "\u{1B}[?1049l")
        check("vt: back to main screen", !t.isCurrentBufferAlternate && line(0) == "abRPT", line(0))
        t.resize(cols: 20, rows: 5)
        check("vt: resize", t.cols == 20 && t.rows == 5)

        // a real pty running the login shell
        let s = TerminalSession(number: 99, cwd: FileManager.default.temporaryDirectory)
        s.view.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        wait(3) { false }       // let the shell start and print its prompt
        s.send("echo vanta-$((40+2)); tput cols\r")
        let found = wait(8) {
            let txt = String(decoding: s.view.getTerminal().getBufferAsData(), as: UTF8.self)
            return txt.contains("vanta-42\n\(s.view.getTerminal().cols)")
        }
        let txt = String(decoding: s.view.getTerminal().getBufferAsData(), as: UTF8.self)
        check("pty: login shell runs commands", found, txt.suffix(400).description)
        let cols = s.view.getTerminal().cols
        check("pty: TIOCSWINSZ size reaches the shell", txt.contains("\n\(cols)"), "cols=\(cols) " + txt.suffix(200).description)
        s.send("exit\r")
        wait(4) { s.exited != nil }
        check("pty: exit is reported", s.exited != nil)
    }

    // MARK: debugger

    static func debugger(_ dir: URL) {
        let dbg = DebugController.shared
        guard RunController.shared.runtime?.supportsDebugJSON == true else {
            check("debugger: runtime supports --json", false, "\(String(describing: RunController.shared.runtime))"); return
        }
        let f = dir.appendingPathComponent("dbg.va")
        try? """
        to square(n)
            let result be n * n
            give back result
        end

        let total be 0
        let data be {"items": [1, 2, 3], "name": "box"}
        for each i in [1, 2, 3]
            change total to total + square(i)
        end
        say "total is {total}"

        """.write(to: f, atomically: true, encoding: .utf8)
        let uri = f.standardizedFileURL
        BreakpointStore.shared.set([1], for: uri)                 // `let result be n * n` (0-based line 1)
        RunSettings.shared.setCondition("n is 2", uri, 1)
        var cfg = RunConfiguration(name: "dbg")
        cfg.target = .file(f.path)
        dbg.start(configuration: cfg)
        let paused = wait(15) { dbg.isPaused }
        check("debugger: stops at the conditional breakpoint", paused && dbg.stack.first?.line == 2, "state=\(dbg.state) stack=\(dbg.stack)")
        check("debugger: call stack", dbg.stack.map(\.name) == ["square", "top level"], "\(dbg.stack)")
        wait(5) { !dbg.scopes.isEmpty && dbg.scopes.allSatisfy { dbg.children[$0.ref] != nil } }
        let locals = dbg.scopes.first.flatMap { dbg.children[$0.ref] } ?? []
        check("debugger: locals", locals.contains { $0.name == "n" && $0.value == "2" }, "\(locals)")
        dbg.evaluate("n * 100")
        wait(5) { dbg.consoleEntries.last?.kind == .result }
        check("debugger: evaluate in frame", dbg.consoleEntries.last?.text == "200", "\(dbg.consoleEntries.map(\.text))")
        dbg.selectedFrame = 1
        wait(5) { dbg.scopes.contains { $0.name == "Globals" } && dbg.scopes.allSatisfy { dbg.children[$0.ref] != nil } }
        let globals = dbg.scopes.last.flatMap { dbg.children[$0.ref] } ?? []
        let data = globals.first { $0.name == "data" }
        check("debugger: caller frame globals", globals.contains { $0.name == "total" && $0.value == "1" } && data?.ref ?? 0 > 0, "\(globals)")
        if let data {
            dbg.load(ref: data.ref)
            wait(5) { dbg.children[data.ref] != nil }
            let items = dbg.children[data.ref]?.first { $0.name == "\"items\"" }
            check("debugger: expand a map", items?.value == "[1, 2, 3]" && items?.count == 3, "\(String(describing: dbg.children[data.ref]))")
        }
        dbg.addWatch("total + 1000")
        wait(5) { dbg.watches.last?.value != nil }
        check("debugger: watch expression", dbg.watches.last?.value?.value == "1001", "\(dbg.watches)")
        dbg.removeWatch("total + 1000")
        dbg.stepOut()
        wait(10) { dbg.isPaused && dbg.stack.first?.name == "top level" }
        check("debugger: step out", dbg.stack.first?.line == 9, "\(dbg.stack)")
        dbg.stepOver()
        wait(10) { dbg.isPaused }
        check("debugger: step over", dbg.isPaused && dbg.stack.first?.name == "top level", "\(dbg.stack)")
        BreakpointStore.shared.set([], for: uri)
        dbg.continueRun()
        let done = wait(15) { !dbg.isActive }
        check("debugger: runs to the end", done && RunController.shared.console.contains("total is 14"), RunController.shared.console)
        RunSettings.shared.setCondition(nil, uri, 1)

        // pause a running program, then stop it
        let loop = dir.appendingPathComponent("spin.va")
        try? "let i be 0\nwhile yes\n    change i to i + 1\nend\n".write(to: loop, atomically: true, encoding: .utf8)
        cfg.target = .file(loop.path)
        dbg.start(configuration: cfg)
        wait(10) { dbg.state == .running }
        wait(0.5) { false }
        dbg.pause()
        let p2 = wait(10) { dbg.isPaused }
        check("debugger: pause a running program", p2 && (dbg.stack.first?.line ?? 0) >= 2, "\(dbg.state) \(dbg.stack)")
        dbg.stop()
        check("debugger: stop", !dbg.isActive)
    }

    // MARK: git

    static func git(_ dir: URL) {
        guard GitClient.gitPath != nil else { check("git installed", false); return }
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        try? FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let g = GitClient(root: repo)
        g.git(["init", "-q", "-b", "main"])
        g.git(["config", "user.email", "test@example.com"]); g.git(["config", "user.name", "Self Test"])
        g.git(["config", "commit.gpgsign", "false"])
        try? "one\ntwo\nthree\n".write(to: repo.appendingPathComponent("a.va"), atomically: true, encoding: .utf8)
        try? "keep\n".write(to: repo.appendingPathComponent("b.va"), atomically: true, encoding: .utf8)
        _ = g.stage(["."])
        let c1 = g.commit(message: "first")
        check("git: commit", c1.ok, c1.combined)
        try? "one\n2\nthree\nfour\n".write(to: repo.appendingPathComponent("a.va"), atomically: true, encoding: .utf8)
        try? "new\n".write(to: repo.appendingPathComponent("c.va"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: repo.appendingPathComponent("b.va"))
        var st = g.status()
        check("git: status on a temp repo", st.branch == "main"
              && Set(st.changes.map { "\($0.area.rawValue):\($0.code):\($0.path)" }) == ["unstaged:M:a.va", "unstaged:D:b.va", "untracked:?:c.va"],
              "\(st.changes)")
        _ = g.stage(["a.va"])
        st = g.status()
        check("git: stage", st.changes.contains { $0.area == .staged && $0.path == "a.va" })
        _ = g.unstage(["a.va"], hasHead: true)
        st = g.status()
        check("git: unstage", !st.changes.contains { $0.area == .staged })
        check("git: HEAD contents", g.headContents("a.va") == "one\ntwo\nthree\n")
        _ = g.discard(["b.va"])
        check("git: discard restores a deleted file", FileManager.default.fileExists(atPath: repo.appendingPathComponent("b.va").path))
        _ = g.createBranch("feature")
        check("git: branches", Set(g.branches()) == ["main", "feature"], "\(g.branches())")

        // the controller end to end
        let gc = GitController.shared
        gc.open(repo)
        wait(10) { gc.isRepo && !gc.status.changes.isEmpty }
        check("git controller: open + refresh", gc.status.branch == "feature" && gc.unstaged.count == 1 && gc.untracked.count == 1,
              "\(gc.status)")
        gc.commitMessage = "second"
        gc.commit()                                       // nothing staged → stages everything
        wait(10) { gc.busy == nil && gc.history.count == 2 }
        check("git controller: commit all", gc.history.first?.subject == "second" && gc.status.changes.isEmpty, "\(gc.history) \(gc.status)")
        var model: DiffModel?
        try? "one\nTWO\nthree\nfour\n".write(to: repo.appendingPathComponent("a.va"), atomically: true, encoding: .utf8)
        gc.refresh()
        wait(10) { !gc.status.changes.isEmpty }
        if let ch = gc.unstaged.first { gc.showDiff(ch) }
        wait(5) { gc.openDiff != nil }
        model = gc.openDiff
        check("git controller: diff vs HEAD", model?.oldText == "one\n2\nthree\nfour\n" && model?.newText == "one\nTWO\nthree\nfour\n",
              "\(String(describing: model))")
        gc.openDiff = nil
        gc.open(Services.shared.workspace.root)
    }
}
