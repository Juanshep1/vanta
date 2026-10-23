import AppKit
import Combine

/// All open documents, plus save / autosave / external-change handling.
final class DocumentStore: ObservableObject {
    @Published private(set) var documents: [Document] = []
    private var autosaveWork: DispatchWorkItem?
    private var bag: [UUID: AnyCancellable] = [:]
    private var untitledCounter = 0

    var settings: StudioSettings { .shared }

    func document(for url: URL) -> Document? {
        let std = url.standardizedFileURL
        return documents.first { $0.url?.standardizedFileURL == std }
    }

    func document(id: UUID) -> Document? { documents.first { $0.id == id } }

    /// Open (or return the already-open) document for a file.
    func open(_ url: URL) -> Document? {
        if let d = document(for: url) { return d }
        guard let d = Document.load(url) else {
            Services.shared.flash("Couldn't open \(url.lastPathComponent)")
            return nil
        }
        add(d)
        return d
    }

    @discardableResult
    func newUntitled(text: String = "", name: String? = nil) -> Document {
        untitledCounter += 1
        let n = name ?? (untitledCounter == 1 ? "untitled.va" : "untitled-\(untitledCounter).va")
        let d = Document(url: nil, name: n, text: text)
        add(d)
        return d
    }

    private func add(_ d: Document) {
        documents.append(d)
        bag[d.id] = d.changes.sink { [weak self] _ in self?.scheduleAutosave() }
    }

    /// Forget a document (the caller has already dealt with unsaved changes).
    func remove(_ d: Document) {
        documents.removeAll { $0.id == d.id }
        bag[d.id] = nil
    }

    var dirtyDocuments: [Document] { documents.filter { $0.isDirty } }

    // MARK: save

    /// Save; shows a Save panel for untitled buffers. Returns false if cancelled.
    @discardableResult
    func save(_ d: Document) -> Bool {
        if d.url != nil { return d.save() }
        return saveAs(d)
    }

    @discardableResult
    func saveAs(_ d: Document) -> Bool {
        guard !Services.shared.isSnapshot else { return false }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = d.name
        if let root = Services.shared.workspace.root { panel.directoryURL = root }
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        let ok = d.saveAs(url)
        if ok { Services.shared.workspace.refreshSoon() }
        return ok
    }

    func saveAll() {
        for d in documents where d.isDirty && d.url != nil { d.save() }
    }

    /// Ask what to do with unsaved changes. Returns false if the user cancelled.
    func confirmClose(_ d: Document) -> Bool {
        guard d.isDirty, !Services.shared.isSnapshot else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(d.name)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(d)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: autosave

    private func scheduleAutosave() {
        guard settings.prefs.autosave == .afterDelay, !Services.shared.isSnapshot else { return }
        autosaveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveAll() }
        autosaveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.2, settings.prefs.autosaveDelay), execute: w)
    }

    /// Window lost focus / app deactivated.
    func focusChanged() {
        if settings.prefs.autosave == .onFocusChange && !Services.shared.isSnapshot { saveAll() }
    }

    // MARK: external changes

    /// Check open documents against disk (after FS events or app activation).
    func checkExternalChanges(paths: Set<String>? = nil) {
        for d in documents {
            guard let url = d.url else { continue }
            if let paths, !paths.contains(url.standardizedFileURL.path) { continue }
            guard d.existsOnDisk, d.changedOnDisk else { continue }
            if d.isDirty {
                d.hasExternalChange = true
            } else {
                d.reloadFromDisk()
            }
        }
    }

    /// A file/folder was renamed in the explorer: retarget open documents.
    func didMove(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        for d in documents {
            guard let u = d.url?.standardizedFileURL else { continue }
            if u.path == oldPath { d.didMove(to: new) }
            else if u.path.hasPrefix(oldPath + "/") {
                let rest = String(u.path.dropFirst(oldPath.count + 1))
                d.didMove(to: new.appendingPathComponent(rest))
            }
        }
    }
}
