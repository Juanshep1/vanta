import SwiftUI

/// Registers Vee: the right-hand AI panel (⌘L), ⌘K inline edit, Tab
/// autocomplete, Fix with Vee (console button + editor lightbulb), the
/// searchable Vanta Book sidebar, the AI settings tab and status items.
enum AIModule {
    static func register(_ s: Services) {
        let vee = VeeAssistant.shared
        let inline = InlineEditController.shared
        s.register(vee)
        s.language.inlineCompletionProvider = vee

        KnowledgeBase.shared.load()
        ChatStore.shared.start()
        CodebaseIndex.shared.start()
        Autocomplete.shared.start()

        // views
        s.panels.register(id: PanelID.ai, title: "Vee", icon: "sparkles", location: .auxiliary, order: 0) { AIPanel() }
        s.panels.register(id: PanelID.book, title: "The Vanta Book", icon: "book", location: .sidebar, order: 70) { BookReaderView() }
        s.panels.registerOverlay(id: "ai.inlineEdit") { InlineEditView() }
        s.panels.registerOverlay(id: "ai.lightbulb") { FixLightbulb() }
        s.panels.registerSettingsSection(id: "settings.ai", title: "AI", icon: "sparkles", order: 100) { AISettingsView() }
        s.panels.registerToolbarItem(id: "console.fixWithVee") { FixWithVeeButton() }

        // commands
        let c = s.commands
        let hasEditor = { s.editor != nil }
        c.register(id: "view.toggleAIPanel", title: "Toggle Vee / Add Selection to Chat", category: .view, shortcut: .cmd("l"),
                   group: 1, order: 2) { vee.addSelectionToChat() }
        c.register(id: "ai.inlineEdit", title: "Edit with Vee (⌘K)", category: .ai, shortcut: .cmd("k"),
                   group: 0, order: 0, editorKey: true, isEnabled: hasEditor) { inline.begin() }
        c.register(id: "ai.newChat", title: "New Chat", category: .ai, group: 0, order: 1) {
            s.layout.auxVisible = true; ChatStore.shared.newConversation(); vee.focusToken += 1
        }
        c.register(id: "ai.agentMode", title: "Agent Mode", category: .ai, group: 0, order: 2) {
            s.layout.auxVisible = true; vee.mode = vee.mode == "agent" ? "chat" : "agent"; vee.focusToken += 1
        }
        c.register(id: "ai.askBook", title: "Ask the Book", category: .ai, group: 0, order: 3) {
            s.layout.auxVisible = true; vee.mode = "book"; vee.focusToken += 1
        }
        c.register(id: "ai.stop", title: "Stop Vee", category: .ai, group: 0, order: 4, isEnabled: { vee.busy }) { vee.stop() }

        c.register(id: "ai.fixError", title: "Fix Error with Vee", category: .ai, group: 1, order: 0,
                   isEnabled: { s.editors.activeDocument != nil }) {
            // a failed run first; otherwise the problem at (or nearest to) the caret
            if RunController.shared.lastRunFailed && !RunController.shared.console.isEmpty { vee.fixRunError() }
            else if let (d, uri) = problemAtCursor() { vee.fixDiagnostic(d, uri: uri) }
            else { vee.fixRunError() }
        }
        c.register(id: "ai.fixProblem", title: "Fix Problem at Cursor with Vee", category: .ai, shortcut: .cmdShift("."),
                   group: 1, order: 1, isEnabled: { problemAtCursor() != nil }) {
            if let (d, uri) = problemAtCursor() { vee.fixDiagnostic(d, uri: uri) }
        }
        c.register(id: "ai.explain", title: "Explain This Code", category: .ai, group: 1, order: 2, isEnabled: hasEditor) { vee.explainSelection() }
        c.register(id: "ai.writeTests", title: "Write Tests for This", category: .ai, group: 1, order: 3, isEnabled: hasEditor) { vee.writeTestsForSelection() }

        c.register(id: "ai.acceptSuggestion", title: "Accept Vee's Change", category: .ai, shortcut: KeyShortcut("return", [.cmd]),
                   group: 2, order: 0, isEnabled: { s.editor?.hasInlineDiff == true }) {
            if inline.phase != .idle { inline.accept() }
            else if let pane = s.editor as? EditorPane { pane.acceptInlineDiff() }
        }
        c.register(id: "ai.rejectSuggestion", title: "Reject Vee's Change", category: .ai, group: 2, order: 1,
                   isEnabled: { s.editor?.hasInlineDiff == true }) {
            if inline.phase != .idle { inline.cancel() }
            else if let pane = s.editor as? EditorPane { pane.rejectInlineDiff() }
        }
        c.register(id: "ai.acceptAllChanges", title: "Accept All Agent Changes", category: .ai, group: 2, order: 2,
                   isEnabled: { !ChangeTracker.shared.pending.isEmpty }) { ChangeTracker.shared.acceptAll() }
        c.register(id: "ai.rejectAllChanges", title: "Reject All Agent Changes", category: .ai, group: 2, order: 3,
                   isEnabled: { !ChangeTracker.shared.pending.isEmpty }) { ChangeTracker.shared.rejectAll() }

        c.register(id: "ai.acceptGhostWord", title: "Accept Next Word of Suggestion", category: .ai, shortcut: KeyShortcut("right", [.cmd]),
                   inMenu: false, inPalette: false, editorKey: true, isEnabled: hasEditor) { Autocomplete.shared.acceptNextWord() }
        c.register(id: "ai.toggleAutocomplete", title: "Toggle Tab Autocomplete", category: .ai, group: 3, order: 0) {
            vee.settings.autocomplete.toggle()
            s.flash("Tab autocomplete \(vee.settings.autocomplete ? "on" : "off")")
        }

        AISelfTest.registerCommands(s)

        // status bar
        s.statusBar.register(id: "status.ai", alignment: .right, priority: 60) { AIStatusItem() }
        s.statusBar.register(id: "status.ai.tab", alignment: .right, priority: 59) { AutocompleteStatusItem() }
    }

    static func problemAtCursor() -> (Diagnostic, URL)? {
        let s = Services.shared
        guard let ed = s.editor else { return nil }
        let line = ed.cursorPosition.line
        let diags = s.diagnostics.diagnostics(for: ed.document.uri)
        let d = diags.first { $0.range.start.line == line }
            ?? diags.filter { $0.severity == .error }.min { abs($0.range.start.line - line) < abs($1.range.start.line - line) }
        return d.map { ($0, ed.document.uri) }
    }
}

struct AIStatusItem: View {
    @ObservedObject var vee = VeeAssistant.shared
    var body: some View {
        StatusLabel(icon: vee.busy ? "sparkles" : "sparkle",
                    text: vee.hasKey ? "Vee · \(AIPanel.shortModel(vee.settings.smartModel))" : "Vee: add key",
                    color: vee.busy ? Theme.accent : vee.hasKey ? Theme.muted : Theme.amber,
                    help: "\(vee.providerLabel) · smart \(vee.settings.smartModel) · fast \(vee.settings.fastModel)"
                        + (vee.sessionUsage.total > 0 ? "\nThis session: \(vee.sessionUsage.summary)" : "") + "\nClick to toggle the Vee panel (⌘L)",
                    action: { Services.shared.layout.auxVisible.toggle() })
    }
}

struct AutocompleteStatusItem: View {
    @ObservedObject var vee = VeeAssistant.shared
    var body: some View {
        StatusLabel(icon: vee.settings.autocomplete ? "text.cursor" : "pause.circle",
                    text: vee.settings.autocomplete ? "Tab" : "Tab off",
                    color: vee.settings.autocomplete && vee.hasKey ? Theme.muted : Theme.muted.opacity(0.6),
                    help: "AI Tab autocomplete with \(vee.settings.fastModel) — click to turn \(vee.settings.autocomplete ? "off" : "on")",
                    action: { Services.shared.commands.run("ai.toggleAutocomplete") })
    }
}

/// "Fix with Vee" in the Console header after a failed run.
struct FixWithVeeButton: View {
    @ObservedObject var vee = VeeAssistant.shared
    @ObservedObject var run = RunController.shared
    var body: some View {
        if vee.busy && !vee.status.isEmpty {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(vee.status).font(.system(size: 11)).foregroundColor(Theme.accent).lineLimit(1)
            }
        } else if run.lastRunFailed && !run.console.isEmpty && !run.isRunning {
            Button { vee.fixRunError() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                    Text("Fix with Vee").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentDim))
                .foregroundColor(.white)
            }.buttonStyle(.plain)
                .help("Vee explains the error in plain words and proposes a fix as an inline diff")
        }
    }
}
