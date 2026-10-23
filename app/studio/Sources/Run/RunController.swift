import SwiftUI
import Combine

/// Runs Vanta programs (interpreted or built native) and owns the Console.
///
/// `console` is the plain-text mirror other modules read (the AI's "Fix with
/// Vee" and agent loop); the styled, linkified text lives in `buffer`.
final class RunController: ObservableObject {
    static let shared = RunController()

    /// Plain text of the console (ANSI stripped). Setting it from outside
    /// replaces the styled console too.
    @Published var console: String = "" {
        didSet { if !internalWrite { buffer.setPlain(console); consoleVersion += 1 } }
    }
    @Published private(set) var isRunning = false
    @Published var lastRunFailed = false        // the last run exited non-zero
    @Published var statusText = "Ready"
    @Published private(set) var runningName = ""
    @Published private(set) var lastExitCode: Int32?
    @Published private(set) var lastDuration: TimeInterval?
    @Published private(set) var startedAt: Date?
    /// Bumps whenever the styled console changes (cheap for views to observe).
    @Published private(set) var consoleVersion = 0

    let buffer = ConsoleBuffer()
    private var internalWrite = false
    private let runner = ProcessRunner()
    /// A separate runner for headless "run and capture" (the AI agent) — it
    /// shares the console when streaming but never fights the user's run.
    private let captureRunner = ProcessRunner()
    private var pendingOutput = ""
    private var flushScheduled = false
    private var runOutput = ""                  // this run's plain output (for the problem matcher)
    private var runMainFile: URL?
    private var lastRun: (() -> Void)?

    var runtime: VantaInstall? { VantaInstall.resolve() }

    /// Kept for Studio 1 callers.
    var vantaPyURL: URL? { runtime?.vantaPy }

    // MARK: console writes

    private func write(_ text: String) {
        pendingOutput += text
        guard !flushScheduled else { return }
        flushScheduled = true
        // coalesce bursts of output into ~60 updates per second
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in self?.flushOutput() }
    }

    private func flushOutput() {
        flushScheduled = false
        guard !pendingOutput.isEmpty else { return }
        let chunk = pendingOutput
        pendingOutput = ""
        let plain = buffer.append(chunk)
        internalWrite = true
        console += plain
        if console.utf16.count > buffer.limit { console = String(console.suffix(buffer.limit * 2 / 3)) }
        internalWrite = false
        consoleVersion += 1
    }

    private func note(_ text: String, colour: NSColor = Theme.nMuted, bold: Bool = false) {
        flushOutput()
        buffer.appendNote(text, colour: colour, bold: bold)
        internalWrite = true
        if !console.isEmpty && !console.hasSuffix("\n") { console += "\n" }
        console += text
        internalWrite = false
        consoleVersion += 1
    }

    func clearConsole() {
        pendingOutput = ""
        buffer.clear()
        internalWrite = true
        console = ""
        internalWrite = false
        consoleVersion += 1
    }

    // MARK: resolving what to run

    struct Plan {
        var file: URL
        var displayName: String
        var cwd: URL
        var configuration: RunConfiguration
    }

    /// Work out the file, folder and configuration for a run. Saves (or snapshots
    /// to a temp file) the active document as needed.
    func plan(_ config: RunConfiguration) -> Plan? {
        let s = Services.shared
        var file: URL?
        var name = ""
        switch config.target {
        case .entryPoint:
            if let main = WorkspaceManifest.entryPoint(s.workspace.root) {
                if let doc = s.documents.documents.first(where: { $0.url?.standardizedFileURL == main }), doc.isDirty,
                   s.settings.prefs.saveBeforeRun { doc.save() }
                file = main; name = main.lastPathComponent
            }
        case .file(let p):
            let expanded = (p as NSString).expandingTildeInPath
            let u = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : (s.workspace.root ?? URL(fileURLWithPath: NSHomeDirectory())).appendingPathComponent(expanded)
            guard FileManager.default.fileExists(atPath: u.path) else { s.flash("\(p) doesn't exist"); return nil }
            file = u.standardizedFileURL; name = u.lastPathComponent
        case .currentFile:
            break
        }
        if file == nil {
            guard let doc = s.editors.activeDocument else { s.flash("Open a file to run"); return nil }
            name = doc.name
            if let url = doc.url, url.pathExtension == "va" {
                if doc.isDirty && s.settings.prefs.saveBeforeRun { doc.save() }
                file = doc.isDirty ? writeTemp(doc.text, near: url) : url
            } else {
                file = writeTemp(doc.text, near: nil)
            }
        }
        guard let file else { return nil }
        let fileDir = file.deletingLastPathComponent()
        var cwd = fileDir
        let wd = config.workingDirectory.trimmingCharacters(in: .whitespaces)
        if !wd.isEmpty {
            let root = s.workspace.root?.path ?? fileDir.path
            let expanded = (wd.replacingOccurrences(of: "${workspace}", with: root)
                .replacingOccurrences(of: "${fileDir}", with: fileDir.path) as NSString).expandingTildeInPath
            cwd = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: root).appendingPathComponent(expanded)
        } else if file.path.hasPrefix(FileManager.default.temporaryDirectory.path) {
            cwd = s.workspace.root ?? fileDir
        }
        return Plan(file: file, displayName: name, cwd: cwd, configuration: config)
    }

    /// Unsaved buffers run from a temp copy. A copy of a saved file goes in a
    /// hidden temp folder named like the file so tracebacks still read well.
    private func writeTemp(_ text: String, near url: URL?) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-studio-run", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(url?.lastPathComponent ?? "untitled.va")
        try? text.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    // MARK: run

    /// Run with the selected configuration (⌘R).
    func run() { run(configuration: RunSettings.shared.selected) }

    func run(configuration config: RunConfiguration) {
        if DebugController.shared.isActive { DebugController.shared.stop() }
        guard let plan = plan(config) else { return }
        guard let rt = runtime else { note("⚠️  No Vanta interpreter found.\n", colour: Theme.nRose); return }
        guard let py = PythonRunner.findPython() else {
            note("⚠️  Couldn't find python3 on this Mac — set it in Settings › Run.\n", colour: Theme.nRose); return
        }
        let s = Services.shared
        if isRunning { runner.stop(); isRunning = false }
        if s.settings.prefs.clearConsoleOnRun { clearConsole() }
        lastRun = { [weak self] in self?.run(configuration: config) }

        var args: [String]
        var title = "Running \(plan.displayName)"
        if config.mode == .native {
            guard let vantac = VantaInstall.withCompiler()?.vantac else {
                note("⚠️  This Vanta installation (\(rt.home.path)) has no native compiler (native/vantac.py).\n", colour: Theme.nRose)
                return
            }
            let out = Self.nativeBuildFolder.appendingPathComponent(plan.file.deletingPathExtension().lastPathComponent)
            args = [vantac.path, plan.file.path, "-o", out.path, "--run"] + config.parsedArguments
            title = "Building \(plan.displayName) (native)"
        } else {
            args = [rt.vantaPy.path, plan.file.path] + config.parsedArguments
        }
        let progArgs = config.parsedArguments.map(ShellWords.quote).joined(separator: " ")
        let configLabel = config.id == RunConfiguration.currentFileID ? "" : "  [\(config.name)]"
        note("▶ \(plan.displayName)\(progArgs.isEmpty ? "" : " " + progArgs)\(configLabel)\n", colour: Theme.nAccent, bold: true)
        buffer.baseDirectory = plan.cwd
        runOutput = ""
        runMainFile = plan.file
        ProblemMatcher.publish([])
        isRunning = true
        lastRunFailed = false
        lastExitCode = nil
        lastDuration = nil
        runningName = plan.displayName
        statusText = "\(title)…"
        startedAt = Date()
        s.layout.showBottom(PanelID.console)
        let started = Date()
        runner.start(executable: py, arguments: args, workingDirectory: plan.cwd, environment: config.parsedEnvironment,
            onOutput: { [weak self] out in
                guard let self else { return }
                self.runOutput += out
                self.write(out)
            },
            onFinish: { [weak self] code in
                self?.finish(code: code, started: started, stopped: false)
            })
    }

    private func finish(code: Int32, started: Date, stopped: Bool) {
        flushOutput()
        isRunning = false
        startedAt = nil
        let secs = Date().timeIntervalSince(started)
        lastDuration = secs
        lastExitCode = code
        lastRunFailed = !stopped && code != 0
        let time = Self.formatDuration(secs)
        if stopped {
            statusText = "Stopped after \(time)"
            note("■ stopped after \(time)\n", colour: Theme.nAmber)
        } else if code == 0 {
            statusText = "Finished in \(time)"
            note("✓ exited with code 0 · \(time)\n", colour: Theme.nMint)
        } else {
            statusText = "Exited with code \(code)"
            note("✗ exited with code \(code) · \(time)\n", colour: Theme.nRose)
        }
        let problems = ProblemMatcher.match(ANSIParser.strip(runOutput), resolve: { [buffer] in buffer.resolve($0) }, mainFile: runMainFile)
        ProblemMatcher.publish(problems)
    }

    static func formatDuration(_ s: TimeInterval) -> String {
        if s < 1 { return "\(Int(s * 1000)) ms" }
        if s < 60 { return String(format: "%.2f s", s) }
        return "\(Int(s) / 60)m \(Int(s) % 60)s"
    }

    static var nativeBuildFolder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let u = base.appendingPathComponent("VantaStudio/native", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func stop() {
        guard isRunning else { return }
        runner.stop()
        finish(code: -1, started: startedAt ?? Date(), stopped: true)
    }

    func restart() {
        if isRunning { runner.stop(); isRunning = false }
        if let lastRun { lastRun() } else { run() }
    }

    func sendInput(_ line: String) {
        note(line + "\n", colour: Theme.nBlue)
        if DebugController.shared.isActive && !isRunning { DebugController.shared.sendInput(line) } else { runner.write(line + "\n") }
    }

    /// End of input for `ask` (⌃D).
    func sendEOF() { runner.closeInput() }

    /// The program accepts typed input right now (a run, or a debug session).
    var acceptsInput: Bool { isRunning || DebugController.shared.isActive }

    // MARK: debug sessions share the console

    private var debugStarted: Date?

    func prepareForDebug(name: String, cwd: URL) {
        if Services.shared.settings.prefs.clearConsoleOnRun { clearConsole() }
        note("🐞 debugging \(name)\n", colour: Theme.nAmber, bold: true)
        buffer.baseDirectory = cwd
        runOutput = ""
        ProblemMatcher.publish([])
        debugStarted = Date()
        lastRunFailed = false
        statusText = "Debugging \(name)…"
    }

    func appendProgramOutput(_ text: String) {
        runOutput += text
        write(text)
    }

    func debugEnded(code: Int32?) {
        let secs = Date().timeIntervalSince(debugStarted ?? Date())
        flushOutput()
        if let code {
            lastExitCode = code
            lastRunFailed = code != 0
            note(code == 0 ? "✓ exited with code 0 · \(Self.formatDuration(secs))\n" : "✗ exited with code \(code) · \(Self.formatDuration(secs))\n",
                 colour: code == 0 ? Theme.nMint : Theme.nRose)
            statusText = code == 0 ? "Finished in \(Self.formatDuration(secs))" : "Exited with code \(code)"
        } else {
            note("■ debugging stopped\n", colour: Theme.nAmber)
            statusText = "Stopped"
        }
    }

    // MARK: native build (no run)

    /// Compile the active file to a native executable next to it (`vanta build`).
    func buildNative() {
        guard var plan = plan(RunSettings.shared.selected) else { return }
        guard let vantac = VantaInstall.withCompiler()?.vantac else {
            Services.shared.flash("Native builds need a Vanta installation with native/vantac.py"); return
        }
        guard let py = PythonRunner.findPython() else { return }
        if isRunning { runner.stop() }
        if plan.file.path.hasPrefix(FileManager.default.temporaryDirectory.path) { plan.cwd = Self.nativeBuildFolder }
        let out = plan.file.deletingLastPathComponent().path.hasPrefix(FileManager.default.temporaryDirectory.path)
            ? Self.nativeBuildFolder.appendingPathComponent(plan.file.deletingPathExtension().lastPathComponent)
            : plan.file.deletingPathExtension()
        if Services.shared.settings.prefs.clearConsoleOnRun { clearConsole() }
        note("⚙ vantac \(plan.displayName) → \(out.path)\n", colour: Theme.nAccent, bold: true)
        buffer.baseDirectory = plan.cwd
        runOutput = ""
        runMainFile = plan.file
        isRunning = true
        runningName = plan.displayName
        statusText = "Building \(plan.displayName)…"
        startedAt = Date()
        Services.shared.layout.showBottom(PanelID.console)
        let started = Date()
        runner.start(executable: py, arguments: [vantac.path, plan.file.path, "-o", out.path], workingDirectory: plan.cwd,
            onOutput: { [weak self] s in self?.runOutput += s; self?.write(s) },
            onFinish: { [weak self] code in
                guard let self else { return }
                self.finish(code: code, started: started, stopped: false)
                if code == 0 { self.statusText = "Built \(out.lastPathComponent) in \(Self.formatDuration(Date().timeIntervalSince(started)))" }
            })
    }

    // MARK: headless run (used by the AI agent)

    struct RunResult {
        let output: String
        let failed: Bool      // process exited non-zero (and wasn't a server we timed out)
        var timedOut = false
        var exitCode: Int32 = 0
    }

    /// Run the given source and return what it printed plus whether it failed,
    /// judged by the real process exit code. A long-running program (a web
    /// server, a game loop) is stopped after `timeout` seconds and counted as
    /// success. `ask` gets end-of-input immediately instead of hanging. When
    /// `streaming` is true the output is mirrored to the console live.
    func runAndCapture(_ code: String, streaming: Bool = false, timeout: Double = 18) async -> RunResult {
        guard let rt = runtime else { return RunResult(output: "No Vanta interpreter found.", failed: true) }
        guard let py = PythonRunner.findPython() else { return RunResult(output: "python3 not found.", failed: true) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vanta-agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent("agent-run.va")
        try? code.write(to: tmp, atomically: true, encoding: .utf8)
        let cwd = Services.shared.workspace.root ?? dir
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                if streaming { self.clearConsole(); Services.shared.layout.showBottom(PanelID.console) }
                var buffer = ""
                var done = false
                let finish: (RunResult) -> Void = { r in
                    if done { return }; done = true
                    cont.resume(returning: r)
                }
                self.captureRunner.start(executable: py, arguments: [rt.vantaPy.path, tmp.path], workingDirectory: cwd,
                    onOutput: { s in
                        buffer += s
                        if streaming { self.write(s) }
                    },
                    onFinish: { code in
                        if streaming { self.flushOutput() }
                        finish(RunResult(output: ANSIParser.strip(buffer), failed: code != 0, exitCode: code))
                    })
                self.captureRunner.closeInput()
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, timeout)) {
                    guard !done else { return }
                    self.captureRunner.stop()
                    let note = "\n[still running after \(Int(timeout))s — looks like a server or a game loop; stopped it. Press Run to keep it going.]"
                    buffer += note
                    if streaming { self.write(note) }
                    finish(RunResult(output: ANSIParser.strip(buffer), failed: false, timedOut: true, exitCode: -1))
                }
            }
        }
    }
}
