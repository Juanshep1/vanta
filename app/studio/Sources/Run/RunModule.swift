import SwiftUI
import AppKit

/// Pushes git change markers to the editor gutter and redraws panes showing the file.
enum GitGutter {
    static func publish(_ url: URL, _ markers: [Int: LineDiffer.Marker]) {
        let mapped = markers.mapValues { m -> LineChangeKind in
            switch m { case .added: return .added; case .modified: return .modified; case .deletedAbove: return .deletedAbove }
        }
        LineMarkerStore.shared.set(mapped, for: url)
        let s = Services.shared
        for doc in s.documents.documents where doc.url?.standardizedFileURL == url.standardizedFileURL {
            for g in s.editors.groups { g.existingPane(for: doc)?.gutter.needsDisplay = true }
        }
    }
}

/// Registers everything the Run module contributes: run/debug/terminal/git
/// commands, the Console, Terminal and Debug panels, the Run and Debug and
/// Source Control sidebars, the diff overlay, title-bar controls and status items.
enum RunModule {
    static func register(_ s: Services) {
        let run = RunController.shared
        let debug = DebugController.shared
        let git = GitController.shared
        let terms = TerminalManager.shared
        s.register(run); s.register(debug); s.register(git); s.register(terms)
        let c = s.commands
        let hasDoc = { s.editors.activeDocument != nil }

        // MARK: run
        c.register(id: "run.start", title: "Run Program", category: .run, shortcut: .cmd("r"), group: 0, order: 0,
                   isEnabled: { hasDoc() || WorkspaceManifest.entryPoint(s.workspace.root) != nil }) { run.run() }
        c.register(id: "run.stop", title: "Stop", category: .run, shortcut: .cmd("."), group: 0, order: 1,
                   isEnabled: { run.isRunning || debug.isActive }) {
            if debug.isActive { debug.stop() } else { run.stop() }
        }
        c.register(id: "run.restart", title: "Restart Program", category: .run, shortcut: .cmdShift("r"), group: 0, order: 2,
                   isEnabled: hasDoc) { run.restart() }
        c.register(id: "run.currentFile", title: "Run Current File", category: .run, group: 1, order: 0, isEnabled: hasDoc) {
            run.run(configuration: .currentFile)
        }
        c.register(id: "run.entryPoint", title: "Run Workspace Entry Point (vanta.json)", category: .run, group: 1, order: 1,
                   isEnabled: { WorkspaceManifest.entryPoint(s.workspace.root) != nil }) {
            var cfg = RunSettings.shared.selected; cfg.target = .entryPoint; run.run(configuration: cfg)
        }
        c.register(id: "run.native", title: "Build Native and Run", category: .run, group: 1, order: 2, isEnabled: hasDoc) {
            var cfg = RunSettings.shared.selected; cfg.mode = .native; run.run(configuration: cfg)
        }
        c.register(id: "run.buildNative", title: "Build Native Executable", category: .run, shortcut: .cmdShift("b"), group: 1, order: 3,
                   isEnabled: hasDoc) { run.buildNative() }
        c.register(id: "run.configurations", title: "Edit Run Configurations…", category: .run, group: 2, order: 0) {
            s.layout.showSidebar(PanelID.runDebug)
        }
        c.register(id: "run.addConfiguration", title: "Add Run Configuration", category: .run, inMenu: false, group: 2, order: 1) {
            RunSettings.shared.addConfiguration(); s.layout.showSidebar(PanelID.runDebug)
        }
        c.register(id: "run.clearConsole", title: "Clear Console", category: .run, group: 3, order: 0) { run.clearConsole() }
        c.register(id: "run.showConsole", title: "Show Console", category: .run, inMenu: false, group: 3, order: 1) {
            s.layout.showBottom(PanelID.console)
        }

        // MARK: debug
        c.register(id: "debug.start", title: "Start Debugging", category: .debug, shortcut: KeyShortcut("f5", []), group: 0, order: 0,
                   isEnabled: { debug.isPaused || (!debug.isActive && hasDoc()) }) { debug.startOrContinue() }
        c.register(id: "debug.continue", title: "Continue", category: .debug, inMenu: false, group: 0, order: 1,
                   isEnabled: { debug.isPaused }) { debug.continueRun() }
        c.register(id: "debug.pause", title: "Pause", category: .debug, shortcut: KeyShortcut("f6", []), group: 0, order: 2,
                   isEnabled: { debug.state == .running }) { debug.pause() }
        c.register(id: "debug.stop", title: "Stop Debugging", category: .debug, shortcut: KeyShortcut("f5", [.shift]), group: 0, order: 3,
                   isEnabled: { debug.isActive }) { debug.stop() }
        c.register(id: "debug.restart", title: "Restart Debugging", category: .debug, shortcut: KeyShortcut("f5", [.cmd, .shift]), group: 0, order: 4,
                   isEnabled: { debug.isActive }) { debug.restart() }
        c.register(id: "debug.stepOver", title: "Step Over", category: .debug, shortcut: KeyShortcut("f10", []), group: 1, order: 0,
                   isEnabled: { debug.isPaused || (!debug.isActive && hasDoc()) }) { debug.stepOver() }
        c.register(id: "debug.stepInto", title: "Step Into", category: .debug, shortcut: KeyShortcut("f11", []), group: 1, order: 1,
                   isEnabled: { debug.isPaused || (!debug.isActive && hasDoc()) }) { debug.stepInto() }
        c.register(id: "debug.stepOut", title: "Step Out", category: .debug, shortcut: KeyShortcut("f11", [.shift]), group: 1, order: 2,
                   isEnabled: { debug.isPaused }) { debug.stepOut() }
        c.register(id: "debug.toggleBreakpoint", title: "Toggle Breakpoint", category: .debug, shortcut: KeyShortcut("f9", []), group: 2, order: 0,
                   isEnabled: { s.editor != nil }) { debug.toggleBreakpointAtCursor() }
        c.register(id: "debug.removeAllBreakpoints", title: "Remove All Breakpoints", category: .debug, group: 2, order: 1) {
            for u in Array(BreakpointStore.shared.byURI.keys) { BreakpointStore.shared.set([], for: u) }
        }
        c.register(id: "debug.addWatch", title: "Add Selection to Watch", category: .debug, group: 2, order: 2,
                   isEnabled: { !(s.editor?.selectedText.isEmpty ?? true) }) {
            if let t = s.editor?.selectedText { debug.addWatch(t); s.layout.showSidebar(PanelID.runDebug) }
        }
        c.register(id: "debug.evaluateSelection", title: "Evaluate Selection in Debug Console", category: .debug, group: 2, order: 3,
                   isEnabled: { debug.isPaused && !(s.editor?.selectedText.isEmpty ?? true) }) {
            if let t = s.editor?.selectedText { debug.evaluate(t); s.layout.showBottom(PanelID.debugConsole) }
        }

        // MARK: terminal
        c.register(id: "terminal.toggle", title: "Toggle Terminal", category: .terminal, shortcut: KeyShortcut("`", [.ctrl]), group: 0, order: 0) {
            terms.ensureSession()
            s.layout.showBottom(PanelID.terminal, toggle: true)
            if s.layout.bottomVisible { terms.focusActive() }
        }
        c.register(id: "terminal.new", title: "New Terminal", category: .terminal, shortcut: KeyShortcut("`", [.ctrl, .shift]), group: 0, order: 1) {
            terms.newSession(); s.layout.showBottom(PanelID.terminal); terms.focusActive()
        }
        c.register(id: "terminal.newInFileFolder", title: "New Terminal in File's Folder", category: .terminal, group: 0, order: 2,
                   isEnabled: { s.editors.activeDocument?.url != nil }) {
            terms.newSession(cwd: s.editors.activeDocument?.url?.deletingLastPathComponent())
            s.layout.showBottom(PanelID.terminal); terms.focusActive()
        }
        c.register(id: "terminal.kill", title: "Kill Terminal", category: .terminal, group: 1, order: 0,
                   isEnabled: { !terms.sessions.isEmpty }) { terms.closeActive() }
        c.register(id: "terminal.clear", title: "Clear Terminal", category: .terminal, group: 1, order: 1,
                   isEnabled: { !terms.sessions.isEmpty }) { terms.clearActive() }
        c.register(id: "terminal.runFile", title: "Run Current File in Terminal", category: .terminal, group: 1, order: 2,
                   isEnabled: { s.editors.activeDocument?.url != nil }) {
            guard let doc = s.editors.activeDocument, let url = doc.url, let rt = run.runtime else { return }
            if doc.isDirty { doc.save() }
            let py = PythonRunner.findPython() ?? "python3"
            terms.run("\(ShellWords.quote(py)) \(ShellWords.quote(rt.vantaPy.path)) \(ShellWords.quote(url.path))",
                      cwd: url.deletingLastPathComponent())
        }

        // MARK: source control
        c.register(id: "git.refresh", title: "Git: Refresh", category: .git, group: 0, order: 0) { git.refresh(fetch: true) }
        c.register(id: "git.commit", title: "Git: Commit", category: .git, group: 0, order: 1, isEnabled: { git.isRepo }) {
            s.layout.showSidebar(PanelID.sourceControl); git.commit()
        }
        c.register(id: "git.stageAll", title: "Git: Stage All Changes", category: .git, group: 0, order: 2, isEnabled: { git.isRepo }) { git.stageAll() }
        c.register(id: "git.unstageAll", title: "Git: Unstage All Changes", category: .git, group: 0, order: 3, isEnabled: { git.isRepo }) { git.unstageAll() }
        c.register(id: "git.stageFile", title: "Git: Stage Current File", category: .git, group: 0, order: 4,
                   isEnabled: { git.isRepo && s.editors.activeDocument?.url != nil }) {
            if let u = s.editors.activeDocument?.url, let rel = git.relativePath(u) {
                git.stage([GitChange(path: rel, origPath: nil, area: .unstaged, code: "M")])
            }
        }
        c.register(id: "git.diffFile", title: "Git: Open Changes (Diff with HEAD)", category: .git, group: 1, order: 0,
                   isEnabled: { git.isRepo && s.editors.activeDocument?.url != nil }) { git.showDiffForActiveFile() }
        c.register(id: "git.closeDiff", title: "Git: Close Diff", category: .git, inMenu: false, group: 1, order: 1,
                   isEnabled: { git.openDiff != nil }) { git.openDiff = nil }
        c.register(id: "git.pull", title: "Git: Pull", category: .git, group: 2, order: 0, isEnabled: { git.isRepo }) { git.pull() }
        c.register(id: "git.push", title: "Git: Push", category: .git, group: 2, order: 1, isEnabled: { git.isRepo }) { git.push() }
        c.register(id: "git.sync", title: "Git: Sync", category: .git, group: 2, order: 2, isEnabled: { git.isRepo }) { git.sync() }
        c.register(id: "git.checkout", title: "Git: Switch Branch…", category: .git, group: 3, order: 0, isEnabled: { git.isRepo }) {
            s.layout.showSidebar(PanelID.sourceControl)
        }
        c.register(id: "git.showSidebar", title: "Show Source Control", category: .view, inMenu: false) {
            s.layout.showSidebar(PanelID.sourceControl)
        }

        // headless self-test hook: `--snapshot out.png --run run.selftest`
        c.register(id: "run.selftest", title: "Run Module Self-Test", category: .help, inMenu: false, inPalette: false) {
            exit(RunSelfTest.run() ? 0 : 1)
        }

        // snapshot helpers (`--run run.demo.debug` etc.): put the UI in a state worth looking at
        c.register(id: "run.demo.run", title: "Demo: run", category: .help, inMenu: false, inPalette: false) {
            run.run(); RunSelfTest.waitPublic(8) { !run.isRunning }
        }
        c.register(id: "run.demo.debug", title: "Demo: debug", category: .help, inMenu: false, inPalette: false) {
            guard let ed = s.editor else { return }
            let lines = ed.text.components(separatedBy: "\n")
            // break inside the first function body if there is one, else on line 3
            let target = lines.firstIndex { $0.hasPrefix("    ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 2
            BreakpointStore.shared.set([target], for: ed.document.uri)
            debug.addWatch("total")
            debug.start()
            RunSelfTest.waitPublic(10) { debug.isPaused }
            for sc in debug.scopes { debug.load(ref: sc.ref) }
            RunSelfTest.waitPublic(1) { false }
            debug.evaluate("1 + 2")
            RunSelfTest.waitPublic(1) { false }
        }
        c.register(id: "run.demo.diff", title: "Demo: diff", category: .help, inMenu: false, inPalette: false) {
            RunSelfTest.waitPublic(4) { git.isRepo }
            if let ch = git.unstaged.first ?? git.staged.first { git.showDiff(ch) } else { git.showDiffForActiveFile() }
            RunSelfTest.waitPublic(4) { git.openDiff != nil }
        }
        c.register(id: "run.demo.inline", title: "Demo: inline diff", category: .help, inMenu: false, inPalette: false) {
            RunSelfTest.inlineDiffDemo = true
        }
        c.register(id: "run.demo.terminal", title: "Demo: terminal", category: .help, inMenu: false, inPalette: false) {
            terms.ensureSession()
            s.layout.showBottom(PanelID.terminal)
            RunSelfTest.waitPublic(2.5) { false }
            terms.active?.send("printf '\\033[1;35mVanta\\033[0m \\033[38;5;214m256\\033[0m \\033[38;2;80;200;160mtruecolor\\033[0m\\n'; ls -G\r")
            RunSelfTest.waitPublic(1.5) { false }
            // note: SwiftTerm draws in a layer-backed view, so `--snapshot` composites of the
            // whole window show the terminal area empty; the emulator itself is tested in run.selftest.
        }

        c.register(id: "run.demo.wait", title: "Demo: wait for git", category: .help, inMenu: false, inPalette: false) {
            RunSelfTest.waitPublic(5) { git.isRepo && !git.history.isEmpty }
        }

        // MARK: views
        s.panels.registerToolbarItem(id: "run.buttons") { RunToolbarButtons() }
        s.panels.register(id: PanelID.console, title: "Console", icon: "text.alignleft", location: .bottom, order: 0) { ConsoleView() }
        s.panels.register(id: PanelID.terminal, title: "Terminal", icon: "terminal", location: .bottom, order: 10,
                          badge: { terms.sessions.count > 1 ? "\(terms.sessions.count)" : nil }) { TerminalPanelView() }
        s.panels.register(id: PanelID.debugConsole, title: "Debug Console", icon: "ladybug", location: .bottom, order: 40) { DebugConsoleView() }
        s.panels.register(id: PanelID.sourceControl, title: "Source Control", icon: "arrow.triangle.branch", location: .sidebar, order: 20,
                          badge: { git.changeCount > 0 ? "\(git.changeCount)" : nil }) { SourceControlView() }
        s.panels.register(id: PanelID.runDebug, title: "Run and Debug", icon: "play.circle", location: .sidebar, order: 30,
                          badge: { debug.isPaused ? "‖" : nil }) { RunSidebarView() }
        s.panels.registerOverlay(id: "run.diff") { DiffOverlay() }
        s.statusBar.register(id: "status.run", alignment: .left, priority: 80) { RunStatusItem() }
        s.statusBar.register(id: "status.git", alignment: .left, priority: 100) { GitBranchStatusItem() }

        git.attach(s)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            run.stop(); debug.stop(); terms.terminateAll()
        }
    }
}
