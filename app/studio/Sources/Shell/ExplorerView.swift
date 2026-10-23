import SwiftUI

/// File tree (workspace) or open editors + examples (single-file mode).
final class ExplorerState: ObservableObject {
    static let shared = ExplorerState()
    enum Pending: Equatable { case newFile(URL), newFolder(URL), rename(String) }
    @Published var pending: Pending?
    @Published var draftName = ""
}

struct ExplorerView: View {
    @ObservedObject var workspace = Services.shared.workspace
    @ObservedObject var state = ExplorerState.shared
    @ObservedObject var editors = Services.shared.editors

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("Explorer") {
                if workspace.root != nil {
                    IconButton(icon: "doc.badge.plus", help: "New File") { beginNewFile(nil) }
                    IconButton(icon: "folder.badge.plus", help: "New Folder") { beginNewFolder(nil) }
                    IconButton(icon: "arrow.clockwise", help: "Refresh") { workspace.refreshSoon() }
                    IconButton(icon: "rectangle.compress.vertical", help: "Collapse All") { workspace.collapseAll() }
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    OpenEditorsSection()
                    if let root = workspace.root {
                        sectionHeader(root.lastPathComponent)
                        if case .newFile(let d)? = state.pending, d == root { pendingRow(depth: 0, folder: false) }
                        if case .newFolder(let d)? = state.pending, d == root { pendingRow(depth: 0, folder: true) }
                        let _ = workspace.treeVersion
                        ForEach(workspace.visibleRows(), id: \.node.id) { row in
                            FileRow(node: row.node, depth: row.depth)
                            if row.node.isDirectory, workspace.expanded.contains(row.node.id) {
                                if case .newFile(let d)? = state.pending, d == row.node.url { pendingRow(depth: row.depth + 1, folder: false) }
                                if case .newFolder(let d)? = state.pending, d == row.node.url { pendingRow(depth: row.depth + 1, folder: true) }
                            }
                        }
                    } else {
                        NoFolderView()
                        ExamplesSection()
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .contextMenu {
            if workspace.root != nil {
                Button("New File…") { beginNewFile(nil) }
                Button("New Folder…") { beginNewFolder(nil) }
                Divider()
                Button("Reveal in Finder") { if let r = workspace.root { workspace.revealInFinder(r) } }
            }
        }
    }

    func sectionHeader(_ t: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
            Text(t.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.4)
            Spacer()
        }
        .foregroundColor(Theme.ink.opacity(0.85))
        .padding(.horizontal, 8).frame(height: 24)
    }

    func pendingRow(depth: Int, folder: Bool) -> some View {
        HStack(spacing: 5) {
            FileIcon(name: folder ? "" : (state.draftName.isEmpty ? "x.va" : state.draftName), isDirectory: folder)
            InlineNameField()
        }
        .padding(.leading, CGFloat(depth) * 12 + 22).padding(.trailing, 8).frame(height: 24)
    }

    func beginNewFile(_ dir: URL?) {
        guard let d = dir ?? targetFolder() else { return }
        workspace.expanded.insert(d.standardizedFileURL.path)
        state.draftName = ""
        state.pending = .newFile(d.standardizedFileURL)
    }

    func beginNewFolder(_ dir: URL?) {
        guard let d = dir ?? targetFolder() else { return }
        workspace.expanded.insert(d.standardizedFileURL.path)
        state.draftName = ""
        state.pending = .newFolder(d.standardizedFileURL)
    }

    /// Selected folder, the selected file's folder, or the root.
    func targetFolder() -> URL? {
        if let sel = workspace.selection, let n = workspace.find(path: sel) {
            return n.isDirectory ? n.url : n.url.deletingLastPathComponent()
        }
        return workspace.root
    }
}

/// The text field used for new-file / new-folder / rename.
struct InlineNameField: View {
    @ObservedObject var state = ExplorerState.shared
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $state.draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 4).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.editorBg))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.accent))
            .focused($focused)
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onSubmit(commit)
            .onExitCommand { state.pending = nil }
            .onChange(of: focused) { _, f in if !f && state.pending != nil { commit() } }
    }

    func commit() {
        let ws = Services.shared.workspace
        let name = state.draftName.trimmingCharacters(in: .whitespaces)
        let pending = state.pending
        state.pending = nil
        guard !name.isEmpty, let pending else { return }
        switch pending {
        case .newFile(let dir):
            if let u = ws.createFile(in: dir, name: name) { Services.shared.editors.open(u) }
        case .newFolder(let dir):
            ws.createFolder(in: dir, name: name)
        case .rename(let path):
            if let n = ws.find(path: path) { ws.rename(n, to: name) }
        }
    }
}

struct FileRow: View {
    let node: FileNode
    let depth: Int
    @ObservedObject var workspace = Services.shared.workspace
    @ObservedObject var state = ExplorerState.shared
    @ObservedObject var editors = Services.shared.editors
    @State private var hover = false

    var body: some View {
        let selected = workspace.selection == node.id
        let isActiveDoc = editors.activeDocument?.url?.standardizedFileURL == node.url
        let dirty = Services.shared.documents.document(for: node.url)?.isDirty ?? false
        HStack(spacing: 4) {
            if node.isDirectory {
                Image(systemName: workspace.expanded.contains(node.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8.5, weight: .bold)).foregroundColor(Theme.muted).frame(width: 12)
            } else {
                Color.clear.frame(width: 12)
            }
            FileIcon(name: node.name, isDirectory: node.isDirectory, expanded: workspace.expanded.contains(node.id))
            if state.pending == .rename(node.id) {
                InlineNameField()
            } else {
                Text(node.name).font(.system(size: 12.5)).lineLimit(1)
                    .foregroundColor(isActiveDoc ? Theme.ink : Theme.ink.opacity(0.82))
                Spacer(minLength: 0)
                if dirty { Circle().fill(Theme.ink.opacity(0.7)).frame(width: 6, height: 6) }
            }
        }
        .padding(.leading, CGFloat(depth) * 12 + 8).padding(.trailing, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Theme.accentDim.opacity(0.32) : (hover ? Theme.panel2.opacity(0.7) : .clear))
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) {
            if !node.isDirectory { editors.open(node.url, preview: false) }
        }
        .simultaneousGesture(TapGesture().onEnded {
            workspace.selection = node.id
            if node.isDirectory { workspace.toggle(node) } else { editors.open(node.url, preview: true) }
        })
        .contextMenu {
            if node.isDirectory {
                Button("New File…") { begin(.newFile(node.url)) }
                Button("New Folder…") { begin(.newFolder(node.url)) }
                Divider()
            } else {
                Button("Open") { editors.open(node.url) }
                Button("Open to the Side") { editors.open(node.url); editors.split() }
                Divider()
            }
            Button("Rename…") {
                state.draftName = node.name
                state.pending = .rename(node.id)
            }
            Button("Move to Trash") { workspace.trash([node]) }
            Divider()
            Button("Reveal in Finder") { workspace.revealInFinder(node.url) }
            Button("Copy Path") { copy(node.url.path) }
            Button("Copy Relative Path") { copy(workspace.relativePath(node.url)) }
        }
        .help(node.url.path)
    }

    func begin(_ p: ExplorerState.Pending) {
        workspace.expanded.insert(node.id)
        state.draftName = ""
        state.pending = p
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct OpenEditorsSection: View {
    @ObservedObject var editors = Services.shared.editors
    @ObservedObject var documents = Services.shared.documents
    @State private var expanded = true

    var body: some View {
        let docs = editors.allDocumentsInTabs
        if !docs.isEmpty {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                    Text("OPEN EDITORS").font(.system(size: 11, weight: .bold)).tracking(0.4)
                    Spacer()
                }
                .foregroundColor(Theme.ink.opacity(0.85))
                .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                ForEach(docs) { d in OpenEditorRow(document: d) }
            }
        }
    }
}

struct OpenEditorRow: View {
    @ObservedObject var document: Document
    @ObservedObject var editors = Services.shared.editors
    var body: some View {
        let active = editors.activeDocument?.id == document.id
        HStack(spacing: 5) {
            FileIcon(name: document.name, isDirectory: false)
            Text(document.name).font(.system(size: 12.5)).lineLimit(1)
            if document.isDirty { Circle().fill(Theme.ink.opacity(0.7)).frame(width: 6, height: 6) }
            Spacer()
        }
        .padding(.leading, 22).padding(.trailing, 10).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(active ? Theme.panel2 : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { editors.open(document: document) }
    }
}

struct NoFolderView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You have not opened a folder yet. Open one to browse its files, search across them and keep a session.")
                .font(.system(size: 12)).foregroundColor(Theme.muted)
            Button { CommandRegistry.shared.run("file.open") } label: {
                Text("Open Folder…").font(.system(size: 12.5, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentDim))
                    .foregroundColor(.white)
            }.buttonStyle(.plain)
            RecentList()
        }
        .padding(14)
    }
}

struct RecentList: View {
    @ObservedObject var workspace = Services.shared.workspace
    var body: some View {
        if !workspace.recent.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("RECENT").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
                    .padding(.top, 6)
                ForEach(workspace.recent.prefix(6), id: \.self) { u in
                    Button { AppActions.openWorkspace(u) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").font(.system(size: 10.5))
                            Text(u.lastPathComponent).lineLimit(1)
                        }.font(.system(size: 12.5)).foregroundColor(Theme.accent)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// Bundled example programs (kept from Vanta Studio 1).
struct ExamplesSection: View {
    @State private var expanded = true
    var examples: [URL] {
        (Bundle.main.urls(forResourcesWithExtension: "va", subdirectory: "examples") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    var body: some View {
        if !examples.isEmpty {
            Button { expanded.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                    Text("EXAMPLES").font(.system(size: 11, weight: .bold)).tracking(0.4)
                    Spacer()
                }
                .foregroundColor(Theme.ink.opacity(0.85))
                .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                ForEach(examples, id: \.self) { u in
                    HStack(spacing: 5) {
                        FileIcon(name: u.lastPathComponent, isDirectory: false)
                        Text(u.lastPathComponent).font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.leading, 22).frame(height: 22)
                    .contentShape(Rectangle())
                    .onTapGesture { AppActions.openExample(u) }
                }
            }
        }
    }
}
