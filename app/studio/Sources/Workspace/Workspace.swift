import AppKit
import Combine

/// A node in the explorer tree. Children load lazily on first expand.
final class FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    weak var parent: FileNode?
    var children: [FileNode]?          // nil = not loaded yet

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url.standardizedFileURL
        self.isDirectory = isDirectory
        self.parent = parent
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

/// The open folder: file tree, file index (for Quick Open / search), FSEvents
/// watching, git branch, recent workspaces and the per-workspace session.
final class Workspace: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var rootNode: FileNode?
    /// Bumped whenever the tree changes (views observe this).
    @Published private(set) var treeVersion = 0
    @Published var expanded: Set<String> = []
    @Published var selection: String?
    @Published private(set) var fileIndex: [URL] = []
    @Published private(set) var gitBranch: String?
    @Published private(set) var recent: [URL] = []

    /// Fires with changed paths after FSEvents (already coalesced).
    let filesChanged = PassthroughSubject<Set<String>, Never>()

    private var watcher: FileWatcher?
    private var indexTask: Task<Void, Never>?
    private var refreshWork: DispatchWorkItem?

    static let ignoredNames: Set<String> = [".git", ".DS_Store", "node_modules", "__pycache__", ".build",
                                            "DerivedData", ".svn", ".hg", ".idea", ".vscode-test", ".venv",
                                            "venv", ".mypy_cache", ".pytest_cache", "xcuserdata"]
    private let recentKey = "vanta-studio-2-recent-workspaces"
    private let lastKey = "vanta-studio-2-last-workspace"

    init() {
        recent = (UserDefaults.standard.stringArray(forKey: recentKey) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var name: String { root?.lastPathComponent ?? "No Folder" }
    var lastWorkspace: URL? {
        UserDefaults.standard.string(forKey: lastKey).map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    // MARK: open / close

    func open(_ url: URL) {
        let url = url.standardizedFileURL
        watcher?.stop()
        root = url
        let node = FileNode(url: url, isDirectory: true, parent: nil)
        rootNode = node
        expanded = loadExpanded(for: url)
        expanded.insert(url.path)
        loadChildren(node)
        for p in expanded { if let n = find(path: p) { loadChildren(n) } }
        treeVersion += 1
        watcher = FileWatcher(path: url.path) { [weak self] paths in self?.handleFSEvents(paths) }
        rebuildIndex()
        readGitBranch()
        if !Services.shared.isSnapshot {
            recent.removeAll { $0 == url }
            recent.insert(url, at: 0)
            if recent.count > 12 { recent.removeLast(recent.count - 12) }
            UserDefaults.standard.set(recent.map(\.path), forKey: recentKey)
            UserDefaults.standard.set(url.path, forKey: lastKey)
        }
    }

    func close() {
        watcher?.stop(); watcher = nil
        root = nil; rootNode = nil; fileIndex = []; gitBranch = nil
        expanded = []
        treeVersion += 1
        if !Services.shared.isSnapshot { UserDefaults.standard.removeObject(forKey: lastKey) }
    }

    func clearRecent() {
        recent = []
        UserDefaults.standard.set([String](), forKey: recentKey)
    }

    // MARK: tree

    func loadChildren(_ node: FileNode) {
        guard node.isDirectory else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: node.url, includingPropertiesForKeys: [.isDirectoryKey],
                                                 options: [])) ?? []
        let old = Dictionary(uniqueKeysWithValues: (node.children ?? []).map { ($0.url, $0) })
        node.children = items
            .filter { !Self.ignoredNames.contains($0.lastPathComponent) }
            .map { u -> FileNode in
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if let existing = old[u.standardizedFileURL], existing.isDirectory == isDir { return existing }
                return FileNode(url: u, isDirectory: isDir, parent: node)
            }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    func find(path: String) -> FileNode? {
        guard let rootNode else { return nil }
        if rootNode.url.path == path { return rootNode }
        guard path.hasPrefix(rootNode.url.path + "/") else { return nil }
        var node = rootNode
        let rel = path.dropFirst(rootNode.url.path.count + 1).split(separator: "/")
        for comp in rel {
            if node.children == nil { loadChildren(node) }
            guard let next = node.children?.first(where: { $0.name == comp }) else { return nil }
            node = next
        }
        return node
    }

    func toggle(_ node: FileNode) {
        if expanded.contains(node.id) { expanded.remove(node.id) } else {
            if node.children == nil { loadChildren(node) }
            expanded.insert(node.id)
        }
        saveExpanded()
        treeVersion += 1
    }

    func collapseAll() {
        if let r = root { expanded = [r.path] }
        saveExpanded()
        treeVersion += 1
    }

    /// Expand parents and select the file (used by "reveal active file").
    func reveal(_ url: URL) {
        guard let root, url.path.hasPrefix(root.path + "/") else { return }
        var dir = url.deletingLastPathComponent().standardizedFileURL
        var toExpand: [String] = []
        while dir.path.count >= root.path.count {
            toExpand.append(dir.path)
            if dir.path == root.path { break }
            dir = dir.deletingLastPathComponent()
        }
        for p in toExpand.reversed() {
            if let n = find(path: p) { if n.children == nil { loadChildren(n) } }
            expanded.insert(p)
        }
        selection = url.standardizedFileURL.path
        treeVersion += 1
    }

    /// Visible rows (depth-first through expanded folders).
    func visibleRows() -> [(node: FileNode, depth: Int)] {
        guard let rootNode else { return [] }
        var out: [(FileNode, Int)] = []
        func walk(_ n: FileNode, _ depth: Int) {
            for c in n.children ?? [] {
                out.append((c, depth))
                if c.isDirectory && expanded.contains(c.id) {
                    if c.children == nil { loadChildren(c) }
                    walk(c, depth + 1)
                }
            }
        }
        walk(rootNode, 0)
        return out
    }

    func relativePath(_ url: URL) -> String {
        guard let root else { return url.lastPathComponent }
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : p
    }

    // MARK: file operations

    @discardableResult
    func createFile(in dir: URL, name: String, contents: String = "") -> URL? {
        let url = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            Services.shared.flash("\(name) already exists"); return nil
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch { Services.shared.flash("Couldn't create \(name): \(error.localizedDescription)"); return nil }
        refresh(dir)
        expanded.insert(dir.standardizedFileURL.path)
        selection = url.standardizedFileURL.path
        return url
    }

    @discardableResult
    func createFolder(in dir: URL, name: String) -> URL? {
        let url = dir.appendingPathComponent(name)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        catch { Services.shared.flash("Couldn't create folder: \(error.localizedDescription)"); return nil }
        refresh(dir)
        expanded.insert(dir.standardizedFileURL.path)
        selection = url.standardizedFileURL.path
        return url
    }

    @discardableResult
    func rename(_ node: FileNode, to newName: String) -> URL? {
        let newURL = node.url.deletingLastPathComponent().appendingPathComponent(newName)
        guard newName != node.name, !newName.isEmpty else { return nil }
        do { try FileManager.default.moveItem(at: node.url, to: newURL) }
        catch { Services.shared.flash("Couldn't rename: \(error.localizedDescription)"); return nil }
        Services.shared.documents.didMove(from: node.url, to: newURL)
        if expanded.remove(node.id) != nil { expanded.insert(newURL.standardizedFileURL.path) }
        refresh(node.url.deletingLastPathComponent())
        selection = newURL.standardizedFileURL.path
        return newURL
    }

    /// Move to the Trash (recoverable) — never a hard delete.
    func trash(_ nodes: [FileNode], completion: (() -> Void)? = nil) {
        let urls = nodes.map(\.url)
        NSWorkspace.shared.recycle(urls) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error { Services.shared.flash("Couldn't move to Trash: \(error.localizedDescription)") }
                for u in urls { self?.refresh(u.deletingLastPathComponent()) }
                completion?()
            }
        }
    }

    func revealInFinder(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// Reload one directory's children (and the index) soon.
    func refresh(_ dir: URL) {
        if let n = find(path: dir.standardizedFileURL.path), n.children != nil { loadChildren(n) }
        treeVersion += 1
        refreshSoon()
    }

    /// Coalesced full refresh of loaded folders + index.
    func refreshSoon() {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshLoaded(); self?.rebuildIndex() }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func refreshLoaded() {
        guard let rootNode else { return }
        func walk(_ n: FileNode) {
            guard n.isDirectory, n.children != nil else { return }
            loadChildren(n)
            for c in n.children ?? [] { walk(c) }
        }
        walk(rootNode)
        treeVersion += 1
    }

    private func handleFSEvents(_ paths: Set<String>) {
        guard let root else { return }
        let interesting = paths.filter { p in
            !p.split(separator: "/").contains { Self.ignoredNames.contains(String($0)) }
        }
        if paths.contains(where: { $0.hasPrefix(root.path + "/.git/HEAD") || $0 == root.path + "/.git" }) { readGitBranch() }
        guard !interesting.isEmpty else { return }
        // Re-list the parent folders of anything that changed.
        var dirs = Set<String>()
        for p in interesting { dirs.insert((p as NSString).deletingLastPathComponent) }
        for d in dirs { if let n = find(path: d), n.children != nil { loadChildren(n) } }
        treeVersion += 1
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.rebuildIndex() }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
        let std = Set(interesting.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        Services.shared.documents.checkExternalChanges(paths: std)
        filesChanged.send(std)
    }

    // MARK: index

    /// Every file in the workspace (ignoring build/VCS folders), for Quick Open and search.
    func rebuildIndex() {
        guard let root else { fileIndex = []; return }
        indexTask?.cancel()
        indexTask = Task.detached(priority: .utility) { [weak self] in
            var out: [URL] = []
            let fm = FileManager.default
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                                        options: [.skipsPackageDescendants]) else { return }
            for case let u as URL in e {
                if Task.isCancelled { return }
                if Self.ignoredNames.contains(u.lastPathComponent) { e.skipDescendants(); continue }
                let v = try? u.resourceValues(forKeys: [.isRegularFileKey])
                if v?.isRegularFile == true { out.append(u.standardizedFileURL) }
                if out.count > 50_000 { break }
            }
            let result = out
            await MainActor.run { self?.fileIndex = result }
        }
    }

    // MARK: git

    func readGitBranch() {
        guard let root else { gitBranch = nil; return }
        var dir = root
        for _ in 0..<6 {
            let head = dir.appendingPathComponent(".git/HEAD")
            if let s = try? String(contentsOf: head, encoding: .utf8) {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                gitBranch = t.hasPrefix("ref: refs/heads/") ? String(t.dropFirst(16)) : String(t.prefix(7))
                return
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        gitBranch = nil
    }

    // MARK: per-workspace state

    private func expandedKey(_ url: URL) -> String { "vanta-studio-2-expanded:" + url.path }

    private func loadExpanded(for url: URL) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: expandedKey(url)) ?? [])
    }

    private func saveExpanded() {
        guard let root, !Services.shared.isSnapshot else { return }
        UserDefaults.standard.set(Array(expanded), forKey: expandedKey(root))
    }

    struct Session: Codable {
        var openFiles: [String]
        var active: String?
    }

    func saveSession(_ s: Session) {
        guard let root, !Services.shared.isSnapshot, let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: "vanta-studio-2-session:" + root.path)
    }

    func loadSession() -> Session? {
        guard let root, let data = UserDefaults.standard.data(forKey: "vanta-studio-2-session:" + root.path) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
}
