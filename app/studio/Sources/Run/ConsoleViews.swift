import SwiftUI
import AppKit

// MARK: - Console panel

struct ConsoleView: View {
    @ObservedObject var run = RunController.shared
    @ObservedObject var debug = DebugController.shared
    @ObservedObject var panels = PanelRegistry.shared
    @State private var stdinText = ""
    @State private var wrap = true
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack(alignment: .topLeading) {
                ConsoleTextView(buffer: run.buffer, wrap: wrap, version: run.consoleVersion)
                if run.console.isEmpty && !run.isRunning {
                    Text("Press Run (⌘R) to execute your Vanta program.")
                        .font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.muted)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            if run.acceptsInput { inputRow }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if run.isRunning || debug.isActive {
                RunningDot()
                Text(debug.isActive ? "Debugging \(debug.sessionName)" : run.statusText)
                    .font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
                if let t = run.startedAt { ElapsedText(since: t) }
            } else if let code = run.lastExitCode {
                ExitBadge(code: code)
                if let d = run.lastDuration {
                    Text(RunController.formatDuration(d)).font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            ForEach(panels.toolbarItems.filter { $0.id.hasPrefix("console.") }) { $0.makeView() }
            Button { wrap.toggle() } label: {
                Image(systemName: "text.word.spacing").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(wrap ? Theme.accent : Theme.muted).help(wrap ? "Don't wrap lines" : "Wrap lines")
            Button { run.clearConsole() } label: {
                Image(systemName: "trash").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundColor(Theme.muted).help("Clear Console")
        }
        .padding(.horizontal, 12).padding(.top, 4).frame(height: 24)
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            Text("›").foregroundColor(Theme.accent).font(.system(size: 13, weight: .bold, design: .monospaced))
            TextField("input for `ask` — ⏎ sends", text: $stdinText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .focused($inputFocused)
                .onSubmit { run.sendInput(stdinText); stdinText = ""; inputFocused = true }
            if run.isRunning {
                Button("EOF") { run.sendEOF() }
                    .buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.muted)
                    .help("Close the program's input (end of file)")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.panel2.opacity(0.6))
        .onAppear { if !Services.shared.isSnapshot { inputFocused = true } }
    }
}

struct RunningDot: View {
    @State private var on = false
    var body: some View {
        Circle().fill(Theme.amber).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever()) { on = true } }
    }
}

struct ExitBadge: View {
    let code: Int32
    var body: some View {
        let ok = code == 0
        let stopped = code < 0
        HStack(spacing: 4) {
            Image(systemName: stopped ? "stop.fill" : ok ? "checkmark" : "xmark").font(.system(size: 8.5, weight: .bold))
            Text(stopped ? "stopped" : "exit \(code)").font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        }
        .foregroundColor(stopped ? Theme.amber : ok ? Theme.green : Theme.red)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((stopped ? Theme.amber : ok ? Theme.green : Theme.red).opacity(0.14)))
    }
}

struct ElapsedText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            Text(RunController.formatDuration(ctx.date.timeIntervalSince(since)))
                .font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.muted)
        }
    }
}

/// NSTextView attached to the console's shared text storage (fast appends,
/// selection, links).
struct ConsoleTextView: NSViewRepresentable {
    let buffer: ConsoleBuffer
    var wrap: Bool
    var version: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            ConsoleBuffer.open(link)
        }
    }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = !wrap
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        let lm = NSLayoutManager()
        // detach from any earlier (now hidden) console view
        for old in buffer.storage.layoutManagers { buffer.storage.removeLayoutManager(old) }
        buffer.storage.addLayoutManager(lm)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.delegate = context.coordinator
        tv.linkTextAttributes = [.foregroundColor: Theme.nAccent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        sv.documentView = tv
        apply(wrap: wrap, tv: tv, sv: sv)
        buffer.textView = tv
        DispatchQueue.main.async { buffer.scrollToEnd() }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView else { return }
        apply(wrap: wrap, tv: tv, sv: sv)
        if buffer.textView !== tv { buffer.textView = tv }
    }

    private func apply(wrap: Bool, tv: NSTextView, sv: NSScrollView) {
        guard let c = tv.textContainer else { return }
        let isWrapping = c.widthTracksTextView
        guard isWrapping != wrap || c.size.width == 0 else { return }
        sv.hasHorizontalScroller = !wrap
        if wrap {
            c.widthTracksTextView = true
            c.size = NSSize(width: sv.contentSize.width, height: .greatestFiniteMagnitude)
            tv.isHorizontallyResizable = false
            tv.frame.size.width = sv.contentSize.width
        } else {
            c.widthTracksTextView = false
            c.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            tv.isHorizontallyResizable = true
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        }
    }
}

// MARK: - Title bar & status bar

struct RunToolbarButtons: View {
    @ObservedObject var run = RunController.shared
    @ObservedObject var debug = DebugController.shared
    @ObservedObject var settings = RunSettings.shared
    var body: some View {
        HStack(spacing: 6) {
            if debug.isActive {
                DebugToolbar()
            } else if run.isRunning {
                ToolbarPill(title: "Stop", icon: "stop.fill", tint: Theme.red, help: "Stop (⌘.)") { CommandRegistry.shared.run("run.stop") }
            } else {
                ToolbarPill(title: "Run", icon: "play.fill", filled: true, help: "Run \(settings.selected.name) (⌘R)") { CommandRegistry.shared.run("run.start") }
                ToolbarPill(title: "", icon: "ladybug.fill", help: "Start Debugging (F5)") { CommandRegistry.shared.run("debug.start") }
            }
            if settings.configurations.count > 1 { ConfigurationMenu(compact: true) }
        }
    }
}

/// Continue / step / stop buttons shown while debugging.
struct DebugToolbar: View {
    @ObservedObject var debug = DebugController.shared
    var body: some View {
        HStack(spacing: 2) {
            if debug.isPaused {
                dbgButton("play.fill", "Continue (F5)", "debug.continue", Theme.green)
            } else {
                dbgButton("pause.fill", "Pause (F6)", "debug.pause", Theme.amber)
            }
            dbgButton("arrow.turn.down.right", "Step Over (F10)", "debug.stepOver").disabled(!debug.isPaused)
            dbgButton("arrow.down.to.line", "Step Into (F11)", "debug.stepInto").disabled(!debug.isPaused)
            dbgButton("arrow.up.to.line", "Step Out (⇧F11)", "debug.stepOut").disabled(!debug.isPaused)
            dbgButton("arrow.clockwise", "Restart (⌘⇧F5)", "debug.restart", Theme.green)
            dbgButton("stop.fill", "Stop (⇧F5)", "debug.stop", Theme.red)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel2))
    }

    private func dbgButton(_ icon: String, _ help: String, _ cmd: String, _ tint: Color = Theme.ink) -> some View {
        Button { CommandRegistry.shared.run(cmd) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(tint).help(help)
    }
}

struct ConfigurationMenu: View {
    @ObservedObject var settings = RunSettings.shared
    var compact = false
    var body: some View {
        Menu {
            ForEach(settings.configurations) { c in
                Button { settings.selectedID = c.id } label: {
                    if c.id == settings.selectedID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Divider()
            Button("Add Configuration…") {
                settings.addConfiguration()
                Services.shared.layout.showSidebar(PanelID.runDebug)
            }
            Button("Edit Configurations…") { Services.shared.layout.showSidebar(PanelID.runDebug) }
        } label: {
            HStack(spacing: 4) {
                Text(settings.selected.name).font(.system(size: 11.5)).lineLimit(1)
                if settings.selected.mode == .native { Image(systemName: "hammer.fill").font(.system(size: 9)) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundColor(Theme.muted)
        .help("Run configuration")
    }
}

struct RunStatusItem: View {
    @ObservedObject var run = RunController.shared
    @ObservedObject var debug = DebugController.shared
    var body: some View {
        Button { Services.shared.layout.showBottom(PanelID.console) } label: {
            HStack(spacing: 5) {
                Circle().fill(debug.isActive ? (debug.isPaused ? Theme.amber : Theme.blue)
                              : run.isRunning ? Theme.amber : (run.lastRunFailed ? Theme.red : Theme.green))
                    .frame(width: 7, height: 7)
                Text(debug.isPaused ? "Paused · \(debug.stack.first.map { "\($0.name) line \($0.line)" } ?? "")" : run.statusText).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(statusHelp)
    }

    private var statusHelp: String {
        let rt = run.runtime
        return "Vanta \(rt?.version ?? "?") · \(rt?.home.path ?? "no interpreter")\n\(PythonRunner.findPython() ?? "python3 not found")"
    }
}

// MARK: - Terminal panel

struct TerminalPanelView: View {
    @ObservedObject var terms = TerminalManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(terms.sessions) { s in TerminalTab(session: s, active: s.id == terms.active?.id) }
                    }
                }
                Spacer(minLength: 4)
                IconButton(icon: "plus", help: "New Terminal (⌃⇧`)") { CommandRegistry.shared.run("terminal.new") }
                IconButton(icon: "eraser", help: "Clear Terminal") { terms.clearActive() }
                IconButton(icon: "trash", help: "Kill Terminal") { terms.closeActive() }
            }
            .padding(.horizontal, 8).frame(height: 26)
            if let s = terms.active {
                TerminalHost(session: s).id(s.id)
                    .padding(.leading, 6)
            } else {
                PlaceholderPanel(title: "No terminal", icon: "terminal", message: "Press + to start a shell in the workspace folder.")
            }
        }
        .onAppear { terms.ensureSession() }
    }
}

struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let active: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: session.exited == nil ? "terminal" : "xmark.octagon").font(.system(size: 10))
            Text(session.displayTitle).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: 160)
            Button { TerminalManager.shared.close(session) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }.buttonStyle(.plain).opacity(active ? 0.8 : 0.4)
        }
        .foregroundColor(active ? Theme.ink : Theme.muted)
        .padding(.horizontal, 8).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 5).fill(active ? Theme.panel2 : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { TerminalManager.shared.activeID = session.id; TerminalManager.shared.focusActive() }
        .help(session.cwd ?? "")
    }
}

/// Re-parents the session's long-lived terminal view into the panel.
struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    final class Container: NSView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            for v in subviews { if let t = v as? StudioTerminalView { TerminalManager.applyAppearance(t) } }
        }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        attach(to: c)
        return c
    }

    func updateNSView(_ c: Container, context: Context) {
        if session.view.superview !== c { attach(to: c) }
        TerminalManager.applyAppearance(session.view)
    }

    private func attach(to c: Container) {
        let v = session.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor), v.trailingAnchor.constraint(equalTo: c.trailingAnchor),
            v.topAnchor.constraint(equalTo: c.topAnchor), v.bottomAnchor.constraint(equalTo: c.bottomAnchor),
        ])
        TerminalManager.applyAppearance(v)
        if !Services.shared.isSnapshot { DispatchQueue.main.async { v.window?.makeFirstResponder(v) } }
    }
}
