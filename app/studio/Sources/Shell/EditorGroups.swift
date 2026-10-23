import AppKit
import Combine

final class EditorTab: ObservableObject, Identifiable, Equatable {
    let id = UUID()
    let document: Document
    /// Preview tabs (single-click in the explorer) are replaced by the next
    /// preview; editing or double-clicking pins them.
    @Published var isPreview: Bool
    init(document: Document, isPreview: Bool) { self.document = document; self.isPreview = isPreview }
    static func == (a: EditorTab, b: EditorTab) -> Bool { a.id == b.id }
}

/// One editor column: a tab strip and the panes for its documents.
final class EditorGroup: ObservableObject, Identifiable {
    let id = UUID()
    @Published var tabs: [EditorTab] = []
    @Published var activeTabID: UUID?
    private var panes: [UUID: EditorPane] = [:]           // by document id

    var activeTab: EditorTab? { tabs.first { $0.id == activeTabID } ?? tabs.last }
    var activeDocument: Document? { activeTab?.document }
    var activePane: EditorPane? { activeDocument.map { pane(for: $0) } }

    func pane(for doc: Document) -> EditorPane {
        if let p = panes[doc.id] { return p }
        let p = EditorPane(document: doc)
        panes[doc.id] = p
        return p
    }

    func existingPane(for doc: Document) -> EditorPane? { panes[doc.id] }

    func discardPane(for doc: Document) {
        panes[doc.id]?.close()
        panes[doc.id]?.removeFromSuperview()
        panes[doc.id] = nil
    }

    func contains(_ doc: Document) -> Bool { tabs.contains { $0.document.id == doc.id } }
}

/// The editor area: groups (split editor), tabs, the focused pane, cursor info
/// and open/close logic.
final class EditorGroups: ObservableObject {
    @Published private(set) var groups: [EditorGroup] = [EditorGroup()]
    @Published private(set) var activeGroupID: UUID?
    @Published private(set) var cursor = TextPosition(line: 0, column: 0)
    @Published private(set) var selectionLength = 0
    @Published private(set) var cursorCount = 1
    /// Bumps whenever the focused document changes (status bar / outline observe it).
    @Published private(set) var activeDocumentID: UUID?
    /// Most-recently opened files (for Quick Open).
    @Published private(set) var history: [URL] = []

    private var bag: [UUID: AnyCancellable] = [:]

    var activeGroup: EditorGroup { groups.first { $0.id == activeGroupID } ?? groups[0] }
    var activePane: EditorPane? { activeGroup.activePane }
    var activeDocument: Document? { activeGroup.activeDocument }
    var services: Services { .shared }

    // MARK: open

    @discardableResult
    func open(_ url: URL, preview: Bool = false, focus: Bool = true) -> EditorPane? {
        guard let doc = services.documents.open(url) else { return nil }
        history.removeAll { $0 == doc.url }
        if let u = doc.url { history.insert(u, at: 0) }
        if history.count > 50 { history.removeLast() }
        return open(document: doc, preview: preview, focus: focus)
    }

    @discardableResult
    func open(document doc: Document, preview: Bool = false, focus: Bool = true, in group: EditorGroup? = nil) -> EditorPane {
        let g = group ?? activeGroup
        if let tab = g.tabs.first(where: { $0.document.id == doc.id }) {
            if !preview { tab.isPreview = false }
            g.activeTabID = tab.id
        } else {
            let tab = EditorTab(document: doc, isPreview: preview)
            if preview, let i = g.tabs.firstIndex(where: { $0.isPreview }) {
                let old = g.tabs[i]
                g.tabs[i] = tab
                release(old.document, from: g)
            } else if let ai = g.tabs.firstIndex(where: { $0.id == g.activeTabID }) {
                g.tabs.insert(tab, at: ai + 1)
            } else {
                g.tabs.append(tab)
            }
            g.activeTabID = tab.id
            // editing pins a preview tab
            bag[tab.id] = doc.changes.first().sink { [weak tab] _ in tab?.isPreview = false }
        }
        activeGroupID = g.id
        let pane = g.pane(for: doc)
        documentFocused()
        if focus { DispatchQueue.main.async { pane.focus() } }
        saveSession()
        return pane
    }

    func open(location: Location) {
        let pane: EditorPane?
        if location.uri.isFileURL { pane = open(location.uri) }
        else { pane = services.documents.documents.first { $0.uri == location.uri }.map { open(document: $0) } }
        guard let pane else { return }
        DispatchQueue.main.async {
            pane.scrollToLine(location.range.start.line, select: true)
            let s = pane.offset(of: location.range.start)
            let e = pane.offset(of: location.range.end)
            pane.textView.setSelectedRange(NSRange(location: s, length: max(0, e - s)))
        }
    }

    // MARK: focus & cursor

    func focus(pane: EditorPane) {
        if let g = groups.first(where: { $0.existingPane(for: pane.document) === pane }) {
            if activeGroupID != g.id { activeGroupID = g.id }
            if let t = g.tabs.first(where: { $0.document.id == pane.document.id }), g.activeTabID != t.id { g.activeTabID = t.id }
        }
        documentFocused()
        cursorMoved(pane)
    }

    func activate(group: EditorGroup, tab: EditorTab) {
        group.activeTabID = tab.id
        activeGroupID = group.id
        documentFocused()
        let p = group.pane(for: tab.document)
        DispatchQueue.main.async { p.focus() }
        saveSession()
    }

    private func documentFocused() {
        let id = activeDocument?.id
        if activeDocumentID != id { activeDocumentID = id }
        if let p = activePane { cursorMoved(p) }
        services.activeEditorChanged.send(activePane)
        objectWillChange.send()
    }

    func cursorMoved(_ pane: EditorPane) {
        guard pane === activePane else { return }
        let sel = pane.textView.selectedRange()
        cursor = pane.document.lines.position(of: sel.location)
        selectionLength = sel.length
        cursorCount = pane.textView.allRanges.count
    }

    // MARK: close

    @discardableResult
    func close(tab: EditorTab, in group: EditorGroup) -> Bool {
        let doc = tab.document
        let openElsewhere = groups.contains { $0 !== group && $0.contains(doc) }
        if !openElsewhere && !services.documents.confirmClose(doc) { return false }
        guard let i = group.tabs.firstIndex(of: tab) else { return true }
        group.tabs.remove(at: i)
        bag[tab.id] = nil
        if group.activeTabID == tab.id {
            group.activeTabID = group.tabs.indices.contains(i) ? group.tabs[i].id : group.tabs.last?.id
        }
        release(doc, from: group)
        if group.tabs.isEmpty && groups.count > 1 {
            groups.removeAll { $0 === group }
            if activeGroupID == group.id { activeGroupID = groups.last?.id }
        }
        documentFocused()
        if let p = activePane { DispatchQueue.main.async { p.focus() } }
        saveSession()
        return true
    }

    private func release(_ doc: Document, from group: EditorGroup) {
        if !group.contains(doc) { group.discardPane(for: doc) }
        if !groups.contains(where: { $0.contains(doc) }) { services.documents.remove(doc) }
    }

    func closeActiveTab() {
        let g = activeGroup
        if let t = g.activeTab { close(tab: t, in: g) }
    }

    func closeOthers(_ tab: EditorTab, in group: EditorGroup) {
        for t in group.tabs where t != tab { if !close(tab: t, in: group) { return } }
    }

    func closeAll() -> Bool {
        for g in groups { for t in g.tabs { if !close(tab: t, in: g) { return false } } }
        return true
    }

    // MARK: split & reorder

    /// ⌘\ — open the current document in a new group to the right.
    func split() {
        guard let doc = activeDocument else { return }
        if groups.count >= 3 { return }
        let g = EditorGroup()
        let idx = (groups.firstIndex { $0.id == activeGroupID } ?? 0) + 1
        groups.insert(g, at: idx)
        let src = activePane
        let pane = open(document: doc, in: g)
        if let src {
            let sel = src.textView.selectedRange()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                pane.textView.setSelectedRange(sel)
                pane.reveal(sel)
            }
        }
    }

    func focusGroup(_ n: Int) {
        guard groups.indices.contains(n) else { return }
        activeGroupID = groups[n].id
        documentFocused()
        if let p = activePane { p.focus() }
    }

    func moveTab(_ tabID: UUID, before targetID: UUID?, in group: EditorGroup) {
        guard let from = group.tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let tab = group.tabs.remove(at: from)
        if let targetID, let to = group.tabs.firstIndex(where: { $0.id == targetID }) { group.tabs.insert(tab, at: to) }
        else { group.tabs.append(tab) }
        saveSession()
    }

    func cycleTab(_ d: Int) {
        let g = activeGroup
        guard let i = g.tabs.firstIndex(where: { $0.id == g.activeTab?.id }), !g.tabs.isEmpty else { return }
        let n = (i + d + g.tabs.count) % g.tabs.count
        activate(group: g, tab: g.tabs[n])
    }

    var allDocumentsInTabs: [Document] {
        var seen = Set<UUID>(); var out: [Document] = []
        for g in groups { for t in g.tabs where !seen.contains(t.document.id) { seen.insert(t.document.id); out.append(t.document) } }
        return out
    }

    // MARK: session

    func saveSession() {
        guard services.workspace.root != nil else { return }
        let files = allDocumentsInTabs.compactMap { $0.url?.path }
        services.workspace.saveSession(.init(openFiles: files, active: activeDocument?.url?.path))
    }

    func restoreSession() {
        guard let s = services.workspace.loadSession() else { return }
        for p in s.openFiles where FileManager.default.fileExists(atPath: p) { open(URL(fileURLWithPath: p), focus: false) }
        if let a = s.active, FileManager.default.fileExists(atPath: a) { open(URL(fileURLWithPath: a)) }
    }

    /// Close every tab without prompting (used when switching workspaces after confirming).
    func reset() {
        for g in groups { for t in g.tabs { g.discardPane(for: t.document) } }
        for d in services.documents.documents { services.documents.remove(d) }
        groups = [EditorGroup()]
        activeGroupID = groups[0].id
        documentFocused()
    }
}
