import AppKit

/// Registers every editing command (Edit / Selection menus, editor shortcuts).
enum EditorModule {
    static func register(_ s: Services) {
        let c = s.commands
        func pane() -> EditorPane? { s.editors.activePane }
        func has() -> Bool { pane() != nil }
        let groupLines = 10, groupFind = 20, groupFold = 30, groupMisc = 40

        // Edit
        c.register(id: "editor.toggleComment", title: "Toggle Line Comment", category: .edit, shortcut: .cmd("/"),
                   group: groupLines, order: 0, editorKey: true, isEnabled: has) { pane()?.toggleComment() }
        c.register(id: "editor.indent", title: "Indent Line", category: .edit, shortcut: .cmd("]"),
                   group: groupLines, order: 1, editorKey: true, isEnabled: has) { pane()?.indentLines(by: 1) }
        c.register(id: "editor.outdent", title: "Outdent Line", category: .edit, shortcut: .cmd("["),
                   group: groupLines, order: 2, editorKey: true, isEnabled: has) { pane()?.indentLines(by: -1) }
        c.register(id: "editor.format", title: "Format Document", category: .edit, shortcut: KeyShortcut("f", [.opt, .shift]),
                   group: groupLines, order: 3, editorKey: true, isEnabled: has) { pane()?.formatDocument() }

        c.register(id: "editor.find", title: "Find", category: .edit, shortcut: .cmd("f"),
                   group: groupFind, order: 0, isEnabled: has) { pane()?.showFind(replace: false) }
        c.register(id: "editor.replace", title: "Find and Replace", category: .edit, shortcut: .cmdOpt("f"),
                   group: groupFind, order: 1, isEnabled: has) { pane()?.showFind(replace: true) }
        c.register(id: "editor.findNext", title: "Find Next", category: .edit, shortcut: .cmd("g"),
                   group: groupFind, order: 2, isEnabled: has) { pane()?.findNext(1) }
        c.register(id: "editor.findPrevious", title: "Find Previous", category: .edit, shortcut: .cmdShift("g"),
                   group: groupFind, order: 3, isEnabled: has) { pane()?.findNext(-1) }
        c.register(id: "editor.useSelectionForFind", title: "Use Selection for Find", category: .edit, shortcut: .cmd("e"),
                   group: groupFind, order: 4, isEnabled: has) {
            guard let p = pane() else { return }
            p.find.query = p.selectedText
        }

        c.register(id: "editor.fold", title: "Fold", category: .edit, shortcut: KeyShortcut("[", [.cmd, .opt]),
                   group: groupFold, order: 0, editorKey: true, isEnabled: has) {
            guard let p = pane() else { return }
            p.foldBlock(containing: p.cursorPosition.line)
        }
        c.register(id: "editor.unfold", title: "Unfold", category: .edit, shortcut: KeyShortcut("]", [.cmd, .opt]),
                   group: groupFold, order: 1, editorKey: true, isEnabled: has) {
            guard let p = pane() else { return }
            p.unfold(atLine: p.cursorPosition.line)
        }
        c.register(id: "editor.foldAll", title: "Fold All", category: .edit, shortcut: KeyShortcut("[", [.cmd, .opt, .shift]),
                   group: groupFold, order: 2, editorKey: true, isEnabled: has) { pane()?.foldAll() }
        c.register(id: "editor.unfoldAll", title: "Unfold All", category: .edit, shortcut: KeyShortcut("]", [.cmd, .opt, .shift]),
                   group: groupFold, order: 3, editorKey: true, isEnabled: has) { pane()?.unfoldAll() }

        c.register(id: "editor.triggerSuggest", title: "Trigger Suggest", category: .edit, shortcut: KeyShortcut("space", [.ctrl]),
                   group: groupMisc, order: 0, editorKey: true, isEnabled: has) { pane()?.triggerCompletion(explicit: true) }

        // Selection
        c.register(id: "editor.moveLineUp", title: "Move Line Up", category: .selection, shortcut: .opt("up"),
                   group: 0, order: 0, editorKey: true, isEnabled: has) { pane()?.moveLines(-1) }
        c.register(id: "editor.moveLineDown", title: "Move Line Down", category: .selection, shortcut: .opt("down"),
                   group: 0, order: 1, editorKey: true, isEnabled: has) { pane()?.moveLines(1) }
        c.register(id: "editor.duplicateLine", title: "Duplicate Line", category: .selection, shortcut: .cmdShift("d"),
                   group: 0, order: 2, editorKey: true, isEnabled: has) { pane()?.duplicateLines() }
        c.register(id: "editor.selectLine", title: "Expand Selection to Line", category: .selection,
                   inMenu: true, group: 0, order: 3, editorKey: false, isEnabled: has) {
            guard let p = pane() else { return }
            p.selectLines(p.selectedLineRange)
        }
        c.register(id: "editor.selectNextOccurrence", title: "Add Next Occurrence", category: .selection, shortcut: .cmd("d"),
                   group: 1, order: 0, editorKey: true, isEnabled: has) { pane()?.selectNextOccurrence() }
        c.register(id: "editor.selectAllOccurrences", title: "Select All Occurrences", category: .selection, shortcut: .cmdShift("l"),
                   group: 1, order: 1, editorKey: true, isEnabled: has) { pane()?.selectAllOccurrences() }
        c.register(id: "editor.addCursorAbove", title: "Add Cursor Above", category: .selection, shortcut: KeyShortcut("up", [.cmd, .opt]),
                   group: 1, order: 2, editorKey: true, isEnabled: has) { pane()?.addCursor(-1) }
        c.register(id: "editor.addCursorBelow", title: "Add Cursor Below", category: .selection, shortcut: KeyShortcut("down", [.cmd, .opt]),
                   group: 1, order: 3, editorKey: true, isEnabled: has) { pane()?.addCursor(1) }

        // Go
        c.register(id: "editor.goToDefinition", title: "Go to Definition", category: .go, shortcut: KeyShortcut("f12", []),
                   group: 1, order: 0, editorKey: true, isEnabled: has) { pane()?.goToDefinition() }

        // View: editor appearance toggles
        c.register(id: "editor.toggleWordWrap", title: "Toggle Word Wrap", category: .view, shortcut: .opt("z"),
                   group: 30, order: 0, editorKey: true) { s.settings.prefs.wordWrap.toggle() }
        c.register(id: "editor.zoomIn", title: "Increase Font Size", category: .view, shortcut: .cmd("="),
                   group: 30, order: 1) { s.settings.prefs.fontSize = min(32, s.settings.prefs.fontSize + 1) }
        c.register(id: "editor.zoomOut", title: "Decrease Font Size", category: .view, shortcut: .cmd("-"),
                   group: 30, order: 2) { s.settings.prefs.fontSize = max(8, s.settings.prefs.fontSize - 1) }
        c.register(id: "editor.zoomReset", title: "Reset Font Size", category: .view, shortcut: .cmd("0"),
                   group: 30, order: 3) { s.settings.prefs.fontSize = 13 }
    }
}
