import SwiftUI

/// ⇧F12 "Find All References": results grouped by file in a bottom panel.
final class ReferencesModel: ObservableObject {
    static let shared = ReferencesModel()
    static let panelID = "panel.references"

    struct Item: Identifiable {
        let id = UUID()
        let location: Location
        let preview: String          // the line, trimmed
        let match: NSRange           // the name inside `preview`
        let isDeclaration: Bool
    }
    struct Group: Identifiable {
        var id: URL { uri }
        let uri: URL
        var items: [Item]
    }

    @Published private(set) var symbol = ""
    @Published private(set) var groups: [Group] = []
    @Published private(set) var busy = false
    @Published var collapsed: Set<URL> = []
    @Published var selected: UUID?

    var count: Int { groups.reduce(0) { $0 + $1.items.count } }

    func findAtCursor() {
        let s = Services.shared
        guard let ed = s.editor else { return }
        guard ed.document.language == .vanta else { s.flash("References work in Vanta files"); return }
        let caret = ed.selections.first?.location ?? 0
        let ns = ed.text as NSString
        var a = caret, b = caret
        while a > 0 && VantaLexer.isIdent(ns.character(at: a - 1)) { a -= 1 }
        while b < ns.length && VantaLexer.isIdent(ns.character(at: b)) { b += 1 }
        guard b > a else { s.flash("Put the cursor on a name first"); return }
        let word = ns.substring(with: NSRange(location: a, length: b - a))
        let uri = ed.document.uri, text = ed.text, pos = ed.position(of: caret)
        symbol = word
        busy = true
        groups = []
        s.layout.showBottom(Self.panelID)
        Task { [weak self] in
            let locs = await LanguageService.shared.references(uri: uri, text: text, position: pos)
            let decl = await LanguageService.shared.definition(DocumentContext(uri: uri, text: text, languageID: "vanta",
                                                                               offset: caret, position: pos)).first
            await MainActor.run { self?.show(locs, declaration: decl) }
        }
    }

    func show(_ locs: [Location], declaration: Location?) {
        busy = false
        var byFile: [URL: [Item]] = [:]
        var texts: [URL: [String]] = [:]
        func lines(_ uri: URL) -> [String] {
            if let t = texts[uri] { return t }
            let text = Services.shared.documents.documents.first { $0.uri == uri }?.text
                ?? (try? String(contentsOf: uri, encoding: .utf8)) ?? ""
            let l = text.components(separatedBy: "\n")
            texts[uri] = l
            return l
        }
        for loc in locs {
            let ls = lines(loc.uri)
            let raw = loc.range.start.line < ls.count ? ls[loc.range.start.line] : ""
            let lead = raw.prefix { $0 == " " || $0 == "\t" }.utf16.count
            let preview = String(raw.dropFirst(raw.prefix { $0 == " " || $0 == "\t" }.count))
            let match = NSRange(location: max(0, loc.range.start.column - lead),
                                length: max(0, loc.range.end.column - loc.range.start.column))
            let isDecl = declaration.map { $0.uri == loc.uri && $0.range.start == loc.range.start } ?? false
            byFile[loc.uri, default: []].append(Item(location: loc, preview: preview, match: match, isDeclaration: isDecl))
        }
        let current = Services.shared.editor?.document.uri
        groups = byFile.map { Group(uri: $0.key, items: $0.value.sorted { $0.location.range.start < $1.location.range.start }) }
            .sorted { ($0.uri == current ? 0 : 1, $0.uri.path) < ($1.uri == current ? 0 : 1, $1.uri.path) }
        if groups.isEmpty { Services.shared.flash("No references to “\(symbol)”") }
    }

    func open(_ item: Item) {
        selected = item.id
        let loc = item.location
        Services.shared.editors.open(location: loc)
        if let ed = Services.shared.editor, ed.document.uri == loc.uri {
            let a = ed.offset(of: loc.range.start), b = ed.offset(of: loc.range.end)
            ed.selections = [NSRange(location: a, length: max(0, b - a))]
        }
    }

    func step(_ dir: Int) {
        let all = groups.flatMap(\.items)
        guard !all.isEmpty else { return }
        let i = all.firstIndex { $0.id == selected } ?? (dir > 0 ? -1 : 0)
        open(all[(i + dir + all.count) % all.count])
    }

    func clear() { groups = []; symbol = "" }
}

struct ReferencesPanel: View {
    @ObservedObject var model = ReferencesModel.shared
    @ObservedObject var workspace = Services.shared.workspace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("Finding references to “\(model.symbol)”…").foregroundColor(Theme.muted)
                } else if !model.symbol.isEmpty {
                    Text("“\(model.symbol)”").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("\(model.count) reference\(model.count == 1 ? "" : "s") in \(model.groups.count) file\(model.groups.count == 1 ? "" : "s")")
                        .foregroundColor(Theme.muted)
                }
                Spacer()
                IconButton(icon: "chevron.up", help: "Previous Reference") { model.step(-1) }
                IconButton(icon: "chevron.down", help: "Next Reference") { model.step(1) }
                IconButton(icon: "xmark.circle", help: "Clear") { model.clear() }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10).frame(height: 28)
            if model.groups.isEmpty && !model.busy {
                PlaceholderPanel(title: "No references", icon: "arrow.triangle.branch",
                                 message: "Put the cursor on a name and press ⇧F12 to find every place it's used — across files and imports.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.groups) { g in
                            fileRow(g)
                            if !model.collapsed.contains(g.uri) {
                                ForEach(g.items) { item in row(item) }
                            }
                        }
                    }.padding(.bottom, 6)
                }
            }
        }
    }

    func fileRow(_ g: ReferencesModel.Group) -> some View {
        let open = !model.collapsed.contains(g.uri)
        return HStack(spacing: 5) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.muted).frame(width: 10)
            FileIcon(name: g.uri.lastPathComponent, isDirectory: false)
            Text(g.uri.lastPathComponent).font(.system(size: 12.5))
            Text(g.uri.isFileURL ? (workspace.relativePath(g.uri) as NSString).deletingLastPathComponent : "")
                .font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
            Text("\(g.items.count)").font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).background(Capsule().fill(Theme.panel2))
            Spacer()
        }
        .padding(.horizontal, 10).frame(height: 22).contentShape(Rectangle())
        .onTapGesture {
            if open { model.collapsed.insert(g.uri) } else { model.collapsed.remove(g.uri) }
        }
    }

    func row(_ item: ReferencesModel.Item) -> some View {
        HStack(spacing: 8) {
            Text("\(item.location.range.start.line + 1)").font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(Theme.muted).frame(width: 34, alignment: .trailing)
            preview(item).lineLimit(1)
            if item.isDeclaration {
                Text("definition").font(.system(size: 9.5, weight: .semibold)).foregroundColor(Theme.accent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().stroke(Theme.accent.opacity(0.6)))
            }
            Spacer()
        }
        .padding(.leading, 22).padding(.trailing, 10).frame(height: 21)
        .background(RoundedRectangle(cornerRadius: 4).fill(model.selected == item.id ? Theme.panel2 : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
        .onTapGesture { model.open(item) }
    }

    func preview(_ item: ReferencesModel.Item) -> Text {
        let ns = item.preview as NSString
        let m = NSIntersectionRange(item.match, NSRange(location: 0, length: ns.length))
        let font = Font.system(size: 12, design: .monospaced)
        guard m.length > 0 else { return Text(item.preview).font(font).foregroundColor(Theme.ink) }
        let a = ns.substring(to: m.location), b = ns.substring(with: m), c = ns.substring(from: NSMaxRange(m))
        return Text(a).font(font).foregroundColor(Theme.ink)
            + Text(b).font(font.weight(.bold)).foregroundColor(Theme.accent)
            + Text(c).font(font).foregroundColor(Theme.ink)
    }
}
