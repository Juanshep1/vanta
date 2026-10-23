import SwiftUI
import AppKit

struct VantaStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var registry = CommandRegistry.shared

    init() {
        Bootstrap.start(restoreLast: true)
    }

    var body: some Scene {
        Window("Vanta Studio", id: "main") {
            MainWindowView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            // Every item below comes from the CommandRegistry.
            CommandGroup(replacing: .newItem) { MenuItems(categories: [.file]) }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .printItem) {}
            CommandGroup(replacing: .textEditing) {}
            CommandGroup(after: .pasteboard) {
                Divider()
                MenuItems(categories: [.edit])
            }
            CommandMenu("Selection") { MenuItems(categories: [.selection]) }
            CommandGroup(before: .toolbar) {
                MenuItems(categories: [.view, .git])
                Divider()
            }
            CommandMenu("Go") { MenuItems(categories: [.go]) }
            CommandMenu("Run") { MenuItems(categories: [.run, .debug, .test, .terminal]) }
            CommandMenu("AI") { MenuItems(categories: [.ai]) }
            CommandGroup(replacing: .help) { MenuItems(categories: [.help]) }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Menu items for one or more command categories (dividers between groups).
struct MenuItems: View {
    let categories: [CommandCategory]
    @ObservedObject var registry = CommandRegistry.shared

    var body: some View {
        let groups = categories.flatMap { registry.menuCommands($0) }
        ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
            if i > 0 { Divider() }
            ForEach(group) { c in
                Button(c.title) { registry.run(c.id) }
                    .keyboardShortcut(c.shortcut?.swiftUI)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StudioSettings.shared.applyAppearance()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let s = Services.shared
        s.editors.saveSession()
        for d in s.documents.dirtyDocuments where !s.documents.confirmClose(d) { return .terminateCancel }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidResignActive(_ notification: Notification) {
        Services.shared.documents.focusChanged()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Services.shared.documents.checkExternalChanges()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { AppActions.openWorkspace(u) }
            else { Services.shared.editors.open(u) }
        }
    }
}
