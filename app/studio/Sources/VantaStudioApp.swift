import SwiftUI

@main
struct VantaStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 600)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New File") { model.newFile() }.keyboardShortcut("n")
                Button("Open…") { model.open() }.keyboardShortcut("o")
                Divider()
                Button("Save") { _ = model.save() }.keyboardShortcut("s")
            }
            CommandMenu("Run") {
                Button("Run Program") { model.run() }.keyboardShortcut("r")
                Button("Stop") { model.stop() }.keyboardShortcut(".")
            }
        }
    }
}
