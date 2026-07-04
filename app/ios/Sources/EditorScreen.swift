import SwiftUI

// One file open in the editor, with Run in the toolbar and the console
// sliding up from the bottom.
struct EditorScreen: View {
    @EnvironmentObject var model: AppModel
    let fileName: String
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()
            CodeEditorView(text: $text, fontSize: model.fontSize)
                .ignoresSafeArea(.container, edges: .bottom)
            if model.showConsole {
                ConsoleView()
                    .transition(.move(edge: .bottom))
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
    }
}
