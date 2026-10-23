import SwiftUI

/// F2 "Rename Symbol": a prompt over the editor with a live preview of every change
/// (grouped by file), then one Apply. Works across files and imports; open files are
/// edited in place (one undo step each), closed files are rewritten on disk.
final class RenameModel: ObservableObject {
    static let shared = RenameModel()

    struct Change: Identifiable {
        let id = UUID()
        let line: Int
        let before: String
        let after: String
    }
    struct FileChanges: Identifiable {
        var id: URL { uri }
        let uri: URL
        var changes: [Change]
    }

    @Published var visible = false
    @Published var newName = "" { didSet { if visible && newName != oldValue { schedulePreview() } } }
    @Published private(set) var oldName = ""
    @Published private(set) var preview: [FileChanges] = []
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published var excluded: Set<URL> = []

    private var uri: URL?
    private var text = ""
    private var position = TextPosition(line: 0, column: 0)
    private var edits: [URL: [LSPTextEdit]] = [:]
    private var work: DispatchWorkItem?
    private var generation = 0

    var editCount: Int { preview.filter { !excluded.contains($0.uri) }.reduce(0) { $0 + $1.changes.count } }

    func begin(newName suggested: String? = nil) {
        let s = Services.shared
        guard let ed = s.editor else { return }
        guard ed.document.language == .vanta else { s.flash("Rename works in Vanta files"); return }
        let caret = ed.selections.first?.location ?? 0
        uri = ed.document.uri
        text = ed.text
        position = ed.position(of: caret)
        let u = ed.document.uri, t = ed.text, p = position
        Task { [weak self] in
            let r = await LanguageService.shared.prepareRename(uri: u, text: t, position: p)
            await MainActor.run {
                guard let self else { return }
                switch r {
                case .failure(let e):
                    s.flash(e.message)
                case .success(let (_, placeholder)):
                    self.oldName = placeholder
                    self.preview = []
                    self.edits = [:]
                    self.excluded = []
                    self.error = nil
                    self.visible = true
                    self.newName = suggested ?? placeholder
                    if suggested != nil { self.schedulePreview(delay: 0) }
                }
            }
        }
    }

    func cancel() {
        visible = false
        work?.cancel()
        generation += 1
        Services.shared.editor?.focus()
    }

    func schedulePreview(delay: TimeInterval = 0.25) {
        work?.cancel()
        error = nil
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard name != oldName, !name.isEmpty else { preview = []; edits = [:]; return }
        let w = DispatchWorkItem { [weak self] in self?.computePreview(name) }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func computePreview(_ name: String, then: (() -> Void)? = nil) {
        guard let uri else { return }
        generation += 1
        let gen = generation
        busy = true
        let t = text, p = position
        Task { [weak self] in
            let r = await LanguageService.shared.rename(uri: uri, text: t, position: p, to: name)
            await MainActor.run {
                guard let self, gen == self.generation else { return }
                self.busy = false
                switch r {
                case .failure(let e):
                    self.error = e.message
                    self.preview = []
                    self.edits = [:]
                case .success(let edits):
                    self.edits = edits
                    self.preview = self.describe(edits)
                    then?()
                }
            }
        }
    }

    private func describe(_ edits: [URL: [LSPTextEdit]]) -> [FileChanges] {
        var out: [FileChanges] = []
        for (uri, list) in edits {
            let text = Services.shared.documents.documents.first { $0.uri == uri }?.text
                ?? (try? String(contentsOf: uri, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: "\n")
            var byLine: [Int: [LSPTextEdit]] = [:]
            for e in list { byLine[e.range.start.line, default: []].append(e) }
            var changes: [Change] = []
            for (line, es) in byLine.sorted(by: { $0.key < $1.key }) {
                guard line < lines.count else { continue }
                let ns = NSMutableString(string: lines[line])
                for e in es.sorted(by: { $0.range.start.column > $1.range.start.column }) {
                    let r = NSRange(location: min(e.range.start.column, ns.length),
                                    length: max(0, min(e.range.end.column, ns.length) - min(e.range.start.column, ns.length)))
                    ns.replaceCharacters(in: r, with: e.newText)
                }
                changes.append(Change(line: line, before: lines[line].trimmingCharacters(in: .whitespaces),
                                      after: (ns as String).trimmingCharacters(in: .whitespaces)))
            }
            out.append(FileChanges(uri: uri, changes: changes))
        }
        let current = uri
        return out.sorted { ($0.uri == current ? 0 : 1, $0.uri.path) < ($1.uri == current ? 0 : 1, $1.uri.path) }
    }

    func apply() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if name == oldName { cancel(); return }
        if edits.isEmpty || busy {
            work?.cancel()
            computePreview(name) { [weak self] in self?.apply() }
            return
        }
        guard error == nil else { return }
        let chosen = edits.filter { !excluded.contains($0.key) }
        let n = LanguageService.shared.apply(chosen)
        let files = chosen.count
        visible = false
        Services.shared.flash("Renamed “\(oldName)” to “\(name)”: \(n) change\(n == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")")
        Services.shared.workspace.refreshSoon()
        Services.shared.editor?.focus()
    }
}

struct RenameOverlay: View {
    @ObservedObject var model = RenameModel.shared
    @FocusState private var focused: Bool

    var body: some View {
        if model.visible {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "pencil.line").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.accent)
                    Text("Rename").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.muted)
                    Text(model.oldName).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.ink)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(Theme.muted)
                    TextField("new name", text: $model.newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .focused($focused)
                        .onSubmit { model.apply() }
                        .onExitCommand { model.cancel() }
                    if model.busy { ProgressView().controlSize(.small) }
                    Button { model.apply() } label: {
                        Text(model.editCount > 0 ? "Apply \(model.editCount) ↩" : "Apply ↩")
                            .font(.system(size: 11.5, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(model.error == nil ? Theme.accentDim : Theme.panel2))
                            .foregroundColor(.white)
                    }.buttonStyle(.plain).disabled(model.error != nil)
                    Button { model.cancel() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundColor(Theme.muted)
                }
                .padding(12)
                if let err = model.error {
                    Text(err).font(.system(size: 11.5)).foregroundColor(Theme.red)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                } else if !model.preview.isEmpty {
                    Divider().overlay(Theme.line)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.preview) { f in fileSection(f) }
                        }.padding(.vertical, 6)
                    }
                    .frame(height: min(260, CGFloat(model.preview.count) * 24
                                       + CGFloat(model.preview.reduce(0) { $0 + $1.changes.count }) * 40 + 12))
                    Divider().overlay(Theme.line)
                    Text("↩ apply · ⎋ cancel · untick a file to leave it alone")
                        .font(.system(size: 10.5)).foregroundColor(Theme.muted)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                }
            }
            .frame(width: 560)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel).shadow(color: .black.opacity(0.45), radius: 20, y: 8))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.6)))
            .padding(.top, 64)
            .onAppear { focused = true }
        }
    }

    func fileSection(_ f: RenameModel.FileChanges) -> some View {
        let on = !model.excluded.contains(f.uri)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if on { model.excluded.insert(f.uri) } else { model.excluded.remove(f.uri) }
                } label: {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12)).foregroundColor(on ? Theme.accent : Theme.muted)
                }.buttonStyle(.plain)
                FileIcon(name: f.uri.lastPathComponent, isDirectory: false)
                Text(f.uri.lastPathComponent).font(.system(size: 12, weight: .medium))
                Text("\(f.changes.count)").font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 5).background(Capsule().fill(Theme.panel2))
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 22)
            ForEach(f.changes) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(c.line + 1)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.muted)
                        .frame(width: 30, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.before).strikethrough().foregroundColor(Theme.red.opacity(0.85))
                        Text(c.after).foregroundColor(Theme.green)
                    }
                    .font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                    Spacer()
                }
                .padding(.leading, 18).padding(.trailing, 12).padding(.vertical, 2)
                .opacity(on ? 1 : 0.4)
            }
        }
    }
}
