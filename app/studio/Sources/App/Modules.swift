import Foundation

/// Every module registers itself here, once, at launch — before any window or
/// menu is built. Phase-2 modules don't edit this file: they fill in the
/// `register(_:)` function that already lives in their own folder.
enum Modules {
    private static var registered = false

    static func registerAll(_ s: Services = .shared) {
        guard !registered else { return }
        registered = true
        ShellModule.register(s)       // Shell/ShellModule.swift   — file/view/go commands, explorer, search, outline, book, problems
        EditorModule.register(s)      // Editor/EditorModule.swift — editing commands
        LanguageModule.register(s)    // Language/LanguageModule.swift — symbols, completion, diagnostics, tests
        RunModule.register(s)         // Run/RunController.swift   — run, console, terminal, debugger, git
        AIModule.register(s)          // AI/AIModule.swift         — Vee panel, ⌘K, autocomplete
    }
}

/// Launch sequence shared by the app and the --snapshot hook.
enum Bootstrap {
    static func start(workspace: URL? = nil, files: [URL] = [], restoreLast: Bool) {
        let s = Services.shared
        Modules.registerAll(s)
        s.settings.applyAppearance()
        if let ws = workspace {
            s.workspace.open(ws)
            if files.isEmpty && !s.isSnapshot { s.editors.restoreSession() }
        } else if restoreLast, s.settings.prefs.reopenLastWorkspace, let last = s.workspace.lastWorkspace {
            s.workspace.open(last)
            s.editors.restoreSession()
        }
        for f in files { s.editors.open(f, focus: false) }
        if s.editors.activeDocument == nil && s.workspace.root == nil {
            let d = s.documents.newUntitled(text: AppActions.welcomeText, name: "welcome.va")
            s.editors.open(document: d, focus: false)
        }
    }
}
