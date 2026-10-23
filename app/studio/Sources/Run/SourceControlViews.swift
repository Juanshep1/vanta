import SwiftUI

// MARK: - Source Control sidebar

struct SourceControlView: View {
    @ObservedObject var git = GitController.shared
    @ObservedObject var workspace = Services.shared.workspace
    @State private var newBranch = ""
    @State private var showNewBranch = false
    @State private var showHistory = true
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader("Source Control") {
                if git.isRepo {
                    IconButton(icon: "checkmark", help: "Commit (⌘↩)") { git.commit() }
                    IconButton(icon: "arrow.clockwise", help: "Refresh") { git.refresh(fetch: true) }
                    Menu {
                        Button("Pull") { git.pull() }
                        Button("Push") { git.push() }
                        Button("Sync (pull, then push)") { git.sync() }
                        Divider()
                        Button("Stage All Changes") { git.stageAll() }
                        Button("Unstage All Changes") { git.unstageAll() }
                        Button("Discard All Changes…") { git.discard(git.unstaged + git.untracked) }
                        Divider()
                        Button("Open Terminal Here") { TerminalManager.shared.run("git status", cwd: git.repoRoot) }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 12)) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22).foregroundColor(Theme.muted)
                }
            }
            if workspace.root == nil {
                PlaceholderPanel(title: "No folder open", icon: "folder", message: "Open a folder that's a git repository to see its changes.")
            } else if !git.isRepo {
                VStack(spacing: 12) {
                    PlaceholderPanel(title: "Not a git repository", icon: "arrow.triangle.branch",
                                     message: "This folder isn't tracked by git yet.")
                        .frame(height: 160)
                    Button("Initialize Repository") {
                        TerminalManager.shared.run("git init", cwd: workspace.root)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { git.open(workspace.root) }
                    }
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                branchBar.padding(.horizontal, 12).padding(.bottom, 8)
                commitBox.padding(.horizontal, 12).padding(.bottom, 8)
                if let busy = git.busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy).font(.system(size: 11)).foregroundColor(Theme.muted) }
                        .padding(.horizontal, 14).padding(.bottom, 6)
                }
                if !git.output.isEmpty { outputBox.padding(.horizontal, 12).padding(.bottom, 8) }
                Hairline()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if git.status.changes.isEmpty {
                            Text("No changes — the working tree is clean.").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        group("Merge Conflicts", git.conflicted)
                        group("Staged Changes", git.staged)
                        group("Changes", git.unstaged)
                        group("Untracked", git.untracked)
                        historySection
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    // MARK: branch + remote

    private var branchBar: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(git.branches, id: \.self) { b in
                    Button { git.checkout(b) } label: {
                        if b == git.status.branch { Label(b, systemImage: "checkmark") } else { Text(b) }
                    }
                }
                Divider()
                Button("New Branch…") { showNewBranch = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 10.5))
                    Text(git.status.branch ?? (git.status.head.map { String($0.prefix(7)) } ?? "no commits")).font(.system(size: 12, weight: .medium)).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if git.status.upstream != nil {
                Button { git.pull() } label: {
                    HStack(spacing: 2) { Image(systemName: "arrow.down"); Text("\(git.status.behind)") }
                }.buttonStyle(.plain).help("Pull from \(git.status.upstream ?? "")")
                    .foregroundColor(git.status.behind > 0 ? Theme.blue : Theme.muted)
                Button { git.push() } label: {
                    HStack(spacing: 2) { Image(systemName: "arrow.up"); Text("\(git.status.ahead)") }
                }.buttonStyle(.plain).help("Push to \(git.status.upstream ?? "")")
                    .foregroundColor(git.status.ahead > 0 ? Theme.accent : Theme.muted)
            } else if git.status.branch != nil {
                Button { git.push() } label: { Label("Publish", systemImage: "icloud.and.arrow.up").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted).help("Push this branch to origin")
            }
        }
        .font(.system(size: 11).monospacedDigit())
        .popover(isPresented: $showNewBranch) {
            VStack(alignment: .leading, spacing: 8) {
                Text("New branch from \(git.status.branch ?? "HEAD")").font(.system(size: 12, weight: .semibold))
                TextField("branch-name", text: $newBranch).textFieldStyle(.roundedBorder).frame(width: 220)
                    .onSubmit { createBranch() }
                HStack { Spacer(); Button("Cancel") { showNewBranch = false }; Button("Create") { createBranch() }.keyboardShortcut(.defaultAction) }
            }.padding(14)
        }
    }

    private func createBranch() {
        git.createBranch(newBranch)
        newBranch = ""
        showNewBranch = false
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $git.commitMessage)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(minHeight: 44, maxHeight: 110)
                    .focused($messageFocused)
                    .fixedSize(horizontal: false, vertical: true)
                if git.commitMessage.isEmpty {
                    Text("Message (⌘↩ to commit on \(git.status.branch ?? "HEAD"))")
                        .font(.system(size: 12)).foregroundColor(Theme.muted).padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(messageFocused ? Theme.accent.opacity(0.7) : Theme.line))
            HStack(spacing: 6) {
                Button { git.commit() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                        Text(git.amend ? "Amend" : (git.staged.isEmpty ? "Commit All" : "Commit"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentDim.opacity(canCommit ? 1 : 0.4)))
                    .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
                Toggle("Amend", isOn: $git.amend).toggleStyle(.checkbox).font(.system(size: 11)).foregroundColor(Theme.muted)
            }
        }
    }

    private var canCommit: Bool {
        !git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && git.busy == nil
            && (git.amend || !git.status.changes.isEmpty)
    }

    private var outputBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(git.outputFailed ? "git reported an error" : "git output").font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(git.outputFailed ? Theme.red : Theme.muted)
                Spacer()
                Button { git.clearOutput() } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain).foregroundColor(Theme.muted)
            }
            ScrollView {
                Text(git.output).font(.system(size: 10.5, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }.frame(maxHeight: 90)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill((git.outputFailed ? Theme.red : Theme.panel2).opacity(0.18)))
    }

    // MARK: file groups

    @ViewBuilder private func group(_ title: String, _ changes: [GitChange]) -> some View {
        if !changes.isEmpty {
            HStack(spacing: 4) {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundColor(Theme.muted)
                Text("\(changes.count)").font(.system(size: 10)).foregroundColor(Theme.muted)
                    .padding(.horizontal, 5).background(Capsule().fill(Theme.panel2))
                Spacer()
                if title == "Staged Changes" {
                    IconButton(icon: "minus", help: "Unstage All", size: 11) { git.unstage(changes) }
                } else {
                    if title != "Untracked" || true {
                        IconButton(icon: "arrow.uturn.backward", help: "Discard All…", size: 10.5) { git.discard(changes) }
                    }
                    IconButton(icon: "plus", help: "Stage All", size: 11) { git.stage(changes) }
                }
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.top, 10).padding(.bottom, 2)
            ForEach(changes) { c in ChangeRow(change: c) }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showHistory.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: showHistory ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .semibold))
                    Text("HISTORY").font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                    Spacer()
                }
                .foregroundColor(Theme.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
            if showHistory {
                if git.history.isEmpty {
                    Text("No commits yet").font(.system(size: 11.5)).foregroundColor(Theme.muted).padding(.horizontal, 14)
                }
                ForEach(git.history.prefix(60)) { c in CommitRow(commit: c) }
            }
        }
    }
}

struct ChangeRow: View {
    @ObservedObject var git = GitController.shared
    let change: GitChange
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(colour).frame(width: 14)
            Text(change.fileName).font(.system(size: 12.5)).lineLimit(1)
                .strikethrough(change.code == "D", color: Theme.muted)
            Text(change.folder).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if hover {
                if change.area != .untracked && change.code != "D" {
                    IconButton(icon: "doc.text", help: "Open File", size: 10.5) { openFile() }
                }
                if change.area == .staged {
                    IconButton(icon: "minus", help: "Unstage", size: 11) { git.unstage([change]) }
                } else {
                    IconButton(icon: "arrow.uturn.backward", help: "Discard Changes…", size: 10.5) { git.discard([change]) }
                    IconButton(icon: "plus", help: "Stage", size: 11) { git.stage([change]) }
                }
            }
            Text(String(change.code == "?" ? "U" : change.code)).font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(colour).frame(width: 12)
        }
        .padding(.leading, 14).padding(.trailing, 8).frame(height: 23)
        .background(hover ? Theme.panel2.opacity(0.7) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { git.showDiff(change) }
        .help("\(change.path) — \(change.label)\(change.origPath.map { " from \($0)" } ?? "")")
        .contextMenu {
            Button("Open Changes") { git.showDiff(change) }
            Button("Open File") { openFile() }.disabled(change.code == "D")
            Divider()
            if change.area == .staged { Button("Unstage") { git.unstage([change]) } } else { Button("Stage") { git.stage([change]) } }
            if change.area != .staged { Button("Discard Changes…") { git.discard([change]) } }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            Button("Reveal in Finder") { if let r = git.repoRoot { NSWorkspace.shared.activateFileViewerSelecting([r.appendingPathComponent(change.path)]) } }
        }
    }

    private func openFile() {
        guard let r = git.repoRoot else { return }
        _ = Services.shared.editors.open(r.appendingPathComponent(change.path))
    }

    private var icon: String {
        switch change.code {
        case "A", "?": return "plus.square"
        case "D": return "minus.square"
        case "R", "C": return "arrow.right.square"
        case "U": return "exclamationmark.triangle"
        default: return "pencil"
        }
    }

    private var colour: Color {
        switch change.code {
        case "A", "?": return Theme.green
        case "D": return Theme.red
        case "U": return Theme.amber
        case "R", "C": return Theme.blue
        default: return Theme.amber
        }
    }
}

struct CommitRow: View {
    let commit: GitCommit
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                    if !commit.refs.isEmpty {
                        Text(commit.refs.replacingOccurrences(of: "HEAD -> ", with: "")).font(.system(size: 9.5, weight: .semibold))
                            .foregroundColor(Theme.accent).lineLimit(1)
                            .padding(.horizontal, 4).background(Capsule().fill(Theme.accent.opacity(0.14)))
                    }
                }
                Text("\(String(commit.hash.prefix(7))) · \(commit.author) · \(Self.relative(commit.date))")
                    .font(.system(size: 10.5)).foregroundColor(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 3)
        .help("\(commit.hash)\n\(commit.subject)")
        .contextMenu {
            Button("Copy Commit Hash") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(commit.hash, forType: .string) }
        }
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Status bar: branch + ahead/behind

struct GitBranchStatusItem: View {
    @ObservedObject var git = GitController.shared
    @ObservedObject var workspace = Services.shared.workspace
    var body: some View {
        if git.isRepo {
            HStack(spacing: 8) {
                StatusLabel(icon: "arrow.triangle.branch",
                            text: (git.status.branch ?? git.status.head.map { String($0.prefix(7)) } ?? "HEAD") + (git.changeCount > 0 ? "*" : ""),
                            help: "Source Control — \(git.changeCount) changed file\(git.changeCount == 1 ? "" : "s")") {
                    Services.shared.layout.showSidebar(PanelID.sourceControl)
                }
                if git.status.upstream != nil {
                    StatusLabel(icon: git.busy != nil ? "arrow.triangle.2.circlepath" : "arrow.up.arrow.down",
                                text: "\(git.status.behind)↓ \(git.status.ahead)↑",
                                help: "Sync with \(git.status.upstream ?? "") (pull, then push)") { git.sync() }
                }
            }
        } else if let b = workspace.gitBranch {
            StatusLabel(icon: "arrow.triangle.branch", text: b, help: "Git branch")
        } else if workspace.root != nil {
            StatusLabel(icon: "folder", text: workspace.name)
        }
    }
}

// MARK: - Diff overlay

/// Side-by-side (or inline) diff against HEAD, floating over the editor area.
struct DiffOverlay: View {
    @ObservedObject var git = GitController.shared
    var body: some View {
        if let m = git.openDiff { DiffView(model: m).id(m.id).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

struct DiffView: View {
    let model: DiffModel
    @State private var inline = false
    @State private var rows: [LineDiffer.Row] = []
    @State private var stats = (added: 0, removed: 0)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right").foregroundColor(Theme.accent)
                Text(model.title).font(.system(size: 13, weight: .semibold))
                Text("\(model.oldLabel) ↔ \(model.newLabel)").font(.system(size: 11)).foregroundColor(Theme.muted)
                Text("+\(stats.added)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(Theme.green)
                Text("−\(stats.removed)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundColor(Theme.red)
                Spacer()
                Picker("", selection: $inline) {
                    Text("Side by side").tag(false)
                    Text("Inline").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Button("Open File") {
                    GitController.shared.openDiff = nil
                    _ = Services.shared.editors.open(model.url)
                }.font(.system(size: 11.5))
                Button { GitController.shared.openDiff = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.plain).foregroundColor(Theme.muted).keyboardShortcut(.cancelAction).help("Close (Esc)")
            }
            .padding(.horizontal, 14).frame(height: 38)
            .background(Theme.chrome)
            Hairline()
            if rows.isEmpty {
                PlaceholderPanel(title: "No differences", icon: "equal.circle", message: "\(model.newLabel) matches \(model.oldLabel).")
            } else {
                GeometryReader { geo in
                    if inline {
                        ScrollView([.vertical, .horizontal]) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(inlineRows) { r in inlineRow(r) }
                            }
                            .padding(.vertical, 6)
                            .frame(minWidth: geo.size.width, alignment: .leading)
                        }
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(rows) { r in sideRow(r, column: max(200, (geo.size.width - 1) / 2)) }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
            }
        }
        .background(Theme.editorBg)
        .onAppear { inline = RunSelfTest.inlineDiffDemo; compute() }
    }

    private func compute() {
        let a = LineDiffer.lines(model.oldText), b = LineDiffer.lines(model.newText)
        let r = LineDiffer.rows(a, b)
        let onlyFolds = r.allSatisfy { $0.kind == .same || $0.kind == .fold }
        rows = onlyFolds ? [] : r
        stats = (r.filter { $0.kind == .added || $0.kind == .changed }.count, r.filter { $0.kind == .removed || $0.kind == .changed }.count)
    }

    private struct InlineRow: Identifiable {
        let id: String
        let kind: LineDiffer.Row.Kind
        let oldNo: Int?
        let newNo: Int?
        let text: String
        var fold = 0
    }

    private var inlineRows: [InlineRow] {
        var out: [InlineRow] = []
        for r in rows {
            switch r.kind {
            case .same: out.append(InlineRow(id: "s\(r.id)", kind: .same, oldNo: r.left?.0, newNo: r.right?.0, text: r.right?.1 ?? ""))
            case .fold: out.append(InlineRow(id: "f\(r.id)", kind: .fold, oldNo: nil, newNo: nil, text: "", fold: r.foldCount))
            default:
                if let l = r.left { out.append(InlineRow(id: "d\(r.id)", kind: .removed, oldNo: l.0, newNo: nil, text: l.1)) }
                if let n = r.right { out.append(InlineRow(id: "a\(r.id)", kind: .added, oldNo: nil, newNo: n.0, text: n.1)) }
            }
        }
        // removed lines of a block first, then added (like `git diff`)
        var sorted: [InlineRow] = []
        var dels: [InlineRow] = [], adds: [InlineRow] = []
        for r in out {
            if r.kind == .removed { dels.append(r) } else if r.kind == .added { adds.append(r) } else {
                sorted += dels + adds; dels = []; adds = []; sorted.append(r)
            }
        }
        return sorted + dels + adds
    }

    private let mono = Font.system(size: 12, design: .monospaced)

    private func lineNo(_ n: Int?) -> some View {
        Text(n.map { "\($0 + 1)" } ?? "").font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.muted)
            .frame(width: 44, alignment: .trailing).padding(.trailing, 6)
    }

    private func foldRow(_ n: Int) -> some View {
        HStack {
            Image(systemName: "ellipsis").font(.system(size: 10))
            Text("\(n) unchanged line\(n == 1 ? "" : "s")").font(.system(size: 11))
        }
        .foregroundColor(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 56).frame(height: 22)
        .background(Theme.panel2.opacity(0.35))
    }

    @ViewBuilder private func sideRow(_ r: LineDiffer.Row, column: CGFloat) -> some View {
        if r.kind == .fold { foldRow(r.foldCount) } else {
            HStack(spacing: 0) {
                cell(r.left, colour: r.kind == .removed || r.kind == .changed ? Color(nsColor: Theme.ndiffRemoved) : nil, sign: r.left != nil && r.kind != .same ? "−" : " ")
                    .frame(width: column, alignment: .leading).clipped()
                Rectangle().fill(Theme.line).frame(width: 1)
                cell(r.right, colour: r.kind == .added || r.kind == .changed ? Color(nsColor: Theme.ndiffAdded) : nil, sign: r.right != nil && r.kind != .same ? "+" : " ")
                    .frame(width: column, alignment: .leading).clipped()
            }
            .frame(height: 19)
        }
    }

    private func cell(_ c: (Int, String)?, colour: Color?, sign: String) -> some View {
        HStack(spacing: 0) {
            lineNo(c?.0)
            Text(sign).font(mono).foregroundColor(Theme.muted).frame(width: 12)
            Text(c?.1.replacingOccurrences(of: "\t", with: "    ") ?? "").font(mono).lineLimit(1).truncationMode(.tail)
                .help(c?.1 ?? "")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(c == nil ? Theme.panel2.opacity(0.25) : (colour ?? Color.clear))
    }

    @ViewBuilder private func inlineRow(_ r: InlineRow) -> some View {
        if r.kind == .fold { foldRow(r.fold) } else {
            HStack(spacing: 0) {
                lineNo(r.oldNo)
                lineNo(r.newNo)
                Text(r.kind == .added ? "+" : r.kind == .removed ? "−" : " ").font(mono).foregroundColor(Theme.muted).frame(width: 14)
                Text(r.text.replacingOccurrences(of: "\t", with: "    ")).font(mono).lineLimit(1).fixedSize()
                Spacer(minLength: 0)
            }
            .frame(height: 19)
            .background(r.kind == .added ? Color(nsColor: Theme.ndiffAdded) : r.kind == .removed ? Color(nsColor: Theme.ndiffRemoved) : Color.clear)
        }
    }
}
