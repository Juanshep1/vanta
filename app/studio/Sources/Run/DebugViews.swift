import SwiftUI

// MARK: - Run and Debug sidebar

struct RunSidebarView: View {
    @ObservedObject var run = RunController.shared
    @ObservedObject var debug = DebugController.shared
    @ObservedObject var settings = RunSettings.shared
    @ObservedObject var breakpoints = BreakpointStore.shared
    @State private var editingConfig = false
    @State private var newWatch = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader("Run and Debug") {
                IconButton(icon: "gearshape", help: "Edit configuration") { editingConfig.toggle() }
            }
            launchBar.padding(.horizontal, 12).padding(.bottom, 8)
            if editingConfig { ConfigurationEditor().padding(.horizontal, 12).padding(.bottom, 10) }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if debug.isActive {
                        section("Call Stack", trailing: debug.isPaused ? debug.stopReason : "running") { callStack }
                        section("Variables") { variables }
                    }
                    section("Watch", trailing: nil) { watchList }
                    section("Breakpoints", trailing: breakpointCount == 0 ? nil : "\(breakpointCount)") { breakpointList }
                    if !debug.isActive { section("Interpreter") { interpreter } }
                }
            }
        }
    }

    private var breakpointCount: Int { breakpoints.byURI.values.reduce(0) { $0 + $1.count } }

    // launch row: configuration picker + Run + Debug
    private var launchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button { CommandRegistry.shared.run(debug.isActive ? "debug.continue" : "debug.start") } label: {
                    HStack(spacing: 6) {
                        Image(systemName: debug.isActive ? "play.fill" : "ladybug.fill")
                        Text(debug.isActive ? (debug.isPaused ? "Continue" : "Running…") : "Debug")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentDim))
                    .foregroundColor(.white)
                }.buttonStyle(.plain).disabled(debug.isActive && !debug.isPaused)
                Button { CommandRegistry.shared.run(run.isRunning ? "run.stop" : "run.start") } label: {
                    Image(systemName: run.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 34, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(run.isRunning ? Theme.red.opacity(0.8) : Theme.panel2))
                        .foregroundColor(run.isRunning ? .white : Theme.ink)
                }.buttonStyle(.plain).help(run.isRunning ? "Stop (⌘.)" : "Run without debugging (⌘R)")
            }
            HStack(spacing: 6) {
                ConfigurationMenu()
                Spacer()
                Toggle("Stop on entry", isOn: $settings.stopOnEntry)
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundColor(Theme.muted)
            }
            if debug.isActive { DebugToolbar() }
        }
    }

    // MARK: sections

    private func section<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 10.5)).foregroundColor(Theme.muted) }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
            content()
        }
    }

    private var callStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            if debug.stack.isEmpty {
                Text(debug.isPaused ? "No frames" : "Running — press F6 to pause").font(.system(size: 11.5)).foregroundColor(Theme.muted).padding(.horizontal, 14)
            }
            ForEach(Array(debug.stack.enumerated()), id: \.offset) { i, f in
                Button { debug.selectedFrame = i } label: {
                    HStack(spacing: 6) {
                        Image(systemName: i == 0 ? "arrowtriangle.right.fill" : "circle.fill")
                            .font(.system(size: i == 0 ? 8 : 4)).foregroundColor(i == 0 ? Theme.amber : Theme.muted).frame(width: 10)
                        Text(f.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                        Spacer()
                        Text("\((f.file as NSString).lastPathComponent):\(f.line)").font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
                    }
                    .padding(.horizontal, 12).frame(height: 22)
                    .background(i == debug.selectedFrame ? Theme.panel2 : Color.clear)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private var variables: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !debug.isPaused {
                Text("Pause to inspect variables").font(.system(size: 11.5)).foregroundColor(Theme.muted).padding(.horizontal, 14)
            }
            ForEach(debug.scopes, id: \.ref) { scope in
                let key = "scope/\(scope.name)"
                let open = debug.expanded.contains(key)
                Button { toggle(key, ref: scope.ref) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).frame(width: 12)
                        Text(scope.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 10).frame(height: 21).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if open { VariableRows(ref: scope.ref, depth: 1) }
            }
        }
    }

    private func toggle(_ key: String, ref: Int) {
        if debug.expanded.contains(key) { debug.expanded.remove(key) } else { debug.expanded.insert(key); debug.load(ref: ref) }
    }

    private var watchList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(debug.watches) { w in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(w.expression).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.accent).lineLimit(1)
                        Text("=").foregroundColor(Theme.muted).font(.system(size: 11))
                        if let v = w.value {
                            Text(v.value).font(.system(size: 12, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                        } else if let e = w.error {
                            Text(e).font(.system(size: 11)).foregroundColor(Theme.red).lineLimit(1)
                        } else {
                            Text(debug.isPaused ? "…" : "not paused").font(.system(size: 11)).foregroundColor(Theme.muted)
                        }
                        Spacer()
                        Button { debug.removeWatch(w.expression) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain).foregroundColor(Theme.muted)
                    }
                    .padding(.horizontal, 14).frame(height: 21)
                    if let v = w.value, v.ref > 0 {
                        VariableRows(ref: v.ref, depth: 1).onAppear { debug.load(ref: v.ref) }
                    }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 9)).foregroundColor(Theme.muted)
                TextField("Add expression to watch", text: $newWatch)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .onSubmit { debug.addWatch(newWatch); newWatch = "" }
            }
            .padding(.horizontal, 14).frame(height: 22)
        }
    }

    private var breakpointList: some View {
        VStack(alignment: .leading, spacing: 0) {
            let items = breakpoints.byURI.flatMap { uri, lines in lines.map { (uri, $0) } }
                .sorted { ($0.0.lastPathComponent, $0.1) < ($1.0.lastPathComponent, $1.1) }
            if items.isEmpty {
                Text("Click left of a line number (or press F9) to add one.").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 14)
            }
            ForEach(items, id: \.self.1) { uri, line in BreakpointRow(uri: uri, line: line) }
            if !items.isEmpty {
                Button("Remove all") { for u in Array(breakpoints.byURI.keys) { breakpoints.set([], for: u) } }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(Theme.muted).padding(.horizontal, 14).padding(.top, 4)
            }
        }
    }

    private var interpreter: some View {
        VStack(alignment: .leading, spacing: 6) {
            let rt = run.runtime
            HStack(spacing: 6) {
                Image(systemName: rt?.supportsDebugJSON == true ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(rt?.supportsDebugJSON == true ? Theme.green : Theme.amber).font(.system(size: 11))
                Text(rt.map { "Vanta \($0.version) · \($0.source)" } ?? "No interpreter found").font(.system(size: 11.5))
            }
            Text(rt?.home.path ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.muted).lineLimit(2).textSelection(.enabled)
            if rt?.supportsDebugJSON != true {
                Text("Debugging needs a Vanta install with `vanta debug --json`.").font(.system(size: 11)).foregroundColor(Theme.muted)
            }
            HStack(spacing: 6) {
                TextField("Vanta folder (auto)", text: $settings.vantaHome)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11))
                Button("Choose…") { chooseHome() }.font(.system(size: 11))
            }
            Text(PythonRunner.findPython().map { "python: \($0)" } ?? "python3 not found — set it in Settings › Run")
                .font(.system(size: 10.5)).foregroundColor(Theme.muted)
        }
        .padding(.horizontal, 14).padding(.bottom, 12)
    }

    private func chooseHome() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false
        p.message = "Choose the folder that contains vanta.py"
        if p.runModal() == .OK, let u = p.url { settings.vantaHome = u.path }
    }
}

struct BreakpointRow: View {
    let uri: URL
    let line: Int
    @ObservedObject var settings = RunSettings.shared
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(settings.condition(uri, line) == nil ? Theme.red : Theme.amber).frame(width: 8, height: 8)
                Button {
                    let p = TextPosition(line: line, column: 0)
                    Services.shared.editors.open(location: Location(uri: uri, range: TextRange(start: p, end: p)))
                } label: {
                    HStack(spacing: 4) {
                        Text(uri.lastPathComponent).font(.system(size: 12))
                        Text("\(line + 1)").font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.muted)
                    }
                }.buttonStyle(.plain)
                if let c = settings.condition(uri, line), !editing {
                    Text("if \(c)").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.amber).lineLimit(1)
                }
                Spacer()
                Button { text = settings.condition(uri, line) ?? ""; editing.toggle() } label: {
                    Image(systemName: "questionmark.diamond").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(Theme.muted).help("Condition")
                Button { BreakpointStore.shared.toggle(line, in: uri); settings.setCondition(nil, uri, line) } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                }.buttonStyle(.plain).foregroundColor(Theme.muted).help("Remove")
            }
            if editing {
                TextField("Stop only when… e.g. i is 3", text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                    .onSubmit { settings.setCondition(text, uri, line); editing = false }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 2)
    }
}

/// A lazily expanded tree of debugger variables.
struct VariableRows: View {
    @ObservedObject var debug = DebugController.shared
    let ref: Int
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let vars = debug.children[ref] {
                if vars.isEmpty {
                    Text("empty").font(.system(size: 11)).foregroundColor(Theme.muted).padding(.leading, CGFloat(depth) * 12 + 24).frame(height: 19)
                }
                ForEach(vars) { v in VariableRow(variable: v, depth: depth) }
            } else {
                Text("loading…").font(.system(size: 11)).foregroundColor(Theme.muted).padding(.leading, CGFloat(depth) * 12 + 24).frame(height: 19)
            }
        }
    }
}

struct VariableRow: View {
    @ObservedObject var debug = DebugController.shared
    let variable: DebugSession.Variable
    let depth: Int

    var body: some View {
        let key = "var/\(variable.id)"
        let open = debug.expanded.contains(key)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if variable.ref > 0 {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold)).frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }
                Text(variable.name).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.accent).lineLimit(1)
                Text(":").foregroundColor(Theme.muted).font(.system(size: 11))
                Text(variable.value).font(.system(size: 12, design: .monospaced)).foregroundColor(colour).lineLimit(1)
                Spacer(minLength: 4)
                Text(variable.count.map { "\(variable.type) (\($0))" } ?? variable.type)
                    .font(.system(size: 10)).foregroundColor(Theme.muted).lineLimit(1)
            }
            .padding(.leading, CGFloat(depth) * 12 + 2).padding(.trailing, 10).frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture {
                guard variable.ref > 0 else { return }
                if open { debug.expanded.remove(key) } else { debug.expanded.insert(key); debug.load(ref: variable.ref) }
            }
            .help("\(variable.name) = \(variable.value)")
            .contextMenu {
                Button("Copy Value") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(variable.value, forType: .string) }
                Button("Add to Watch") { debug.addWatch(variable.name) }
            }
            if open && variable.ref > 0 { VariableRows(ref: variable.ref, depth: depth + 1) }
        }
    }

    private var colour: Color {
        switch variable.type {
        case "text": return Color(nsColor: Theme.nstr)
        case "number": return Color(nsColor: Theme.nnum)
        case "yes/no", "nothing": return Color(nsColor: Theme.nconst)
        default: return Theme.ink
        }
    }
}

/// Edit the selected run configuration (name, target, args, env, cwd, mode).
struct ConfigurationEditor: View {
    @ObservedObject var settings = RunSettings.shared

    var body: some View {
        let isDefault = settings.selectedID == RunConfiguration.currentFileID
        VStack(alignment: .leading, spacing: 7) {
            field("Name") {
                TextField("Name", text: binding(\.name)).textFieldStyle(.roundedBorder).disabled(isDefault)
            }
            field("Runs") {
                Picker("", selection: targetKind) {
                    Text("Current file").tag(0)
                    Text("Workspace entry (vanta.json main)").tag(1)
                    Text("A file…").tag(2)
                }.labelsHidden()
            }
            if case .file = settings.selected.target {
                field("File") { TextField("path/to/main.va", text: filePath).textFieldStyle(.roundedBorder) }
            }
            field("Arguments") { TextField("--flag \"two words\"", text: binding(\.arguments)).textFieldStyle(.roundedBorder) }
            field("Folder") { TextField("program's folder · ${workspace}", text: binding(\.workingDirectory)).textFieldStyle(.roundedBorder) }
            field("Environment") {
                TextEditor(text: binding(\.environment))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
            }
            field("Mode") {
                Picker("", selection: binding(\.mode)) {
                    ForEach(RunMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Button("Duplicate") { settings.addConfiguration(settings.selected) }
                Button("New") { settings.addConfiguration() }
                Spacer()
                if !isDefault { Button("Delete", role: .destructive) { settings.remove(settings.selectedID) } }
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 11.5))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2.opacity(0.5)))
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10.5, weight: .medium)).foregroundColor(Theme.muted)
            c()
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<RunConfiguration, T>) -> Binding<T> {
        Binding(get: { settings.selected[keyPath: kp] }, set: { var c = settings.selected; c[keyPath: kp] = $0; settings.selected = c })
    }

    private var targetKind: Binding<Int> {
        Binding(get: {
            switch settings.selected.target { case .currentFile: return 0; case .entryPoint: return 1; case .file: return 2 }
        }, set: { k in
            var c = settings.selected
            c.target = k == 0 ? .currentFile : k == 1 ? .entryPoint : .file(Services.shared.editors.activeDocument?.url.map { relative($0) } ?? "main.va")
            settings.selected = c
        })
    }

    private var filePath: Binding<String> {
        Binding(get: { if case .file(let p) = settings.selected.target { return p }; return "" },
                set: { var c = settings.selected; c.target = .file($0); settings.selected = c })
    }

    private func relative(_ u: URL) -> String {
        guard let root = Services.shared.workspace.root?.path, u.path.hasPrefix(root + "/") else { return u.path }
        return String(u.path.dropFirst(root.count + 1))
    }
}

// MARK: - Debug console (bottom panel)

struct DebugConsoleView: View {
    @ObservedObject var debug = DebugController.shared
    @State private var input = ""
    @State private var history: [String] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(debug.isPaused ? "Paused in \(debug.stack.indices.contains(debug.selectedFrame) ? debug.stack[debug.selectedFrame].name : "?")"
                     : debug.isActive ? "Running" : "Not debugging")
                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                Spacer()
                Button { debug.clearConsole() } label: { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted).help("Clear")
            }
            .padding(.horizontal, 12).frame(height: 24)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if debug.consoleEntries.isEmpty {
                            Text("Evaluate Vanta expressions here while the program is paused — e.g. `total * 2` or `length(items)`.")
                                .font(.system(size: 12)).foregroundColor(Theme.muted)
                        }
                        ForEach(debug.consoleEntries) { e in entry(e).id(e.id) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: debug.consoleEntries.count) { _, _ in
                    if let last = debug.consoleEntries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            HStack(spacing: 8) {
                Text("›").foregroundColor(debug.isPaused ? Theme.accent : Theme.muted).font(.system(size: 13, weight: .bold, design: .monospaced))
                TextField(debug.isPaused ? "Evaluate an expression in the selected frame" : "Pause at a breakpoint to evaluate", text: $input)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced))
                    .focused($focused)
                    .onSubmit {
                        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        history.append(input)
                        debug.evaluate(input)
                        input = ""
                        focused = true
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panel2.opacity(0.6))
        }
    }

    @ViewBuilder private func entry(_ e: DebugController.ConsoleEntry) -> some View {
        switch e.kind {
        case .input:
            Text("› " + e.text).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.accent).textSelection(.enabled)
        case .result:
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(e.text).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                    if let v = e.variable { Text(v.type).font(.system(size: 10)).foregroundColor(Theme.muted) }
                }
                if let v = e.variable, v.ref > 0 { VariableRows(ref: v.ref, depth: 0) }
            }
        case .error:
            Text(e.text).font(.system(size: 12.5, design: .monospaced)).foregroundColor(Theme.red).textSelection(.enabled)
        case .info:
            Text(e.text).font(.system(size: 11.5)).foregroundColor(Theme.muted).textSelection(.enabled)
        }
    }
}
