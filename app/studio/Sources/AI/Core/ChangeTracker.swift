import Foundation

/// File access for the agent and Apply buttons. Reads see unsaved editor
/// buffers; writes go through an open Document (undoable, then saved) or
/// straight to disk. Paths are workspace-relative and may not escape the root.
enum WorkspaceFS {
    static var root: URL? {
        Services.shared.workspace.root ?? VeeAssistant.shared.scratchRoot
    }

    static func resolve(_ path: String) throws -> URL {
        guard let root = root?.standardizedFileURL else { throw AIError.message("No folder is open.") }
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("@") { p.removeFirst() }
        if p.isEmpty || p == "." || p == "./" { return root }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p).standardizedFileURL
                                   : root.appendingPathComponent(p).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else {
            throw AIError.message("'\(path)' is outside the workspace folder.")
        }
        return url
    }

    static func relative(_ url: URL) -> String {
        guard let root = root?.standardizedFileURL else { return url.lastPathComponent }
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    static func exists(_ url: URL) -> Bool {
        Services.shared.documents.document(for: url) != nil || FileManager.default.fileExists(atPath: url.path)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func read(_ url: URL) -> String? {
        if let d = Services.shared.documents.document(for: url) { return d.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ url: URL, _ text: String) throws {
        if let d = Services.shared.documents.document(for: url) {
            d.applyMinimalEdit(to: text, undoable: true)
            if d.url != nil && !d.save() { throw AIError.message("Couldn't save \(url.lastPathComponent)") }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    static func rename(_ from: URL, _ to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
        Services.shared.documents.didMove(from: from, to: to)
    }
}

/// The agent's file changes: pending review (Accept/Reject per hunk, per file
/// or all) and checkpoints (a snapshot of every file before each agent turn).
/// Changes are written to disk immediately so the agent can run them; Reject
/// restores the baseline.
final class ChangeTracker: ObservableObject {
    static let shared = ChangeTracker()

    struct PendingFile: Identifiable, Hashable {
        var id: URL { url }
        let url: URL
        /// Content before the agent touched it (nil = the agent created the file).
        var baseline: String?
    }

    struct Checkpoint: Identifiable {
        let id = UUID()
        let date = Date()
        let label: String
        var files: [URL: String?] = [:]
        var order: [URL] = []
    }

    @Published private(set) var pending: [PendingFile] = []
    @Published private(set) var checkpoints: [Checkpoint] = []
    private var activeCheckpoint: UUID?
    /// Bumped on every change so views re-diff.
    @Published private(set) var revision = 0
    /// Review Changes list expanded in the panel.
    @Published var reviewExpanded = false

    // MARK: recording

    func beginTurn(_ label: String) -> UUID {
        let c = Checkpoint(label: label)
        checkpoints.append(c)
        if checkpoints.count > 40 { checkpoints.removeFirst() }
        activeCheckpoint = c.id
        return c.id
    }

    func endTurn() { activeCheckpoint = nil }

    /// Call before writing/deleting/renaming `url` (records originals once).
    func willModify(_ url: URL) {
        let u = url.standardizedFileURL
        let original = WorkspaceFS.exists(u) ? WorkspaceFS.read(u) : nil
        if let id = activeCheckpoint, let i = checkpoints.firstIndex(where: { $0.id == id }), checkpoints[i].files[u] == nil {
            checkpoints[i].files[u] = .some(original)
            checkpoints[i].order.append(u)
        }
        if !pending.contains(where: { $0.url == u }) { pending.append(PendingFile(url: u, baseline: original)) }
    }

    func didModify(_ url: URL) {
        prune()
        revision += 1
    }

    // MARK: querying

    func current(_ f: PendingFile) -> String? { WorkspaceFS.exists(f.url) ? WorkspaceFS.read(f.url) : nil }

    func hunks(_ f: PendingFile) -> [DiffHunk] { LineDiff.hunks(f.baseline ?? "", current(f) ?? "") }

    func stats(_ f: PendingFile) -> (added: Int, removed: Int) { LineDiff.stats(f.baseline ?? "", current(f) ?? "") }

    var totalStats: (files: Int, added: Int, removed: Int) {
        pending.reduce((0, 0, 0)) { acc, f in let s = stats(f); return (acc.0 + 1, acc.1 + s.added, acc.2 + s.removed) }
    }

    // MARK: accept / reject

    func acceptAll() { pending = []; revision += 1 }

    func accept(_ f: PendingFile) { pending.removeAll { $0.url == f.url }; revision += 1 }

    func reject(_ f: PendingFile) {
        restore(f.url, to: f.baseline)
        pending.removeAll { $0.url == f.url }
        revision += 1
    }

    func rejectAll() { for f in pending { restore(f.url, to: f.baseline) }; pending = []; revision += 1 }

    func accept(_ h: DiffHunk, in f: PendingFile) {
        guard let i = pending.firstIndex(where: { $0.url == f.url }) else { return }
        pending[i].baseline = LineDiff.apply(h, to: f.baseline ?? "")
        prune(); revision += 1
    }

    func reject(_ h: DiffHunk, in f: PendingFile) {
        guard let cur = current(f) else { reject(f); return }
        let reverted = LineDiff.revert(h, in: cur)
        try? WorkspaceFS.write(f.url, reverted)
        prune(); revision += 1
    }

    /// Drop pending entries whose file is back to its baseline.
    private func prune() {
        pending.removeAll { f in
            let cur = current(f)
            return cur == f.baseline || (f.baseline == nil && cur == nil)
        }
    }

    // MARK: checkpoints

    func checkpoint(_ id: UUID) -> Checkpoint? { checkpoints.first { $0.id == id } }

    /// Put every file back the way it was before checkpoint `id` (undoing that
    /// turn and every later one).
    func restore(checkpoint id: UUID) {
        guard let idx = checkpoints.firstIndex(where: { $0.id == id }) else { return }
        // later checkpoints first so the earliest original wins
        for c in checkpoints[idx...].reversed() {
            for u in c.order.reversed() { if let orig = c.files[u] { restore(u, to: orig) } }
        }
        checkpoints.removeSubrange(idx...)
        prune(); revision += 1
    }

    private func restore(_ url: URL, to content: String?) {
        if let content {
            try? WorkspaceFS.write(url, content)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
