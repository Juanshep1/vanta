import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAI = true
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showAI: $showAI, showSettings: $showSettings)
            Rectangle().fill(Theme.line).frame(height: 1)
            HSplitView {
                Sidebar()
                    .frame(minWidth: 170, idealWidth: 205, maxWidth: 300)
                VSplitView {
                    EditorArea()
                        .frame(minHeight: 180)
                    ConsoleArea()
                        .frame(minHeight: 120, idealHeight: 200)
                }
                .frame(minWidth: 360)
                if showAI {
                    AIPanel()
                        .frame(minWidth: 290, idealWidth: 350, maxWidth: 480)
                }
            }
            StatusBar()
        }
        .background(Theme.bg)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @Binding var showAI: Bool
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Vanta").font(.system(size: 15, weight: .semibold))
                + Text(" Studio").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.accent)

            Divider().frame(height: 18)

            if model.isRunning {
                ToolButton(title: "Stop", systemImage: "stop.fill", tint: Theme.red) { model.stop() }
            } else {
                ToolButton(title: "Run", systemImage: "play.fill", tint: Theme.accent, filled: true) { model.run() }
            }
            ToolButton(title: "New", systemImage: "doc.badge.plus") { model.newFile() }
            ToolButton(title: "Open", systemImage: "folder") { model.open() }
            ToolButton(title: "Save", systemImage: "square.and.arrow.down") { _ = model.save() }

            Spacer()

            ToolButton(title: "Vee", systemImage: "sparkles", tint: showAI ? Theme.accent : Theme.muted) { showAI.toggle() }
            ToolButton(title: "AI Settings", systemImage: "gearshape") { showSettings = true }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.panel)
        .foregroundColor(Theme.ink)
    }
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.ink
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 11).padding(.vertical, 6)
                .foregroundColor(filled ? .white : tint)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(filled ? Theme.accentDim : Theme.panel2)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line, lineWidth: filled ? 0 : 1))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                label("FILES")
                Spacer()
                Button { model.newFile() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                }.buttonStyle(.plain).foregroundColor(Theme.muted).padding(.trailing, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.files) { f in
                        row(name: f.name + (f.dirty ? " •" : ""), active: f.id == model.activeID)
                            .onTapGesture { model.select(f.id) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
    }

    func label(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .bold)).tracking(1.5)
            .foregroundColor(Theme.muted).padding(.horizontal, 14).padding(.vertical, 8)
    }

    func row(name: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(Theme.muted)
            Text(name).font(.system(size: 12.5)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .foregroundColor(active ? Theme.ink : Theme.muted)
        .background(active ? Theme.panel2 : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Editor

struct EditorArea: View {
    @EnvironmentObject var model: AppModel

    private var binding: Binding<String> {
        Binding(get: { model.activeFile?.content ?? "" },
                set: { model.updateActiveContent($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.files) { f in
                        HStack(spacing: 6) {
                            Text(f.name).font(.system(size: 12, design: .monospaced))
                            Button { model.closeFile(f.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8))
                            }.buttonStyle(.plain).foregroundColor(Theme.muted)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 7)
                        .foregroundColor(f.id == model.activeID ? Theme.ink : Theme.muted)
                        .background(f.id == model.activeID ? Theme.panel : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .onTapGesture { model.select(f.id) }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6)
            }
            .background(Theme.bg)

            CodeEditor(text: binding,
                       onInlineEdit: { range, sel in model.beginInlineEdit(range: range, selection: sel) },
                       requestCompletion: { prefix, suffix, done in
                           model.requestCompletion(prefix: prefix, suffix: suffix, done: done)
                       },
                       autocompleteEnabled: model.settings.autocomplete)
                .id(model.activeID)
        }
        .background(Theme.nbgColor)
        .overlay(alignment: .top) {
            if model.inlinePhase != .idle { InlineEditSheet().environmentObject(model) }
        }
    }
}

// MARK: - ⌘K inline edit overlay

struct InlineEditSheet: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "command").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.accent)
                Text("Inline edit").font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button { model.cancelInlineEdit() } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }.buttonStyle(.plain).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider().overlay(Theme.line)

            if model.inlinePhase == .prompting || model.inlinePhase == .generating {
                HStack(spacing: 8) {
                    TextField("Tell Vee how to change this code…", text: $model.inlinePrompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.ink)
                        .focused($focused)
                        .onSubmit { model.submitInlineEdit() }
                        .disabled(model.inlinePhase == .generating)
                    if model.inlinePhase == .generating {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { model.submitInlineEdit() } label: {
                            Text("Generate ⏎").font(.system(size: 11.5, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Theme.accentDim).foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(12)
                .onAppear { focused = true }
                if let err = model.inlineError {
                    Text(err).font(.system(size: 11.5)).foregroundColor(Theme.red)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                }
            } else if model.inlinePhase == .reviewing {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.inlineDiff) { line in
                            HStack(spacing: 6) {
                                Text(symbol(line.kind)).font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(color(line.kind)).frame(width: 12, alignment: .leading)
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(line.kind == .remove ? Theme.muted : Theme.ink)
                                    .strikethrough(line.kind == .remove)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 1)
                            .background(bg(line.kind))
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
                Divider().overlay(Theme.line)
                HStack(spacing: 8) {
                    Spacer()
                    Button { model.cancelInlineEdit() } label: {
                        Text("Reject").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.panel2).foregroundColor(Theme.ink)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).keyboardShortcut(.cancelAction)
                    Button { model.acceptInlineEdit() } label: {
                        Text("Accept ⏎").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.green).foregroundColor(.black)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .frame(width: 460)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .padding(.top, 14)
    }

    func symbol(_ k: DiffKind) -> String { k == .add ? "+" : (k == .remove ? "−" : "") }
    func color(_ k: DiffKind) -> Color { k == .add ? Theme.green : (k == .remove ? Theme.red : Theme.muted) }
    func bg(_ k: DiffKind) -> Color {
        k == .add ? Theme.green.opacity(0.12) : (k == .remove ? Theme.red.opacity(0.10) : Color.clear)
    }
}

// MARK: - Console

struct ConsoleArea: View {
    @EnvironmentObject var model: AppModel
    @State private var stdinText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("CONSOLE").font(.system(size: 10.5, weight: .bold)).tracking(1.5).foregroundColor(Theme.muted)
                Spacer()
                if model.aiBusy && !model.agentStatus.isEmpty {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(model.agentStatus).font(.system(size: 11)).foregroundColor(Theme.accent)
                    }
                } else if model.consoleHasError && !model.isRunning {
                    Button { model.fixWithVee() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                            Text("Fix with Vee").font(.system(size: 11.5, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accentDim))
                        .foregroundColor(.white)
                    }.buttonStyle(.plain)
                        .help("Vee reads the error, fixes your code, applies it, and re-runs to confirm")
                }
                Button { model.console = "" } label: {
                    Text("clear").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundColor(Theme.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.console.isEmpty ? "Press Run to execute your Vanta program." : model.console)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(model.console.isEmpty ? Theme.muted : Theme.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("bottom")
                }
                .onChange(of: model.console) { _, _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            if model.isRunning {
                HStack(spacing: 8) {
                    Text("›").foregroundColor(Theme.accent).font(.system(size: 13, design: .monospaced))
                    TextField("type input for `ask`…", text: $stdinText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(Theme.ink)
                        .onSubmit { model.sendInput(stdinText); stdinText = "" }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Theme.panel)
            }
        }
        .background(Theme.panel)
        .foregroundColor(Theme.ink)
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(model.isRunning ? Theme.accent : Theme.green).frame(width: 7, height: 7)
            Text(model.statusText).font(.system(size: 11.5))
            Spacer()
            Text(PythonRunner.findPython() != nil ? "python3 ✓" : "python3 not found")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(PythonRunner.findPython() != nil ? Theme.muted : Theme.red)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.panel)
        .foregroundColor(Theme.muted)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}

extension Theme {
    static let nbgColor = Color(red: 0.066, green: 0.063, blue: 0.102)
}
