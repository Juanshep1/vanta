import SwiftUI

// One file open in the editor, with Run in the toolbar, the console sliding
// up from the bottom, and a one-tap AI fix when a run fails.
struct EditorScreen: View {
    @EnvironmentObject var model: AppModel
    let fileName: String
    @State private var text = ""
    @State private var loaded = false

    private var errorHere: RunError? {
        guard let error = model.lastError, error.file == fileName else { return nil }
        return error
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()
            CodeEditorView(text: $text,
                           fontSize: model.fontSize,
                           errorLine: errorHere.map { $0.line })
                .ignoresSafeArea(.container, edges: .bottom)
            VStack(spacing: 0) {
                if let error = errorHere {
                    errorBanner(error)
                }
                if model.showConsole {
                    ConsoleView()
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .animation(.spring(duration: 0.3), value: model.showConsole)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if model.isRunning {
                    Button {
                        model.stopRun()
                    } label: {
                        Image(systemName: "stop.fill").foregroundStyle(Theme.red)
                    }
                } else {
                    Button {
                        model.save(fileName, text)
                        model.currentFile = fileName
                        model.run(fileName)
                    } label: {
                        Image(systemName: "play.fill").foregroundStyle(Theme.green)
                    }
                    .disabled(model.engine.state == .booting)
                }
                if model.artifactHTML != nil {
                    Button {
                        model.showArtifact = true
                    } label: {
                        Image(systemName: "safari").foregroundStyle(Theme.accent)
                    }
                }
                Button {
                    withAnimation { model.showConsole.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(model.showConsole ? Theme.accent : Theme.muted)
                }
            }
        }
        .onAppear {
            if !loaded {
                text = model.contents(of: fileName)
                loaded = true
            }
            model.currentFile = fileName
        }
        .onDisappear { model.save(fileName, text) }
        .onChange(of: text) { model.save(fileName, text) }
        .onChange(of: model.editorReloadToken) {
            // The open file was rewritten from outside (AI fix / vcode) — pull
            // the new contents into the editor so the change shows immediately.
            let latest = model.contents(of: fileName)
            if latest != text { text = latest }
        }
    }

    private func errorBanner(_ error: RunError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(error.line > 0 ? "line \(error.line)" : "error")
                    .font(.caption2.bold()).foregroundStyle(Theme.red)
                Text(error.message)
                    .font(.caption).foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            Spacer()
            if model.fixingWithAI {
                ProgressView().tint(Theme.accent)
            } else {
                Button {
                    model.fixWithAI(file: fileName, source: text) { fixed in
                        text = fixed
                    }
                } label: {
                    Label("AI fix", systemImage: "sparkles")
                        .font(.caption.bold())
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.accentDim.opacity(0.5), in: Capsule())
                        .foregroundStyle(Theme.ink)
                }
            }
            Button {
                model.lastError = nil
            } label: {
                Image(systemName: "xmark").font(.caption2.bold()).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Theme.panel2)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.red.opacity(0.4)), alignment: .top)
    }
}
