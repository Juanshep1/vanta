import SwiftUI

/// ⌘⇧F — find/replace across the workspace.
struct SearchView: View {
    @ObservedObject var search: ProjectSearch
    @State private var showFilters = false
    @FocusState private var focus: Bool

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader("Search") {
                IconButton(icon: "arrow.clockwise", help: "Refresh") { search.run() }
                IconButton(icon: "rectangle.compress.vertical", help: "Collapse All") {
                    search.collapsed = Set(search.results.map(\.url))
                }
            }
            VStack(spacing: 5) {
                HStack(alignment: .top, spacing: 3) {
                    Button { search.showReplace.toggle(); search.run() } label: {
                        Image(systemName: search.showReplace ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold)).frame(width: 14, height: 24)
                    }.buttonStyle(.plain).foregroundColor(Theme.muted)
                    VStack(spacing: 5) {
                        HStack(spacing: 2) {
                            TextField("Search", text: $search.options.query)
                                .textFieldStyle(.plain).font(.system(size: 12.5))
                                .focused($focus)
                                .onSubmit { search.run() }
                            toggle("Aa", $search.options.caseSensitive, "Match Case")
                            toggle("ab", $search.options.wholeWord, "Match Whole Word")
                            toggle(".*", $search.options.regex, "Use Regular Expression")
                        }
                        .padding(.leading, 7).padding(.trailing, 2).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBg))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(focus ? Theme.accent : Theme.line))
                        if search.showReplace {
                            HStack(spacing: 4) {
                                TextField("Replace", text: $search.options.replacement)
                                    .textFieldStyle(.plain).font(.system(size: 12.5))
                                    .padding(.horizontal, 7).frame(height: 26)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBg))
                                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
                                    .onChange(of: search.options.replacement) { _, _ in search.run() }
                                IconButton(icon: "text.badge.checkmark", help: "Replace All") { confirmReplaceAll() }
                                    .disabled(search.results.isEmpty)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    IconButton(icon: "ellipsis", help: "Toggle Search Details") { showFilters.toggle() }
                }
                .frame(height: 14)
                if showFilters {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("files to include").font(.system(size: 10.5)).foregroundColor(Theme.muted)
                        filterField("e.g. *.va, lib/**", $search.options.include)
                        Text("files to exclude").font(.system(size: 10.5)).foregroundColor(Theme.muted)
                        filterField("e.g. build, *.md", $search.options.exclude)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)

            HStack {
                if let e = search.error { Text(e).foregroundColor(Theme.red) }
                else if search.searching { ProgressView().controlSize(.mini); Text("Searching…") }
                else if !search.options.query.isEmpty {
                    Text(search.matchCount == 0 ? "No results" :
                         "\(search.matchCount) result\(search.matchCount == 1 ? "" : "s") in \(search.results.count) file\(search.results.count == 1 ? "" : "s")")
                }
                Spacer()
            }
            .font(.system(size: 11)).foregroundColor(Theme.muted)
            .padding(.horizontal, 14).frame(height: 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { file in
                        fileHeader(file)
                        if !search.collapsed.contains(file.url) {
                            ForEach(file.matches) { m in matchRow(file, m) }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear { focus = true }
    }

    func toggle(_ label: String, _ on: Binding<Bool>, _ help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(on.wrappedValue ? Theme.accentDim.opacity(0.45) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on.wrappedValue ? Theme.accent : .clear))
        }.buttonStyle(.plain).foregroundColor(on.wrappedValue ? Theme.ink : Theme.muted).help(help)
    }

    func filterField(_ placeholder: String, _ text: Binding<String>) -> some View {
        TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12))
            .padding(.horizontal, 7).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
    }

    func fileHeader(_ f: ProjectSearch.FileResult) -> some View {
        let collapsed = search.collapsed.contains(f.url)
        return HStack(spacing: 5) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8.5, weight: .bold))
                .foregroundColor(Theme.muted).frame(width: 10)
            FileIcon(name: f.url.lastPathComponent, isDirectory: false)
            Text(f.url.lastPathComponent).font(.system(size: 12.5)).lineLimit(1)
            Text((f.relativePath as NSString).deletingLastPathComponent).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(f.matches.count)").font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.panel2))
        }
        .padding(.horizontal, 10).frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed { search.collapsed.remove(f.url) } else { search.collapsed.insert(f.url) }
        }
        .contextMenu {
            if search.showReplace { Button("Replace All in File") { search.replace(in: f) } }
            Button("Open") { Services.shared.editors.open(f.url) }
        }
    }

    func matchRow(_ f: ProjectSearch.FileResult, _ m: ProjectSearch.Match) -> some View {
        HStack(spacing: 0) {
            preview(m).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, 34).padding(.trailing, 8).frame(height: 21)
        .contentShape(Rectangle())
        .onTapGesture {
            Services.shared.editors.open(location: Location(uri: f.url, range: TextRange(
                start: TextPosition(line: m.line, column: 0), end: TextPosition(line: m.line, column: 0))))
            // select the exact match once the pane exists
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard let p = Services.shared.editors.activePane, p.document.url == f.url else { return }
                let r = m.range.location + m.range.length <= p.document.storage.length ? m.range : NSRange(location: 0, length: 0)
                p.textView.setSelectedRange(r)
                p.reveal(r)
            }
        }
        .help("Line \(m.line + 1)")
    }

    func preview(_ m: ProjectSearch.Match) -> Text {
        let ns = m.lineText as NSString
        let pr = m.previewRange
        guard pr.location >= 0, NSMaxRange(pr) <= ns.length else { return Text(m.lineText).foregroundColor(Theme.ink) }
        let before = Text(ns.substring(to: pr.location)).foregroundColor(Theme.ink.opacity(0.8))
        let hit = ns.substring(with: pr)
        let after = Text(ns.substring(from: NSMaxRange(pr))).foregroundColor(Theme.ink.opacity(0.8))
        if let rep = m.replacement, search.showReplace {
            return before + Text(hit).strikethrough().foregroundColor(Theme.red)
                + Text(rep).foregroundColor(Theme.green).bold() + after
        }
        return before + Text(hit).foregroundColor(Theme.amber).bold() + after
    }

    func confirmReplaceAll() {
        let n = search.matchCount, files = search.results.count
        guard n > 0 else { return }
        if !Services.shared.isSnapshot {
            let a = NSAlert()
            a.messageText = "Replace \(n) occurrence\(n == 1 ? "" : "s") across \(files) file\(files == 1 ? "" : "s") with “\(search.options.replacement)”?"
            a.informativeText = "Open files can be undone with ⌘Z; closed files are rewritten on disk."
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let count = search.replaceAll()
        Services.shared.flash("Replaced \(count) occurrence\(count == 1 ? "" : "s")")
    }
}
