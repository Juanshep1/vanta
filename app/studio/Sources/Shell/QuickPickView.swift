import SwiftUI

/// One row in the quick pick.
struct QuickPickItem: Identifiable {
    let id: String
    var title: String
    var subtitle: String = ""
    var icon: String = "doc"
    var trailing: String = ""
    var titleMatches: [Int] = []
    var score: Int = 0
    var fileName: String? = nil
    var action: () -> Void
}

/// ⌘P files · ⌘⇧P ">" commands · ⌃G ":" line · ⌘⇧O "@" symbols.
final class QuickPickModel: ObservableObject {
    static let shared = QuickPickModel()
    @Published var text = "" { didSet { if text != oldValue { refresh() } } }
    @Published private(set) var items: [QuickPickItem] = []
    @Published var selected = 0
    private var symbolCache: [DocumentSymbol] = []
    private var symbolTask: Task<Void, Never>?

    enum Mode { case files, commands, line, symbols }
    var mode: Mode {
        if text.hasPrefix(">") { return .commands }
        if text.hasPrefix(":") { return .line }
        if text.hasPrefix("@") { return .symbols }
        return .files
    }
    var query: String { mode == .files ? text : String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }

    var placeholder: String {
        switch mode {
        case .files: return "Search files by name (> commands, : line, @ symbols)"
        case .commands: return "Type a command"
        case .line: return "Go to line (and :column)"
        case .symbols: return "Go to symbol in file"
        }
    }

    func open(_ initial: String) {
        text = initial
        selected = 0
        if mode == .symbols { loadSymbols() }
        refresh()
    }

    func refresh() {
        selected = 0
        switch mode {
        case .files: items = fileItems()
        case .commands: items = commandItems()
        case .line: items = lineItems()
        case .symbols:
            if symbolCache.isEmpty { loadSymbols() }
            items = symbolItems()
        }
    }

    func accept() {
        guard items.indices.contains(selected) else {
            if mode == .line { close() }
            return
        }
        let a = items[selected].action
        close()
        DispatchQueue.main.async { a() }
    }

    func close() { Services.shared.layout.quickPickVisible = false }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + d + items.count) % items.count
    }

    // MARK: sources

    private func fileItems() -> [QuickPickItem] {
        let s = Services.shared
        let q = query.trimmingCharacters(in: .whitespaces)
        var urls: [URL] = []
        var seen = Set<URL>()
        let openDocs = s.editors.allDocumentsInTabs.compactMap(\.url)
        for u in s.editors.history + openDocs where !seen.contains(u) { seen.insert(u); urls.append(u) }
        let recentCount = urls.count
        for u in s.workspace.fileIndex where !seen.contains(u) { seen.insert(u); urls.append(u) }
        var out: [QuickPickItem] = []
        for (i, u) in urls.enumerated() {
            let rel = s.workspace.relativePath(u)
            let name = u.lastPathComponent
            var score = 0
            var idx: [Int] = []
            if !q.isEmpty {
                guard let m = Fuzzy.match(q, rel) else { continue }
                score = m.score
                // map indices into the file name for highlighting
                let offset = (rel as NSString).length - (name as NSString).length
                idx = m.indices.filter { $0 >= offset }.map { $0 - offset }
                if let nm = Fuzzy.match(q, name) { score += nm.score / 2 + 20 }
            }
            if i < recentCount { score += q.isEmpty ? 1000 - i : 15 }
            out.append(QuickPickItem(id: u.path, title: name, subtitle: (rel as NSString).deletingLastPathComponent,
                                     icon: "doc", trailing: i < recentCount && q.isEmpty ? "recently opened" : "",
                                     titleMatches: idx, score: score, fileName: name,
                                     action: { s.editors.open(u) }))
        }
        if s.workspace.root == nil && urls.isEmpty {
            // single-file mode: open buffers (incl. untitled)
            for d in s.editors.allDocumentsInTabs {
                if !q.isEmpty && Fuzzy.match(q, d.name) == nil { continue }
                out.append(QuickPickItem(id: d.id.uuidString, title: d.name, subtitle: "open editor", fileName: d.name,
                                         action: { s.editors.open(document: d) }))
            }
        }
        out.sort { $0.score > $1.score }
        return Array(out.prefix(80))
    }

    private func commandItems() -> [QuickPickItem] {
        let reg = CommandRegistry.shared
        let q = query
        var out: [QuickPickItem] = []
        for c in reg.all where c.inPalette && c.isEnabled() {
            let label = "\(c.category.rawValue): \(c.title)"
            var score = 0
            var idx: [Int] = []
            if !q.isEmpty {
                guard let m = Fuzzy.match(q, label) else { continue }
                score = m.score; idx = m.indices
            }
            if let r = reg.recent.firstIndex(of: c.id) { score += q.isEmpty ? 1000 - r : 8 }
            out.append(QuickPickItem(id: c.id, title: label, icon: "command", trailing: c.shortcut?.display ?? "",
                                     titleMatches: idx, score: score, action: { reg.run(c.id) }))
        }
        if q.isEmpty { out.sort { ($0.score, $1.title) > ($1.score, $0.title) } } else { out.sort { $0.score > $1.score } }
        return out
    }

    private func lineItems() -> [QuickPickItem] {
        guard let ed = Services.shared.editor else { return [] }
        let parts = query.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        let total = ed.document.lines.count
        guard let first = parts.first, let line = first else {
            return [QuickPickItem(id: "line-hint", title: "Current line \(ed.cursorPosition.line + 1). Type a line number between 1 and \(total).",
                                  icon: "arrow.right.to.line", action: {})]
        }
        let col = parts.count > 1 ? (parts[1] ?? 1) : 1
        let l = max(1, min(line, total))
        return [QuickPickItem(id: "line", title: "Go to line \(l)\(parts.count > 1 ? ", column \(col)" : "")",
                              icon: "arrow.right.to.line", action: {
            ed.scrollToLine(l - 1, select: true)
            if col > 1 { ed.selections = [NSRange(location: ed.offset(of: TextPosition(line: l - 1, column: col - 1)), length: 0)] }
            ed.focus()
        })]
    }

    private func loadSymbols() {
        symbolCache = []
        guard let ed = Services.shared.editor, let p = LanguageRegistry.shared.symbolProvider else { return }
        let t = ed.text, u = ed.document.uri
        symbolTask?.cancel()
        symbolTask = Task { [weak self] in
            let s = await p.symbols(text: t, uri: u)
            await MainActor.run {
                func flat(_ x: [DocumentSymbol]) -> [DocumentSymbol] { x.flatMap { [$0] + flat($0.children) } }
                self?.symbolCache = flat(s)
                if self?.mode == .symbols { self?.items = self?.symbolItems() ?? [] }
            }
        }
    }

    private func symbolItems() -> [QuickPickItem] {
        let q = query
        var out: [QuickPickItem] = []
        for s in symbolCache {
            var score = -s.line
            var idx: [Int] = []
            if !q.isEmpty {
                guard let m = Fuzzy.match(q, s.name) else { continue }
                score = m.score; idx = m.indices
            }
            out.append(QuickPickItem(id: s.id.uuidString, title: s.name, subtitle: s.detail, icon: s.kind.symbol,
                                     trailing: "line \(s.line + 1)", titleMatches: idx, score: score, action: {
                Services.shared.editor?.scrollToLine(s.line, select: true)
                Services.shared.editor?.focus()
            }))
        }
        if !q.isEmpty { out.sort { $0.score > $1.score } }
        return out
    }
}

struct QuickPickView: View {
    @ObservedObject var model = QuickPickModel.shared
    @ObservedObject var layout = Services.shared.layout
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(model.placeholder, text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.editorBg))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent.opacity(0.8)))
                .padding(8)
                .focused($focused)
                .onSubmit { model.accept() }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.escape) { model.close(); return .handled }
                .onExitCommand { model.close() }
            if !model.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == model.selected)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selected = i; model.accept() }
                            }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(model.items.count) * 28, 420))
                    .onChange(of: model.selected) { _, s in proxy.scrollTo(s) }
                }
                .padding(.bottom, 6)
            }
        }
        .frame(width: 620)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel)
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
        .onAppear { model.open(layout.quickPickInitialText); focusAtEnd() }
        .onChange(of: layout.quickPickToken) { _, _ in model.open(layout.quickPickInitialText); focusAtEnd() }
    }

    /// Focus the field with the caret after the prefix (">" / ":" / "@") instead of selecting it.
    func focusAtEnd() {
        focused = true
        DispatchQueue.main.async {
            if let editor = NSApp.keyWindow?.firstResponder as? NSTextView ?? NSApp.windows.compactMap({ $0.firstResponder as? NSTextView }).first(where: { $0.isFieldEditor }) {
                let n = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: n, length: 0))
            }
        }
    }

    func row(_ item: QuickPickItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let f = item.fileName { FileIcon(name: f, isDirectory: false) }
            else { Image(systemName: item.icon).font(.system(size: 11.5)).foregroundColor(Theme.muted).frame(width: 15) }
            highlight(item.title, item.titleMatches).font(.system(size: 13)).lineLimit(1)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.system(size: 11.5)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 6)
            if !item.trailing.isEmpty {
                Text(item.trailing).font(.system(size: 11, design: .rounded)).foregroundColor(Theme.muted)
            }
        }
        .padding(.horizontal, 14).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accentDim.opacity(0.35) : .clear).padding(.horizontal, 6))
    }

    func highlight(_ s: String, _ idx: [Int]) -> Text {
        guard !idx.isEmpty else { return Text(s).foregroundColor(Theme.ink) }
        let set = Set(idx)
        var t = Text("")
        var run = "", runHit = false
        func flush() {
            guard !run.isEmpty else { return }
            let piece = Text(run)
            t = t + (runHit ? piece.foregroundColor(Theme.accent).bold() : piece.foregroundColor(Theme.ink))
            run = ""
        }
        for (i, u) in s.utf16.enumerated() {
            let hit = set.contains(i)
            if hit != runHit { flush(); runHit = hit }
            run += String(utf16CodeUnits: [u], count: 1)
        }
        flush()
        return t
    }
}
