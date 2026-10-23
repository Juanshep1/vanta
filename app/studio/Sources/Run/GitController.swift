import SwiftUI
import Combine

/// Source control state for the workspace, refreshed from `git status` when
/// files change, documents save, or the window comes back.
final class GitController: ObservableObject {
    static let shared = GitController()

    @Published private(set) var repoRoot: URL?
    @Published private(set) var status = GitStatus()
    @Published private(set) var branches: [String] = []
    @Published private(set) var history: [GitCommit] = []
    @Published private(set) var busy: String?             // "Pushing…" etc.
    @Published private(set) var output: String = ""       // last push/pull/commit output
    @Published private(set) var outputFailed = false
    @Published var commitMessage = ""
    @Published var amend = false
    /// The diff on screen (an overlay over the editor area).
    @Published var openDiff: DiffModel?
    /// Gutter change markers per open file (0-based line → marker).
    @Published private(set) var markers: [URL: [Int: LineDiffer.Marker]] = [:]

    private let queue = DispatchQueue(label: "vanta.git", qos: .userInitiated)
    private var bag = Set<AnyCancellable>()
    private var editCancellable: AnyCancellable?
    private var refreshWork: DispatchWorkItem?
    private var markerWork: [URL: DispatchWorkItem] = [:]
    private var headCache: [String: String?] = [:]       // path → HEAD text (cleared on refresh)
    private var lastFetch = Date.distantPast

    var isRepo: Bool { repoRoot != nil }
    var client: GitClient? { repoRoot.map(GitClient.init(root:)) }

    var staged: [GitChange] { status.changes.filter { $0.area == .staged } }
    var unstaged: [GitChange] { status.changes.filter { $0.area == .unstaged } }
    var untracked: [GitChange] { status.changes.filter { $0.area == .untracked } }
    var conflicted: [GitChange] { status.changes.filter { $0.area == .conflicted } }
    var changeCount: Int { Set(status.changes.map(\.path)).count }

    private init() {}

    /// Wire up refresh triggers (called once from RunModule.register).
    func attach(_ s: Services) {
        s.workspace.$root
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] root in self?.open(root) }
            .store(in: &bag)
        s.workspace.filesChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &bag)
        s.activeEditorChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ed in
                guard let self else { return }
                self.editCancellable = nil
                guard let ed else { return }
                self.updateMarkers(ed.document)
                let doc = ed.document
                self.editCancellable = ed.textChanges
                    .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
                    .sink { [weak self, weak doc] _ in if let doc { self?.updateMarkers(doc) } }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.scheduleRefresh(fetch: true) }
            .store(in: &bag)
    }

    func open(_ workspace: URL?) {
        repoRoot = nil
        status = GitStatus(); branches = []; history = []; markers = [:]
        guard let workspace else { return }
        queue.async {
            let root = GitClient.repoRoot(for: workspace)
            DispatchQueue.main.async {
                self.repoRoot = root
                self.refresh()
            }
        }
    }

    func scheduleRefresh(fetch: Bool = false) {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refresh(fetch: fetch) }
        refreshWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    /// Re-read status, branches and history. `fetch` also updates ahead/behind
    /// from the remote (at most once a minute, never prompts for credentials).
    func refresh(fetch: Bool = false, completion: (() -> Void)? = nil) {
        guard let c = client else { completion?(); return }
        let doFetch = fetch && Date().timeIntervalSince(lastFetch) > 60 && status.upstream != nil
        if doFetch { lastFetch = Date() }
        queue.async {
            if doFetch { _ = c.fetch() }
            let st = c.status()
            let br = c.branches()
            let log = c.log(limit: 80)
            DispatchQueue.main.async {
                if st != self.status { self.status = st }
                self.branches = br
                if log != self.history { self.history = log }
                self.headCache = [:]
                for doc in Services.shared.documents.documents { self.updateMarkers(doc) }
                completion?()
            }
        }
    }

    // MARK: operations

    private func perform(_ title: String, showOutput: Bool = false, _ op: @escaping (GitClient) -> ShellCommand.Output,
                         then: ((ShellCommand.Output) -> Void)? = nil) {
        guard let c = client else { return }
        busy = title
        queue.async {
            let r = op(c)
            DispatchQueue.main.async {
                self.busy = nil
                if showOutput || !r.ok {
                    self.output = r.combined.isEmpty ? (r.ok ? "\(title.replacingOccurrences(of: "…", with: "")) done." : "failed (\(r.code))") : r.combined
                    self.outputFailed = !r.ok
                }
                if !r.ok { Services.shared.flash("git: " + (r.stderr.split(separator: "\n").first.map(String.init) ?? "failed")) }
                then?(r)
                self.refresh()
            }
        }
    }

    func stage(_ changes: [GitChange]) { perform("Staging…") { $0.stage(changes.map(\.path)) } }
    func unstage(_ changes: [GitChange]) {
        let hasHead = status.head != nil
        perform("Unstaging…") { $0.unstage(changes.map(\.path), hasHead: hasHead) }
    }
    func stageAll() { perform("Staging…") { $0.stage(["."]) } }
    func unstageAll() {
        let hasHead = status.head != nil
        perform("Unstaging…") { $0.unstage(["."], hasHead: hasHead) }
    }

    /// Discard working-tree changes (asks first). Untracked files go to the Trash.
    func discard(_ changes: [GitChange], confirm: Bool = true) {
        guard !changes.isEmpty, let root = repoRoot else { return }
        if confirm && !Services.shared.isSnapshot {
            let a = NSAlert()
            a.messageText = changes.count == 1 ? "Discard changes in \(changes[0].fileName)?" : "Discard changes in \(changes.count) files?"
            a.informativeText = changes.contains { $0.area == .untracked }
                ? "Untracked files will be moved to the Trash. Other changes can't be undone."
                : "This can't be undone."
            a.alertStyle = .warning
            a.addButton(withTitle: "Discard")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let untracked = changes.filter { $0.area == .untracked }
        let tracked = changes.filter { $0.area != .untracked }.map(\.path)
        for u in untracked { try? FileManager.default.trashItem(at: root.appendingPathComponent(u.path), resultingItemURL: nil) }
        if tracked.isEmpty { refresh(); reloadOpenDocuments(); return }
        perform("Discarding…", { $0.discard(tracked) }) { _ in self.reloadOpenDocuments() }
    }

    private func reloadOpenDocuments() {
        for d in Services.shared.documents.documents where !d.isDirty && d.url != nil { d.reloadFromDisk() }
    }

    func commit() {
        let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { Services.shared.flash("Write a commit message first"); return }
        let stageEverything = staged.isEmpty && !amend
        if stageEverything && unstaged.isEmpty && untracked.isEmpty { Services.shared.flash("Nothing to commit"); return }
        let amend = self.amend
        perform(amend ? "Amending…" : "Committing…", showOutput: true, { c in
            if stageEverything { _ = c.stage(["."]) }
            return c.commit(message: msg, amend: amend)
        }) { r in
            if r.ok { self.commitMessage = ""; self.amend = false }
        }
    }

    func checkout(_ branch: String) {
        perform("Switching to \(branch)…", { $0.checkout(branch) }) { r in if r.ok { self.reloadOpenDocuments() } }
    }

    func createBranch(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        guard !n.isEmpty else { return }
        perform("Creating \(n)…") { $0.createBranch(n) }
    }

    func push() {
        let setUp = status.upstream == nil ? status.branch : nil
        perform("Pushing…", showOutput: true) { $0.push(setUpstream: setUp) }
    }

    func pull() {
        perform("Pulling…", showOutput: true, { $0.pull() }) { r in if r.ok { self.reloadOpenDocuments() } }
    }

    func sync() {
        perform("Syncing…", showOutput: true) { c in
            let p = c.pull()
            guard p.ok else { return p }
            let u = c.push(setUpstream: nil)
            return ShellCommand.Output(code: u.code, stdout: Data((p.combined + "\n" + u.combined).utf8), stderr: "")
        }
    }

    func clearOutput() { output = ""; outputFailed = false }

    // MARK: diffs

    func relativePath(_ url: URL) -> String? {
        guard let root = repoRoot?.path else { return nil }
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path
        let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
        guard p.hasPrefix(r + "/") else { return nil }
        return String(p.dropFirst(r.count + 1))
    }

    /// Show a change's diff: staged → HEAD vs index, otherwise HEAD vs the working copy.
    func showDiff(_ change: GitChange) {
        guard let c = client, let root = repoRoot else { return }
        let url = root.appendingPathComponent(change.path)
        let live = Services.shared.documents.documents.first { $0.url?.standardizedFileURL == url.standardizedFileURL }?.text
        queue.async {
            let oldPath = change.origPath ?? change.path
            let old = change.area == .untracked ? "" : (c.headContents(oldPath) ?? "")
            let new: String
            if change.area == .staged { new = c.indexContents(change.path) ?? "" }
            else if change.code == "D" { new = "" }
            else { new = live ?? (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
            let title = change.area == .staged ? "\(change.fileName) (staged)" : change.fileName
            let model = DiffModel(title: title, path: change.path, url: url, oldText: old, newText: new,
                                  oldLabel: "HEAD", newLabel: change.area == .staged ? "Index" : "Working tree")
            DispatchQueue.main.async { self.openDiff = model }
        }
    }

    /// Diff the active editor's file against HEAD.
    func showDiffForActiveFile() {
        guard let doc = Services.shared.editors.activeDocument, let url = doc.url, let rel = relativePath(url), let c = client else {
            Services.shared.flash("The current file isn't in a git repository"); return
        }
        let text = doc.text
        queue.async {
            let old = c.headContents(rel) ?? ""
            let model = DiffModel(title: url.lastPathComponent, path: rel, url: url, oldText: old, newText: text,
                                  oldLabel: "HEAD", newLabel: "Working tree")
            DispatchQueue.main.async { self.openDiff = model }
        }
    }

    // MARK: gutter markers

    /// Recompute a document's change markers against HEAD (debounced per file).
    func updateMarkers(_ doc: Document) {
        guard let url = doc.url?.standardizedFileURL, let rel = relativePath(url), let c = client else { return }
        markerWork[url]?.cancel()
        let text = doc.text
        let cached = headCache[rel]
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                let head: String?
                if let cached { head = cached } else { head = c.headContents(rel) }
                let isUntracked = head == nil
                let m: [Int: LineDiffer.Marker]
                if isUntracked {
                    m = [:]       // untracked files: no markers (the whole file would be green)
                } else {
                    m = LineDiffer.markers(old: LineDiffer.lines(head ?? ""), new: LineDiffer.lines(text))
                }
                DispatchQueue.main.async {
                    self.headCache[rel] = .some(head)
                    if self.markers[url] != m { self.markers[url] = m; GitGutter.publish(url, m) }
                }
            }
        }
        markerWork[url] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}

/// What the diff overlay shows.
struct DiffModel: Identifiable {
    let id = UUID()
    let title: String
    let path: String
    let url: URL
    let oldText: String
    let newText: String
    let oldLabel: String
    let newLabel: String
}
