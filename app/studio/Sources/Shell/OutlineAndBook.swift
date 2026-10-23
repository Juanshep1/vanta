import SwiftUI
import Combine

// MARK: - Outline (uses the registered SymbolProvider)

final class OutlineModel: ObservableObject {
    static let shared = OutlineModel()
    @Published private(set) var symbols: [DocumentSymbol] = []
    @Published private(set) var documentName = ""
    private var bag = Set<AnyCancellable>()
    private var docBag: AnyCancellable?

    init() {
        Services.shared.activeEditorChanged
            .sink { [weak self] _ in self?.attach() }
            .store(in: &bag)
    }

    func attach() {
        let doc = Services.shared.editors.activeDocument
        documentName = doc?.name ?? ""
        docBag = doc?.changes
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard let doc = Services.shared.editors.activeDocument, let p = LanguageRegistry.shared.symbolProvider else {
            symbols = []; return
        }
        let text = doc.text, uri = doc.uri
        Task { [weak self] in
            let s = await p.symbols(text: text, uri: uri)
            await MainActor.run { self?.symbols = s }
        }
    }
}

struct OutlineView: View {
    @ObservedObject var model = OutlineModel.shared
    @ObservedObject var editors = Services.shared.editors

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("Outline") {
                IconButton(icon: "arrow.clockwise", help: "Refresh") { model.refresh() }
            }
            if model.symbols.isEmpty {
                PlaceholderPanel(title: model.documentName.isEmpty ? "No file open" : "No symbols",
                                 icon: "list.bullet.indent",
                                 message: "Functions (`to`), types, kinds, tests and top-level `let`s show up here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(flatten(model.symbols), id: \.0.id) { sym, depth in
                            row(sym, depth)
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
        .onAppear { model.attach() }
    }

    func flatten(_ s: [DocumentSymbol], _ d: Int = 0) -> [(DocumentSymbol, Int)] {
        s.flatMap { [($0, d)] + flatten($0.children, d + 1) }
    }

    func row(_ s: DocumentSymbol, _ depth: Int) -> some View {
        let current = editors.cursor.line >= s.line && editors.cursor.line <= (s.endLine ?? s.line)
        return HStack(spacing: 6) {
            Image(systemName: s.kind.symbol).font(.system(size: 11)).foregroundColor(color(s.kind)).frame(width: 14)
            Text(s.name).font(.system(size: 12.5)).lineLimit(1)
            if !s.detail.isEmpty { Text(s.detail).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1) }
            Spacer(minLength: 0)
            Text("\(s.line + 1)").font(.system(size: 10.5)).foregroundColor(Theme.muted.opacity(0.7))
        }
        .padding(.leading, CGFloat(depth) * 14 + 12).padding(.trailing, 10).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 4).fill(current ? Theme.panel2 : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { Services.shared.editor?.scrollToLine(s.line, select: true); Services.shared.editor?.focus() }
    }

    func color(_ k: SymbolKind) -> Color {
        switch k {
        case .function, .method: return Theme.blue
        case .type, .kind: return Theme.amber
        case .test: return Theme.green
        case .constant: return Theme.red
        default: return Theme.muted
        }
    }
}

// MARK: - Book & docs

/// The Vanta Book chapters (~/projects/vanta-book/chapters) and language docs,
/// opened read-only in editor tabs.
struct BookView: View {
    struct Entry: Identifiable, Hashable { var id: URL { url }; let url: URL; let title: String }
    @State private var chapters: [Entry] = []
    @State private var docs: [Entry] = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("The Vanta Book") {
                IconButton(icon: "doc.richtext", help: "Open the PDF") { openPDF() }
            }
            TextField("Filter chapters", text: $filter)
                .textFieldStyle(.plain).font(.system(size: 12.5))
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBg))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                .padding(.horizontal, 10).padding(.bottom, 6)
            if chapters.isEmpty && docs.isEmpty {
                PlaceholderPanel(title: "Book not found", icon: "book.closed",
                                 message: "Expected chapters in ~/projects/vanta-book/chapters and docs in ~/projects/vanta/docs.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("Chapters", chapters)
                        section("Reference", docs)
                    }.padding(.bottom, 16)
                }
            }
        }
        .onAppear(perform: load)
    }

    func section(_ title: String, _ items: [Entry]) -> some View {
        let shown = filter.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(filter) }
        return Group {
            if !shown.isEmpty {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
                    .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)
                ForEach(shown) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "text.book.closed").font(.system(size: 10.5)).foregroundColor(Theme.accent)
                        Text(e.title).font(.system(size: 12.5)).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 14).frame(height: 22).contentShape(Rectangle())
                    .onTapGesture { open(e.url) }
                }
            }
        }
    }

    func load() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        chapters = entries(home.appendingPathComponent("projects/vanta-book/chapters"))
        docs = entries(home.appendingPathComponent("projects/vanta/docs"))
    }

    func entries(_ dir: URL) -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { u in Entry(url: u, title: title(of: u)) }
    }

    func title(of url: URL) -> String {
        if let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 600), let s = String(data: d, encoding: .utf8),
           let line = s.split(separator: "\n").first(where: { $0.hasPrefix("#") }) {
            return line.drop { $0 == "#" || $0 == " " }.trimmingCharacters(in: .whitespaces)
        }
        return url.deletingPathExtension().lastPathComponent
    }

    func open(_ url: URL) {
        if let pane = Services.shared.editors.open(url, preview: true) {
            pane.document.isReadOnly = true
            pane.textView.isEditable = false
        }
    }

    func openPDF() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for p in ["Desktop/The-Vanta-Book.pdf", "Documents/The-Vanta-Book.pdf"] {
            let u = home.appendingPathComponent(p)
            if FileManager.default.fileExists(atPath: u.path) { NSWorkspace.shared.open(u); return }
        }
        Services.shared.flash("The Vanta Book PDF wasn't found on the Desktop or in Documents")
    }
}

// MARK: - Problems

struct ProblemsView: View {
    @ObservedObject var store = DiagnosticsStore.shared
    @ObservedObject var workspace = Services.shared.workspace

    var body: some View {
        let all = store.all.filter { !$0.1.isEmpty }
        if all.isEmpty {
            PlaceholderPanel(title: "No problems", icon: "checkmark.circle",
                             message: "Errors and warnings from Vanta tools appear here.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(all, id: \.0) { uri, diags in
                        HStack(spacing: 5) {
                            FileIcon(name: uri.lastPathComponent, isDirectory: false)
                            Text(uri.lastPathComponent).font(.system(size: 12.5))
                            Text(uri.isFileURL ? (workspace.relativePath(uri) as NSString).deletingLastPathComponent : "")
                                .font(.system(size: 11)).foregroundColor(Theme.muted)
                            Text("\(diags.count)").font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5).background(Capsule().fill(Theme.panel2))
                            Spacer()
                        }.padding(.horizontal, 10).frame(height: 22)
                        ForEach(diags) { d in
                            HStack(spacing: 6) {
                                Image(systemName: DiagnosticIcon.symbol(d.severity)).foregroundColor(DiagnosticIcon.color(d.severity))
                                    .font(.system(size: 11))
                                Text(d.message).font(.system(size: 12)).lineLimit(1)
                                Text("\(d.source)  [\(d.range.start.line + 1), \(d.range.start.column + 1)]")
                                    .font(.system(size: 11)).foregroundColor(Theme.muted)
                                Spacer()
                            }
                            .padding(.leading, 30).frame(height: 21).contentShape(Rectangle())
                            .onTapGesture { Services.shared.editors.open(location: Location(uri: uri, range: d.range)) }
                        }
                    }
                }.padding(.vertical, 4)
            }
        }
    }
}
