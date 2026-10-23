import SwiftUI
import Combine

/// `vanta test` integration: discovers `test "…"` blocks across the workspace, runs
/// them (all, one file, one test, the failed ones) with `vanta test --json`, and
/// shows live pass/fail results with timings, failure messages linked to their lines,
/// gutter run buttons, and diagnostics on failing `expect` lines.
final class TestModel: ObservableObject {
    static let shared = TestModel()
    static let diagnosticSource = "vanta test"

    enum Status: Equatable { case unknown, queued, running, passed, failed, error }

    struct TestCase: Identifiable, Equatable {
        var id: String { file.path + "::" + name }
        let file: URL
        var name: String
        var line: Int                    // 0-based `test "…"` line
        var status: Status = .unknown
        var ms: Double?
        var message: String?
        var failLine: Int?               // 0-based line the failure points at
        var output: String = ""
    }

    struct TestFile: Identifiable, Equatable {
        var id: URL { url }
        let url: URL
        var tests: [TestCase]
        var error: String?
        var status: Status {
            if error != nil { return .error }
            if tests.contains(where: { $0.status == .running }) { return .running }
            if tests.contains(where: { $0.status == .failed || $0.status == .error }) { return .failed }
            if tests.contains(where: { $0.status == .queued }) { return .queued }
            if !tests.isEmpty && tests.allSatisfy({ $0.status == .passed }) { return .passed }
            return .unknown
        }
    }

    @Published private(set) var files: [TestFile] = []
    @Published private(set) var running = false
    @Published private(set) var lastRun: (passed: Int, failed: Int, errors: Int, ms: Double)?
    @Published private(set) var log = ""
    @Published var collapsed: Set<URL> = []
    @Published var filter = ""
    /// Bumps whenever results change (gutter icons redraw).
    let changed = PassthroughSubject<Void, Never>()

    private var process: Process?
    private var bag = Set<AnyCancellable>()
    private var docBag: [UUID: AnyCancellable] = [:]
    private var discoverWork: DispatchWorkItem?
    private var lineBuffer = ""
    private var runStart = Date()

    var passedCount: Int { files.flatMap(\.tests).filter { $0.status == .passed }.count }
    var failedCount: Int { files.flatMap(\.tests).filter { $0.status == .failed || $0.status == .error }.count + files.filter { $0.error != nil }.count }
    var totalCount: Int { files.reduce(0) { $0 + $1.tests.count } }

    // MARK: discovery

    func start(_ s: Services) {
        s.workspace.$fileIndex.debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.discover() }.store(in: &bag)
        s.workspace.filesChanged.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.discover() }.store(in: &bag)
        s.documents.$documents.receive(on: DispatchQueue.main).sink { [weak self] docs in
            guard let self else { return }
            let ids = Set(docs.map(\.id))
            for id in self.docBag.keys where !ids.contains(id) { self.docBag[id] = nil }
            for d in docs where self.docBag[d.id] == nil && d.language == .vanta {
                self.docBag[d.id] = d.changes.debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                    .sink { [weak self] _ in self?.scheduleDiscover() }
            }
            self.scheduleDiscover()
        }.store(in: &bag)
    }

    func scheduleDiscover() {
        discoverWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.discover() }
        discoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    static let testRE = try! NSRegularExpression(pattern: #"^test[ \t]+"((?:[^"\\\n]|\\.)*)""#, options: [.anchorsMatchLines])

    /// `test "…"` blocks in a source text: (name, 0-based line).
    static func tests(in text: String) -> [(String, Int)] {
        let ns = text as NSString
        var lines = LineIndex()
        lines.rebuild(ns)
        return testRE.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            (ns.substring(with: $0.range(at: 1)), lines.line(at: $0.range.location))
        }
    }

    func discover() {
        let s = Services.shared
        var urls = s.workspace.fileIndex.filter { $0.pathExtension == "va" && !$0.path.contains("/packages/") }
        for d in s.documents.documents where d.language == .vanta {
            if let u = d.url, !urls.contains(where: { $0.standardizedFileURL == u.standardizedFileURL }) { urls.append(u) }
        }
        let open = Dictionary(s.documents.documents.compactMap { d in d.url.map { ($0.standardizedFileURL.path, d.text) } },
                              uniquingKeysWith: { a, _ in a })
        let old = Dictionary(files.flatMap(\.tests).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let oldErrors = Dictionary(files.map { ($0.url.standardizedFileURL.path, $0.error) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [TestFile] = []
            for u in urls.prefix(4000) {
                let key = u.standardizedFileURL.path
                let text: String
                if let t = open[key] { text = t } else {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
                          (attrs[.size] as? Int ?? 0) < 2_000_000,
                          let t = try? String(contentsOf: u, encoding: .utf8) else { continue }
                    text = t
                }
                guard text.contains("test") else { continue }
                let found = Self.tests(in: text)
                guard !found.isEmpty else { continue }
                var cases: [TestCase] = []
                for (name, line) in found {
                    var c = TestCase(file: u, name: name, line: line)
                    if let o = old[c.id] {
                        c.status = o.status; c.ms = o.ms; c.message = o.message; c.output = o.output
                        c.failLine = o.failLine.map { $0 - o.line + line }
                    }
                    cases.append(c)
                }
                out.append(TestFile(url: u, tests: cases, error: oldErrors[key] ?? nil))
            }
            let root = Services.shared.workspace.root?.path ?? ""
            out.sort { a, b in
                let ra = a.url.path.hasPrefix(root), rb = b.url.path.hasPrefix(root)
                return (ra ? 0 : 1, a.url.path) < (rb ? 0 : 1, b.url.path)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if out != self.files { self.files = out; self.changed.send() }
            }
        }
    }

    func tests(for uri: URL) -> [TestCase] {
        let p = uri.standardizedFileURL.path
        return files.first { $0.url.standardizedFileURL.path == p }?.tests ?? []
    }

    // MARK: running

    enum Scope { case all, file(URL), test(URL, String), failed }

    func run(_ scope: Scope) {
        let s = Services.shared
        stop()
        // save edited files first so the tests see what's on screen
        for d in s.documents.documents where d.isDirty && d.url != nil && d.language == .vanta && !s.isSnapshot { d.save() }
        var args = ["test", "--json"]
        var targets: [URL] = []
        var names: [String: Set<String>] = [:]          // file -> test names that will run
        switch scope {
        case .all:
            targets = files.map(\.url)
            if targets.isEmpty, let root = s.workspace.root { targets = [root] }
            for f in files { names[f.url.path] = Set(f.tests.map(\.name)) }
        case .file(let u):
            targets = [u]
            names[u.path] = Set(tests(for: u).map(\.name))
        case .test(let u, let name):
            targets = [u]
            args += ["--exact", "--filter", name]
            names[u.path] = [name]
        case .failed:
            let failed = files.filter { f in f.error != nil || f.tests.contains { $0.status == .failed || $0.status == .error } }
            guard !failed.isEmpty else { s.flash("No failed tests to run again"); return }
            targets = failed.map(\.url)
            for f in failed { names[f.url.path] = Set(f.tests.map(\.name)) }
        }
        guard !targets.isEmpty else { s.flash("No tests found — add a `test \"…\"` block"); return }
        for i in files.indices where names[files[i].url.path] != nil {
            files[i].error = nil
            for j in files[i].tests.indices where names[files[i].url.path]!.contains(files[i].tests[j].name) {
                files[i].tests[j].status = .queued
            }
        }
        changed.send()
        for t in targets { s.diagnostics.publish([], for: t, source: Self.diagnosticSource) }
        log = "$ vanta \(args.joined(separator: " ")) \(targets.map { s.workspace.relativePath($0) }.joined(separator: " "))\n"
        lastRun = nil
        running = true
        runStart = Date()
        launch(args + targets.map(\.path), cwd: s.workspace.root ?? targets[0].deletingLastPathComponent())
    }

    private func launch(_ args: [String], cwd: URL) {
        guard let py = VantaRuntime.python(), let vanta = VantaRuntime.vantaPy else {
            running = false
            log += "python3 or the Vanta runtime is missing\n"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = [vanta.path] + args
        p.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["NO_COLOR"] = "1"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        lineBuffer = ""
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            DispatchQueue.main.async {
                guard let self, self.process === proc else { return }
                if !rest.isEmpty { self.consume(String(decoding: rest, as: UTF8.self)) }
                if !self.lineBuffer.isEmpty { self.consume("\n") }
                self.finish(code: proc.terminationStatus)
            }
        }
        do { try p.run(); process = p } catch {
            running = false
            log += "couldn't start python3: \(error.localizedDescription)\n"
        }
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        p.terminationHandler = nil
        if p.isRunning { p.terminate() }
        running = false
        for i in files.indices {
            for j in files[i].tests.indices where [.queued, .running].contains(files[i].tests[j].status) {
                files[i].tests[j].status = .unknown
            }
        }
        log += "\n(stopped)\n"
        changed.send()
    }

    private func consume(_ chunk: String) {
        lineBuffer += chunk
        while let nl = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<nl])
            lineBuffer.removeSubrange(...nl)
            handle(line)
        }
    }

    private func handle(_ line: String) {
        let marker = "@@vanta-json "
        guard line.hasPrefix(marker), let data = line.dropFirst(marker.count).data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if !line.isEmpty { log += line + "\n" }
            return
        }
        let file = (ev["file"] as? String).map { URL(fileURLWithPath: $0) }
        switch ev["event"] as? String {
        case "file":
            guard let file else { return }
            log += "\n\(Services.shared.workspace.relativePath(file))\n"
            if let fi = index(of: file) {
                for j in files[fi].tests.indices where files[fi].tests[j].status == .queued { files[fi].tests[j].status = .running }
            }
        case "test":
            guard let file, let name = ev["name"] as? String else { return }
            let ok = ev["ok"] as? Bool ?? false
            let ms = ev["ms"] as? Double ?? 0
            let msg = ev["message"] as? String ?? ""
            let output = ev["output"] as? String ?? ""
            let line = (ev["line"] as? Int).map { $0 - 1 }
            log += "  \(ok ? "PASS" : "FAIL")  \(name) (\(String(format: "%.1f", ms)) ms)\n"
            if !ok { for l in msg.split(separator: "\n") { log += "        \(l)\n" } }
            if !output.isEmpty && !ok { for l in output.split(separator: "\n") { log += "        | \(l)\n" } }
            var fi = index(of: file)
            if fi == nil {
                files.append(TestFile(url: file, tests: []))
                fi = files.count - 1
            }
            guard let i = fi else { return }
            let failLine = Self.failureLine(msg)
            if let j = files[i].tests.firstIndex(where: { $0.name == name }) {
                files[i].tests[j].status = ok ? .passed : .failed
                files[i].tests[j].ms = ms
                files[i].tests[j].message = ok ? nil : msg
                files[i].tests[j].output = output
                files[i].tests[j].failLine = ok ? nil : (failLine ?? files[i].tests[j].line)
            } else {
                var c = TestCase(file: file, name: name, line: line ?? 0)
                c.status = ok ? .passed : .failed
                c.ms = ms; c.message = ok ? nil : msg; c.output = output
                c.failLine = ok ? nil : (failLine ?? line)
                files[i].tests.append(c)
            }
            changed.send()
        case "error":
            let msg = ev["message"] as? String ?? "error"
            log += "  ERROR \(msg)\n"
            if let file, let i = index(of: file) {
                files[i].error = msg
                for j in files[i].tests.indices where [.queued, .running].contains(files[i].tests[j].status) {
                    files[i].tests[j].status = .error
                }
            }
            changed.send()
        case "done":
            lastRun = (ev["passed"] as? Int ?? 0, ev["failed"] as? Int ?? 0, ev["errors"] as? Int ?? 0, ev["ms"] as? Double ?? 0)
        default: break
        }
    }

    static func failureLine(_ msg: String) -> Int? {
        guard let r = msg.range(of: #"line (\d+)"#, options: .regularExpression) else { return nil }
        return Int(msg[r].dropFirst(5)).map { $0 - 1 }
    }

    private func index(of url: URL) -> Int? {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        return files.firstIndex { $0.url.standardizedFileURL.resolvingSymlinksInPath().path == p }
    }

    private func finish(code: Int32) {
        process = nil
        running = false
        for i in files.indices {
            for j in files[i].tests.indices where [.queued, .running].contains(files[i].tests[j].status) {
                files[i].tests[j].status = .unknown
            }
        }
        if lastRun == nil {
            lastRun = (passedCount, failedCount, 0, Date().timeIntervalSince(runStart) * 1000)
        }
        if let r = lastRun {
            log += "\n\(r.passed) passed, \(r.failed) failed\(r.errors > 0 ? ", \(r.errors) file errors" : "") in \(Self.duration(r.ms))\n"
            Services.shared.flash(r.failed + r.errors == 0 ? "Tests passed: \(r.passed)" : "Tests: \(r.passed) passed, \(r.failed + r.errors) failed")
        }
        publishFailures()
        changed.send()
    }

    /// Failing tests as diagnostics on the line they point at.
    private func publishFailures() {
        let s = Services.shared
        for f in files {
            var diags: [Diagnostic] = []
            for t in f.tests where t.status == .failed || t.status == .error {
                let line = t.failLine ?? t.line
                var msg = "test “\(t.name)” failed"
                if let m = t.message, !m.isEmpty {
                    msg += ": " + m.replacingOccurrences(of: #"^line \d+: "#, with: "", options: .regularExpression)
                }
                diags.append(Diagnostic(range: lineRange(f.url, line), severity: .error, message: msg, source: Self.diagnosticSource))
            }
            if let e = f.error {
                diags.append(Diagnostic(range: lineRange(f.url, Self.failureLine(e) ?? 0), severity: .error,
                                        message: e, source: Self.diagnosticSource))
            }
            s.diagnostics.publish(diags, for: localURI(f.url), source: Self.diagnosticSource)
        }
    }

    private func localURI(_ u: URL) -> URL {
        Services.shared.documents.document(for: u)?.uri ?? u
    }

    private func lineRange(_ u: URL, _ line: Int) -> TextRange {
        let text = Services.shared.documents.document(for: u)?.text ?? (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        let l = line < lines.count ? lines[line] : ""
        let start = l.prefix { $0 == " " || $0 == "\t" }.utf16.count
        return TextRange(start: TextPosition(line: line, column: start), end: TextPosition(line: line, column: max(start + 1, l.utf16.count)))
    }

    static func duration(_ ms: Double) -> String {
        ms < 1 ? String(format: "%.2f ms", ms) : ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.1f s", ms / 1000)
    }

    // MARK: navigation

    func open(_ t: TestCase, atFailure: Bool = false) {
        let line = atFailure ? (t.failLine ?? t.line) : t.line
        Services.shared.editors.open(location: Location(uri: t.file, range: TextRange(start: TextPosition(line: line, column: 0),
                                                                                      end: TextPosition(line: line, column: 0))))
    }

    /// The test whose block contains the caret.
    func testAtCursor() -> TestCase? {
        guard let ed = Services.shared.editor, let url = ed.url else { return nil }
        let line = ed.cursorPosition.line
        let found = Self.tests(in: ed.text)
        guard let (name, start) = found.last(where: { $0.1 <= line }) else { return nil }
        return tests(for: url).first { $0.name == name } ?? TestCase(file: url, name: name, line: start)
    }
}

// MARK: - Sidebar

struct TestsSidebar: View {
    @ObservedObject var model = TestModel.shared

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("Testing") {
                if model.running {
                    IconButton(icon: "stop.fill", help: "Stop") { model.stop() }
                } else {
                    IconButton(icon: "play.fill", help: "Run All Tests") { model.run(.all) }
                    IconButton(icon: "arrow.counterclockwise", help: "Run Failed Tests") { model.run(.failed) }
                }
                IconButton(icon: "arrow.clockwise", help: "Refresh") { model.discover() }
                IconButton(icon: "rectangle.compress.vertical", help: "Collapse All") {
                    model.collapsed = Set(model.files.map(\.url))
                }
            }
            summary
            if model.files.isEmpty {
                PlaceholderPanel(title: "No tests yet", icon: "checkmark.seal",
                                 message: "Add a block like\n\ntest \"adds numbers\"\n    expect add(2, 2) is 4\nend\n\nto any .va file. Tests show up here.")
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundColor(Theme.muted)
                    TextField("Filter tests", text: $model.filter).textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2.opacity(0.6)))
                .padding(.horizontal, 10).padding(.bottom, 4)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.files) { f in
                            let tests = f.tests.filter { model.filter.isEmpty || $0.name.localizedCaseInsensitiveContains(model.filter) }
                            if !tests.isEmpty || model.filter.isEmpty {
                                TestFileRow(file: f)
                                if !model.collapsed.contains(f.url) {
                                    ForEach(tests) { t in TestRow(test: t) }
                                    if let e = f.error {
                                        Text(e).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.red)
                                            .lineLimit(3).padding(.leading, 40).padding(.trailing, 10).padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }.padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder var summary: some View {
        if model.running || model.lastRun != nil || model.totalCount > 0 {
            HStack(spacing: 10) {
                if model.running { ProgressView().controlSize(.mini) }
                Label("\(model.passedCount)", systemImage: "checkmark.circle.fill").foregroundColor(Theme.green)
                Label("\(model.failedCount)", systemImage: "xmark.circle.fill").foregroundColor(model.failedCount > 0 ? Theme.red : Theme.muted)
                Text("of \(model.totalCount)").foregroundColor(Theme.muted)
                Spacer()
                if let r = model.lastRun, !model.running { Text(TestModel.duration(r.ms)).foregroundColor(Theme.muted) }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 14).padding(.bottom, 6)
        }
    }
}

struct TestStatusIcon: View {
    let status: TestModel.Status
    var body: some View {
        Group {
            switch status {
            case .passed: Image(systemName: "checkmark.circle.fill").foregroundColor(Theme.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundColor(Theme.red)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.amber)
            case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            case .queued: Image(systemName: "clock").foregroundColor(Theme.muted)
            case .unknown: Image(systemName: "circle").foregroundColor(Theme.muted.opacity(0.7))
            }
        }
        .font(.system(size: 11))
        .frame(width: 14)
    }
}

struct TestFileRow: View {
    let file: TestModel.TestFile
    @ObservedObject var model = TestModel.shared
    @ObservedObject var workspace = Services.shared.workspace
    @State private var hover = false

    var body: some View {
        let open = !model.collapsed.contains(file.url)
        HStack(spacing: 5) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.muted).frame(width: 10)
            TestStatusIcon(status: file.status)
            Text(file.url.lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
            Text((workspace.relativePath(file.url) as NSString).deletingLastPathComponent)
                .font(.system(size: 10.5)).foregroundColor(Theme.muted).lineLimit(1)
            Spacer(minLength: 2)
            if hover && !model.running {
                IconButton(icon: "play.fill", help: "Run Tests in File", size: 10) { model.run(.file(file.url)) }
            } else {
                Text("\(file.tests.count)").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 5).background(Capsule().fill(Theme.panel2))
            }
        }
        .padding(.leading, 8).padding(.trailing, 8).frame(height: 24)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            if open { model.collapsed.insert(file.url) } else { model.collapsed.remove(file.url) }
        }
        .contextMenu {
            Button("Run Tests in File") { model.run(.file(file.url)) }
            Button("Open File") { Services.shared.editors.open(file.url) }
        }
    }
}

struct TestRow: View {
    let test: TestModel.TestCase
    @ObservedObject var model = TestModel.shared
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                TestStatusIcon(status: test.status)
                Text(test.name).font(.system(size: 12.5)).lineLimit(1)
                Spacer(minLength: 2)
                if hover && !model.running {
                    IconButton(icon: "play.fill", help: "Run Test", size: 10) { model.run(.test(test.file, test.name)) }
                } else if let ms = test.ms {
                    Text(TestModel.duration(ms)).font(.system(size: 10.5)).foregroundColor(Theme.muted)
                }
            }
            .frame(height: 22)
            if let m = test.message, test.status == .failed || test.status == .error {
                Text(m.replacingOccurrences(of: #"^line \d+: "#, with: "", options: .regularExpression))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.red)
                    .lineLimit(2)
                    .padding(.leading, 20).padding(.bottom, 3)
                    .onTapGesture { model.open(test, atFailure: true) }
            }
        }
        .padding(.leading, 26).padding(.trailing, 8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.open(test, atFailure: test.status == .failed) }
        .contextMenu {
            Button("Run Test") { model.run(.test(test.file, test.name)) }
            Button("Go to Test") { model.open(test) }
            if test.failLine != nil { Button("Go to Failure") { model.open(test, atFailure: true) } }
        }
    }
}

// MARK: - Results panel

struct TestResultsPanel: View {
    @ObservedObject var model = TestModel.shared
    @State private var showLog = false

    var failures: [TestModel.TestCase] {
        model.files.flatMap(\.tests).filter { $0.status == .failed || $0.status == .error }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.running {
                    ProgressView().controlSize(.small)
                    Text("Running tests…").foregroundColor(Theme.muted)
                } else if let r = model.lastRun {
                    Image(systemName: r.failed + r.errors == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(r.failed + r.errors == 0 ? Theme.green : Theme.red)
                    Text("\(r.passed) passed").foregroundColor(Theme.green)
                    Text("\(r.failed) failed").foregroundColor(r.failed > 0 ? Theme.red : Theme.muted)
                    if r.errors > 0 { Text("\(r.errors) file error\(r.errors == 1 ? "" : "s")").foregroundColor(Theme.amber) }
                    Text("in \(TestModel.duration(r.ms))").foregroundColor(Theme.muted)
                } else {
                    Text("\(model.totalCount) test\(model.totalCount == 1 ? "" : "s") found").foregroundColor(Theme.muted)
                }
                Spacer()
                Picker("", selection: $showLog) {
                    Text("Results").tag(false)
                    Text("Output").tag(true)
                }.pickerStyle(.segmented).frame(width: 150).labelsHidden()
                if model.running {
                    IconButton(icon: "stop.fill", help: "Stop") { model.stop() }
                } else {
                    IconButton(icon: "play.fill", help: "Run All Tests") { model.run(.all) }
                    IconButton(icon: "arrow.counterclockwise", help: "Run Failed Tests") { model.run(.failed) }
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 30)
            if showLog {
                ScrollView {
                    Text(model.log.isEmpty ? "No test run yet." : model.log)
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            } else if failures.isEmpty {
                PlaceholderPanel(title: model.lastRun == nil ? "No results yet" : "All tests passed",
                                 icon: model.lastRun == nil ? "checkmark.seal" : "checkmark.seal.fill",
                                 message: model.lastRun == nil ? "Run tests from the Testing sidebar, the ▶ in the gutter, or the Test menu."
                                                                : "Every `expect` held. Nice.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(failures) { t in failure(t) }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    func failure(_ t: TestModel.TestCase) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                TestStatusIcon(status: t.status)
                Text(t.name).font(.system(size: 12.5, weight: .semibold))
                Text("\(t.file.lastPathComponent):\((t.failLine ?? t.line) + 1)")
                    .font(.system(size: 11)).foregroundColor(Theme.accent)
                    .onTapGesture { model.open(t, atFailure: true) }
                Spacer()
                if let ms = t.ms { Text(TestModel.duration(ms)).font(.system(size: 10.5)).foregroundColor(Theme.muted) }
                IconButton(icon: "play.fill", help: "Run Again", size: 10) { model.run(.test(t.file, t.name)) }
            }
            if let m = t.message {
                Text(m).font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.red).textSelection(.enabled)
                    .padding(.leading, 20)
            }
            if !t.output.isEmpty {
                Text(t.output.split(separator: "\n").map { "| " + $0 }.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.muted).textSelection(.enabled)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { model.open(t, atFailure: true) }
    }
}

struct TestsStatusItem: View {
    @ObservedObject var model = TestModel.shared
    var body: some View {
        if model.running {
            StatusLabel(icon: "hourglass", text: "Testing…", help: "Tests are running",
                        action: { Services.shared.layout.showSidebar(PanelID.tests) })
        } else if model.lastRun != nil {
            let failed = model.failedCount
            StatusLabel(icon: failed == 0 ? "checkmark.seal" : "xmark.seal", text: "\(model.passedCount)/\(model.passedCount + failed)",
                        color: failed == 0 ? Theme.muted : Theme.red, help: "Test results — click to show",
                        action: { Services.shared.layout.showSidebar(PanelID.tests) })
        }
    }
}

// MARK: - Gutter run buttons

/// ▶ / ✓ / ✗ in the gutter's glyph margin on every `test "…"` line; click to run that test.
final class TestGutterOverlay: NSView {
    weak var pane: EditorPane?
    private var bag = Set<AnyCancellable>()
    private var cacheVersion = -1
    private var cache: [Int: String] = [:]          // line -> test name

    init(pane: EditorPane) {
        self.pane = pane
        super.init(frame: pane.gutter.bounds)
        autoresizingMask = [.width, .height]
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification,
                                               object: pane.scrollView.contentView)
        pane.document.changes.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.needsDisplay = true }.store(in: &bag)
        TestModel.shared.changed.receive(on: DispatchQueue.main).sink { [weak self] in self?.needsDisplay = true }.store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }
    @objc private func refresh() { needsDisplay = true }

    private var testLines: [Int: String] {
        guard let pane else { return [:] }
        if cacheVersion != pane.document.version {
            cacheVersion = pane.document.version
            cache = Dictionary(TestModel.tests(in: pane.text).map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
        }
        return cache
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let pane, pane.document.language == .vanta, pane.url != nil else { return }
        let lines = testLines
        guard !lines.isEmpty else { return }
        let results = Dictionary(TestModel.shared.tests(for: pane.document.uri).map { ($0.name, $0.status) }, uniquingKeysWith: { a, _ in a })
        let bps = pane.breakpoints
        let tv = pane.textView
        pane.forEachVisibleLine { line, frag, _ in
            guard let name = lines[line], !bps.contains(line) else { return }
            let y = self.convert(NSPoint(x: 0, y: frag.minY), from: tv).y
            let c = NSPoint(x: 10, y: y + frag.height / 2)
            switch results[name] ?? .unknown {
            case .passed: Self.drawSymbol("checkmark.circle.fill", Theme.nMint, at: c)
            case .failed: Self.drawSymbol("xmark.circle.fill", Theme.nRose, at: c)
            case .error: Self.drawSymbol("exclamationmark.triangle.fill", Theme.nAmber, at: c)
            case .running, .queued: Self.drawSymbol("clock.fill", Theme.nAmber, at: c)
            case .unknown: Self.drawSymbol("play.fill", Theme.nMint, at: c, size: 9)
            }
        }
    }

    static func drawSymbol(_ name: String, _ color: NSColor, at c: NSPoint, size: CGFloat = 10.5) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .semibold)
                .applying(.init(paletteColors: name.hasSuffix(".fill") && name != "play.fill" ? [Theme.nbg, color] : [color]))) else { return }
        let s = img.size
        img.draw(in: NSRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height))
    }

    private func line(at p: NSPoint) -> Int? {
        guard let pane, p.x < 18 else { return nil }
        let tvPoint = convert(p, to: pane.textView)
        return pane.line(atY: tvPoint.y)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        guard let l = line(at: p), testLines[l] != nil, pane?.breakpoints.contains(l) == false else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let pane, let url = pane.url, let l = line(at: p), let name = testLines[l] else { return }
        TestModel.shared.run(.test(url, name))
    }

    /// Put an overlay on a pane's gutter (once).
    static func attach(to pane: EditorPane) {
        guard let g = pane.gutter, !g.subviews.contains(where: { $0 is TestGutterOverlay }) else { return }
        let o = TestGutterOverlay(pane: pane)
        o.frame = g.bounds
        g.addSubview(o)
    }
}
