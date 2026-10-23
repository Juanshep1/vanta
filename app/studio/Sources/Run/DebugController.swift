import SwiftUI
import Combine

/// Drives a debug session: breakpoints from the gutter (with conditions), the
/// step controls, the current-line highlight, call stack, variables, watches
/// and the debug console.
final class DebugController: ObservableObject {
    static let shared = DebugController()

    enum State: Equatable { case idle, starting, running, paused }

    struct ConsoleEntry: Identifiable {
        enum Kind { case input, result, error, info }
        let id = UUID()
        let kind: Kind
        let text: String
        var variable: DebugSession.Variable? = nil
    }

    struct Watch: Identifiable, Equatable {
        var id: String { expression }
        let expression: String
        var value: DebugSession.Variable?
        var error: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var stack: [DebugSession.Frame] = []
    @Published var selectedFrame = 0 { didSet { if oldValue != selectedFrame { frameChanged() } } }
    @Published private(set) var scopes: [(name: String, ref: Int)] = []
    /// Loaded children per variable reference (valid while paused).
    @Published private(set) var children: [Int: [DebugSession.Variable]] = [:]
    @Published var expanded: Set<String> = []
    @Published private(set) var watches: [Watch] = []
    @Published private(set) var consoleEntries: [ConsoleEntry] = []
    @Published private(set) var stopReason = ""
    @Published private(set) var sessionName = ""

    var isActive: Bool { state != .idle }
    var isPaused: Bool { state == .paused }

    private var session: DebugSession?
    private var highlighted: EditorController?
    private var bag = Set<AnyCancellable>()
    /// debugger path → document uri (untitled buffers debug from a temp copy)
    private var pathToURI: [String: URL] = [:]
    private var uriToPath: [URL: String] = [:]
    private var lastConfig: RunConfiguration?

    private init() {
        BreakpointStore.shared.changed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] uri in self?.syncBreakpoints(uri) }
            .store(in: &bag)
        RunSettings.shared.$conditions
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncAllBreakpoints() }
            .store(in: &bag)
        watches = RunSettings.shared.watches.map { Watch(expression: $0) }
    }

    // MARK: lifecycle

    /// F5: continue when paused, otherwise start debugging.
    func startOrContinue() {
        switch state {
        case .paused: resume("continue")
        case .idle: start()
        default: break
        }
    }

    func start(configuration: RunConfiguration? = nil) {
        let config = configuration ?? RunSettings.shared.selected
        let run = RunController.shared
        if isActive { stop() }
        if run.isRunning { run.stop() }
        guard let rt = run.runtime, rt.supportsDebugJSON else {
            log(.error, "The debugger needs a Vanta installation with `vanta debug --json` (Vanta 6.0+ with vanta_tools). Set its folder in Run and Debug › Interpreter.")
            Services.shared.layout.showBottom(PanelID.debugConsole)
            return
        }
        guard let py = PythonRunner.findPython() else { log(.error, "python3 not found"); return }
        var cfg = config
        cfg.mode = .interpret
        guard let plan = run.plan(cfg) else { return }
        lastConfig = config
        pathToURI = [:]; uriToPath = [:]
        // map an untitled/dirty buffer's temp copy back to its document
        if let doc = Services.shared.editors.activeDocument, cfg.target == .currentFile,
           plan.file.standardizedFileURL != doc.url?.standardizedFileURL {
            pathToURI[plan.file.path] = doc.uri
            uriToPath[doc.uri] = plan.file.path
        }
        run.prepareForDebug(name: plan.displayName, cwd: plan.cwd)
        consoleEntries.removeAll { $0.kind != .input && $0.kind != .result && $0.kind != .error }
        log(.info, "Debugging \(plan.displayName) with Vanta \(rt.version)")
        sessionName = plan.displayName
        state = .starting
        let sess = DebugSession()
        session = sess
        sess.onEvent = { [weak self, weak sess] e in
            guard let self, let sess, self.session === sess else { return }
            self.handle(e)
        }
        sess.start(python: py, vantaPy: rt.vantaPy, file: plan.file, arguments: cfg.parsedArguments,
                   cwd: plan.cwd, environment: cfg.parsedEnvironment)
        Services.shared.layout.showSidebar(PanelID.runDebug)
    }

    func stop() {
        guard let s = session else { return }
        s.terminate()
        ended(code: nil)
    }

    func restart() {
        let c = lastConfig
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.start(configuration: c) }
    }

    func resume(_ cmd: String) {
        guard state == .paused, let s = session else { return }
        state = .running
        clearHighlight()
        s.command(cmd)
    }

    func continueRun() { resume("continue") }
    func stepOver() { if state == .paused { resume("next") } else if state == .idle { startPaused() } }
    func stepInto() { if state == .paused { resume("step") } else if state == .idle { startPaused() } }
    func stepOut() { resume("finish") }
    func pause() { if state == .running { session?.pause() } }

    private var forceStopOnEntry = false
    private func startPaused() { forceStopOnEntry = true; start() }

    func sendInput(_ text: String) {
        session?.input(text)
    }

    // MARK: events

    private func handle(_ e: DebugSession.Event) {
        switch e {
        case .ready:
            syncAllBreakpoints()
            session?.begin(stopOnEntry: RunSettings.shared.stopOnEntry || forceStopOnEntry)
            forceStopOnEntry = false
            state = .running
        case .output(let text):
            RunController.shared.appendProgramOutput(text)
        case .continued:
            if state == .paused { state = .running }
        case .stopped(let reason, let file, let line, let frames):
            state = .paused
            stopReason = reason
            stack = frames
            children = [:]
            scopes = []
            selectedFrame = 0
            frameChanged()
            refreshWatches()
            _ = file; _ = line
        case .error(let message, let file, let line):
            log(.error, message)
            if let file, let line {
                let uri = uriFor(file)
                ProblemMatcher.publish([ProblemMatcher.Problem(file: uri, line: line, column: nil, message: message)])
            }
        case .exited(let code):
            ended(code: code)
        }
    }

    private func ended(code: Int32?) {
        session = nil
        state = .idle
        stack = []; scopes = []; children = [:]
        clearHighlight()
        if let code { log(code == 0 ? .info : .error, "Program exited with code \(code)") } else { log(.info, "Debugging stopped") }
        RunController.shared.debugEnded(code: code)
        watches = watches.map { Watch(expression: $0.expression) }
    }

    private func frameChanged() {
        guard state == .paused, selectedFrame < stack.count else { return }
        let f = stack[selectedFrame]
        reveal(f)
        scopes = []
        session?.scopes(frame: f.id) { [weak self] sc in
            guard let self else { return }
            self.scopes = sc
            for s in sc { self.load(ref: s.ref) }
            if self.expanded.isEmpty { self.expanded = Set(sc.prefix(1).map { "scope/\($0.name)" }) }
        }
        refreshWatches()
    }

    func load(ref: Int) {
        guard ref > 0, children[ref] == nil else { return }
        session?.variables(ref: ref) { [weak self] vars in self?.children[ref] = vars }
    }

    private func reveal(_ f: DebugSession.Frame) {
        guard f.line > 0, !f.file.isEmpty else { return }
        clearHighlight()
        let uri = uriFor(f.file)
        let s = Services.shared
        let pos = TextPosition(line: f.line - 1, column: 0)
        if let doc = s.documents.documents.first(where: { $0.uri == uri }) {
            s.editors.open(document: doc, focus: false)
        } else {
            s.editors.open(location: Location(uri: uri, range: TextRange(start: pos, end: pos)))
        }
        if let ed = s.editor, ed.document.uri == uri || (ed.document.url.map(FilePaths.real) == (uri.isFileURL ? FilePaths.real(uri) : nil)) {
            ed.highlightLine(f.line - 1)
            highlighted = ed
        }
    }

    private func uriFor(_ path: String) -> URL {
        if let u = pathToURI[path] { return u }
        let real = FilePaths.real(URL(fileURLWithPath: path))
        if let u = pathToURI.first(where: { FilePaths.real(URL(fileURLWithPath: $0.key)) == real })?.value { return u }
        return FilePaths.documentURI(for: URL(fileURLWithPath: path))
    }

    private func clearHighlight() {
        highlighted?.highlightLine(nil)
        highlighted = nil
    }

    // MARK: breakpoints

    private func path(for uri: URL) -> String? {
        if let p = uriToPath[uri] { return p }
        return uri.isFileURL ? FilePaths.real(uri) : nil
    }

    private func syncBreakpoints(_ uri: URL) {
        guard let s = session, s.isAlive, let p = path(for: uri) else { return }
        let lines = BreakpointStore.shared.lines(for: uri).sorted()
        s.setBreakpoints(file: p, lines.map { ($0 + 1, RunSettings.shared.condition(uri, $0)) })
    }

    private func syncAllBreakpoints() {
        for uri in BreakpointStore.shared.byURI.keys { syncBreakpoints(uri) }
    }

    func toggleBreakpointAtCursor() {
        guard let ed = Services.shared.editor else { return }
        BreakpointStore.shared.toggle(ed.cursorPosition.line, in: ed.document.uri)
    }

    // MARK: watches & evaluation

    func addWatch(_ expr: String) {
        let e = expr.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !watches.contains(where: { $0.expression == e }) else { return }
        watches.append(Watch(expression: e))
        RunSettings.shared.watches = watches.map(\.expression)
        refreshWatches()
    }

    func removeWatch(_ expr: String) {
        watches.removeAll { $0.expression == expr }
        RunSettings.shared.watches = watches.map(\.expression)
    }

    func refreshWatches() {
        guard state == .paused, let s = session else { return }
        let frame = stack.indices.contains(selectedFrame) ? stack[selectedFrame].id : 0
        for (i, w) in watches.enumerated() {
            s.evaluate(w.expression, frame: frame) { [weak self] r in
                guard let self, i < self.watches.count, self.watches[i].expression == w.expression else { return }
                switch r {
                case .success(let v):
                    self.watches[i].value = v; self.watches[i].error = nil
                case .failure(let e):
                    self.watches[i].value = nil; self.watches[i].error = e.message
                }
            }
        }
    }

    /// Evaluate in the selected frame for the debug console.
    func evaluate(_ expr: String) {
        let e = expr.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return }
        log(.input, e)
        guard state == .paused, let s = session else {
            log(.error, state == .idle ? "Start debugging (F5) and pause at a breakpoint to evaluate." : "Pause the program first (F6).")
            return
        }
        let frame = stack.indices.contains(selectedFrame) ? stack[selectedFrame].id : 0
        s.evaluate(e, frame: frame) { [weak self] r in
            guard let self else { return }
            switch r {
            case .success(let v):
                self.consoleEntries.append(ConsoleEntry(kind: .result, text: v.value, variable: v))
                if v.ref > 0 { self.load(ref: v.ref) }
            case .failure(let err): self.log(.error, err.message)
            }
        }
    }

    func log(_ kind: ConsoleEntry.Kind, _ text: String) {
        consoleEntries.append(ConsoleEntry(kind: kind, text: text))
        if consoleEntries.count > 500 { consoleEntries.removeFirst(consoleEntries.count - 500) }
    }

    func clearConsole() { consoleEntries = [] }
}
