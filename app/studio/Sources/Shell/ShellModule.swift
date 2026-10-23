import SwiftUI
import AppKit

/// App-level actions used by commands, menus and views.
enum AppActions {
    static var s: Services { .shared }

    /// ⌘O — choose files and/or a folder. A folder becomes the workspace.
    static func openPanel() {
        guard !s.isSnapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Open a Vanta file, or a folder as your workspace"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        if let dir = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) {
            openWorkspace(dir)
        }
        for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            s.editors.open(u)
        }
    }

    static func openWorkspace(_ url: URL) {
        if s.workspace.root == url.standardizedFileURL { return }
        // ask about unsaved changes before closing the current editors
        for d in s.documents.dirtyDocuments where !s.documents.confirmClose(d) { return }
        s.editors.saveSession()
        s.editors.reset()
        s.workspace.open(url)
        s.editors.restoreSession()
        s.layout.showSidebar(PanelID.explorer)
    }

    static func closeWorkspace() {
        for d in s.documents.dirtyDocuments where !s.documents.confirmClose(d) { return }
        s.editors.saveSession()
        s.editors.reset()
        s.workspace.close()
    }

    static func newFile() {
        let d = s.documents.newUntitled(text: "")
        s.editors.open(document: d)
    }

    static func openExample(_ url: URL) {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let d = s.documents.newUntitled(text: content, name: url.lastPathComponent)
        s.editors.open(document: d)
    }

    static func save() {
        guard let d = s.editors.activeDocument else { return }
        if s.documents.save(d) { s.flash("Saved \(d.name)"); s.workspace.refreshSoon() }
    }

    static func saveAs() {
        guard let d = s.editors.activeDocument else { return }
        if s.documents.saveAs(d) { s.flash("Saved \(d.name)") }
    }

    static let welcomeText = """
    # Welcome to Vanta Studio — the native Mac IDE for Vanta.
    # Runs natively (real python3, not WebAssembly), and Vanta is full-stack:
    # console scripts, JSON APIs, and real web servers. Press Run / ⌘R.

    say "Hello from a native Mac app!"

    let squares be [n * n for each n in range(1, 8)]
    say "Squares: {to_json(squares)}"

    to greet(name)
        if name is ""
            give back "Hello, stranger!"
        otherwise
            give back "Hello, {name}!"
        end
    end

    say greet("Vanta")

    # Want a web page? Uncomment this, press Run, open http://localhost:8080
    # to home(req)
    #     give back "<h1>Served by Vanta</h1><p>It's a real web server.</p>"
    # end
    # serve(8080, home)

    # Or ask Vee (the panel on the right, ⌘L): turn on Agent and say
    # "build me a web page" — it writes it, runs it, and fixes its own errors.

    """
}

/// Registers the shell's commands, sidebar/bottom panels and status-bar items.
enum ShellModule {
    static func register(_ s: Services) {
        registerCommands(s)
        registerPanels(s)
        registerStatusItems(s)
    }

    private static func registerCommands(_ s: Services) {
        let c = s.commands
        let hasDoc = { s.editors.activeDocument != nil }

        // File
        c.register(id: "file.new", title: "New File", category: .file, shortcut: .cmd("n"), group: 0, order: 0) { AppActions.newFile() }
        c.register(id: "file.open", title: "Open…", category: .file, shortcut: .cmd("o"), group: 0, order: 1) { AppActions.openPanel() }
        c.register(id: "file.closeFolder", title: "Close Folder", category: .file, group: 0, order: 2,
                   isEnabled: { s.workspace.root != nil }) { AppActions.closeWorkspace() }
        c.register(id: "file.save", title: "Save", category: .file, shortcut: .cmd("s"), group: 1, order: 0, isEnabled: hasDoc) { AppActions.save() }
        c.register(id: "file.saveAs", title: "Save As…", category: .file, shortcut: .cmdShift("s"), group: 1, order: 1, isEnabled: hasDoc) { AppActions.saveAs() }
        c.register(id: "file.saveAll", title: "Save All", category: .file, shortcut: .cmdOpt("s"), group: 1, order: 2) {
            s.documents.saveAll(); s.flash("Saved all files")
        }
        c.register(id: "file.revert", title: "Revert File", category: .file, group: 1, order: 3,
                   isEnabled: { s.editors.activeDocument?.url != nil }) { s.editors.activeDocument?.reloadFromDisk() }
        c.register(id: "file.closeTab", title: "Close Editor", category: .file, shortcut: .cmd("w"), group: 2, order: 0, isEnabled: hasDoc) {
            s.editors.closeActiveTab()
        }
        c.register(id: "file.revealActive", title: "Reveal Active File in Explorer", category: .file, group: 2, order: 1,
                   isEnabled: { s.editors.activeDocument?.url != nil }) {
            if let u = s.editors.activeDocument?.url { s.workspace.reveal(u); s.layout.showSidebar(PanelID.explorer) }
        }
        c.register(id: "file.revealInFinder", title: "Reveal Active File in Finder", category: .file, group: 2, order: 2,
                   isEnabled: { s.editors.activeDocument?.url != nil }) {
            if let u = s.editors.activeDocument?.url { NSWorkspace.shared.activateFileViewerSelecting([u]) }
        }

        // View
        c.register(id: "view.commandPalette", title: "Command Palette…", category: .view, shortcut: .cmdShift("p"), group: 0, order: 0) {
            s.layout.openQuickPick(">")
        }
        c.register(id: "view.quickOpen", title: "Quick Open…", category: .go, shortcut: .cmd("p"), group: 0, order: 0) {
            s.layout.openQuickPick("")
        }
        c.register(id: "view.toggleSidebar", title: "Toggle Sidebar", category: .view, shortcut: .cmd("b"), group: 1, order: 0) {
            s.layout.sidebarVisible.toggle()
        }
        c.register(id: "view.togglePanel", title: "Toggle Panel", category: .view, shortcut: .cmd("j"), group: 1, order: 1) {
            s.layout.bottomVisible.toggle()
        }
        c.register(id: "view.toggleAIPanel", title: "Toggle AI Panel", category: .view, shortcut: .cmd("l"), group: 1, order: 2) {
            s.layout.auxVisible.toggle()
        }
        c.register(id: "view.toggleAIPanelAlt", title: "Toggle AI Panel", category: .view, shortcut: .cmd("i"),
                   inPalette: false, group: 1, order: 3) { s.layout.auxVisible.toggle() }
        c.register(id: "view.splitEditor", title: "Split Editor", category: .view, shortcut: .cmd("\\"), group: 2, order: 0, isEnabled: hasDoc) {
            s.editors.split()
        }
        c.register(id: "view.focusGroup1", title: "Focus First Editor Group", category: .view, shortcut: .cmd("1"), group: 2, order: 1) { s.editors.focusGroup(0) }
        c.register(id: "view.focusGroup2", title: "Focus Second Editor Group", category: .view, shortcut: .cmd("2"), group: 2, order: 2) { s.editors.focusGroup(1) }
        c.register(id: "view.nextTab", title: "Next Editor", category: .view, shortcut: .cmdShift("]"), group: 2, order: 3) { s.editors.cycleTab(1) }
        c.register(id: "view.prevTab", title: "Previous Editor", category: .view, shortcut: .cmdShift("["), group: 2, order: 4) { s.editors.cycleTab(-1) }

        c.register(id: "view.explorer", title: "Show Explorer", category: .view, shortcut: .cmdShift("e"), group: 3, order: 0) {
            s.layout.showSidebar(PanelID.explorer)
        }
        c.register(id: "view.search", title: "Find in Files", category: .edit, shortcut: .cmdShift("f"), group: 25, order: 0) {
            s.layout.showSidebar(PanelID.search)
        }
        c.register(id: "view.replaceInFiles", title: "Replace in Files", category: .edit, shortcut: .cmdShift("h"), group: 25, order: 1) {
            s.resolve(ProjectSearch.self)?.showReplace = true
            s.layout.showSidebar(PanelID.search)
        }
        c.register(id: "view.outline", title: "Show Outline", category: .view, group: 3, order: 1) { s.layout.showSidebar(PanelID.outline) }
        c.register(id: "view.book", title: "Show The Vanta Book", category: .help, group: 0, order: 0) { s.layout.showSidebar(PanelID.book) }
        c.register(id: "view.problems", title: "Show Problems", category: .view, shortcut: .cmdShift("m"), group: 3, order: 2) {
            s.layout.showBottom(PanelID.problems)
        }
        c.register(id: "view.console", title: "Show Console", category: .view, shortcut: .cmdShift("y"), group: 3, order: 3) {
            s.layout.showBottom(PanelID.console)
        }

        // Go
        c.register(id: "go.line", title: "Go to Line…", category: .go, shortcut: .ctrl("g"), group: 0, order: 1, isEnabled: hasDoc) {
            s.layout.openQuickPick(":")
        }
        c.register(id: "go.symbol", title: "Go to Symbol in File…", category: .go, shortcut: .cmdShift("o"), group: 0, order: 2, isEnabled: hasDoc) {
            s.layout.openQuickPick("@")
        }

        // Help
        c.register(id: "help.docs", title: "Vanta Language Guide", category: .help, group: 0, order: 1) {
            let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("projects/vanta/docs/LANGUAGE_GUIDE.md")
            if FileManager.default.fileExists(atPath: u.path) { s.editors.open(u) } else { s.flash("Language guide not found") }
        }
    }

    private static func registerPanels(_ s: Services) {
        let p = s.panels
        let search = ProjectSearch()
        s.register(search)
        p.register(id: PanelID.explorer, title: "Explorer", icon: "doc.on.doc", location: .sidebar, order: 0) { ExplorerView() }
        p.register(id: PanelID.search, title: "Search", icon: "magnifyingglass", location: .sidebar, order: 10) { SearchView(search: search) }
        p.register(id: PanelID.outline, title: "Outline", icon: "list.bullet.indent", location: .sidebar, order: 60) { OutlineView() }
        p.register(id: PanelID.book, title: "The Vanta Book", icon: "book", location: .sidebar, order: 70) { BookView() }
        p.register(id: PanelID.problems, title: "Problems", icon: "exclamationmark.triangle", location: .bottom, order: 20,
                   badge: {
                       let n = DiagnosticsStore.shared.errorCount + DiagnosticsStore.shared.warningCount
                       return n > 0 ? "\(n)" : nil
                   }) { ProblemsView() }
    }

    private static func registerStatusItems(_ s: Services) {
        let sb = s.statusBar
        sb.register(id: "status.git", alignment: .left, priority: 100) { GitStatusItem() }
        sb.register(id: "status.problems", alignment: .left, priority: 90) { ProblemsStatusItem() }
        sb.register(id: "status.cursor", alignment: .right, priority: 100) { CursorStatusItem() }
        sb.register(id: "status.language", alignment: .right, priority: 80) { LanguageStatusItem() }
    }
}

// MARK: - Status items

struct GitStatusItem: View {
    @ObservedObject var workspace = Services.shared.workspace
    var body: some View {
        if let b = workspace.gitBranch {
            StatusLabel(icon: "arrow.triangle.branch", text: b, help: "Git branch")
        } else if workspace.root != nil {
            StatusLabel(icon: "folder", text: workspace.name)
        }
    }
}

struct ProblemsStatusItem: View {
    @ObservedObject var store = DiagnosticsStore.shared
    var body: some View {
        Button { Services.shared.layout.showBottom(PanelID.problems, toggle: true) } label: {
            HStack(spacing: 8) {
                HStack(spacing: 3) { Image(systemName: "xmark.circle"); Text("\(store.errorCount)") }
                    .foregroundColor(store.errorCount > 0 ? Theme.red : Theme.muted)
                HStack(spacing: 3) { Image(systemName: "exclamationmark.triangle"); Text("\(store.warningCount)") }
                    .foregroundColor(store.warningCount > 0 ? Theme.amber : Theme.muted)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).help("Problems (⌘⇧M)")
    }
}

struct CursorStatusItem: View {
    @ObservedObject var editors = Services.shared.editors
    var body: some View {
        if editors.activeDocument != nil {
            let sel = editors.selectionLength > 0 ? " (\(editors.selectionLength) selected)" : ""
            let cur = editors.cursorCount > 1 ? " · \(editors.cursorCount) cursors" : ""
            StatusLabel(text: "Ln \(editors.cursor.line + 1), Col \(editors.cursor.column + 1)\(sel)\(cur)",
                        help: "Go to Line (⌃G)", action: { Services.shared.layout.openQuickPick(":") })
        }
    }
}

struct LanguageStatusItem: View {
    @ObservedObject var editors = Services.shared.editors
    @ObservedObject var settings = StudioSettings.shared
    var body: some View {
        if let d = editors.activeDocument {
            HStack(spacing: 12) {
                Text("Spaces: \(settings.prefs.tabSize)")
                Text("UTF-8")
                Text(d.language.displayName)
            }
        }
    }
}
