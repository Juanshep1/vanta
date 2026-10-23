import SwiftUI

/// The right-hand Vee panel (⌘L): conversations, Chat / Agent / Ask the Book
/// modes, streaming replies, agent tool cards, Review Changes, @-mentions.
struct AIPanel: View {
    @ObservedObject var vee = VeeAssistant.shared
    @ObservedObject var store = ChatStore.shared
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            modeBar
            Hairline().opacity(0.6)
            messages
            footer
        }
        .background(Theme.bg)
        .foregroundColor(Theme.ink)
    }

    // MARK: header

    var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(LinearGradient(colors: [Theme.accentDim, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("V").font(.system(size: 13, weight: .heavy)).foregroundColor(.white)
            }.frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text(store.current.items.isEmpty ? "Vee" : store.current.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 10.5)).foregroundColor(vee.busy ? Theme.accent : Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 4)
            IconButton(icon: "clock.arrow.circlepath", help: "Chat history") { showHistory.toggle() }
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { HistoryList(close: { showHistory = false }) }
            IconButton(icon: "square.and.pencil", help: "New chat") { if !vee.busy { store.newConversation(); vee.focusToken += 1 } }
            IconButton(icon: "xmark", help: "Hide (⌘L)") { Services.shared.layout.auxVisible = false }
        }
        .padding(.horizontal, 10).frame(height: 42)
    }

    var subtitle: String {
        if !vee.status.isEmpty { return vee.status }
        if !vee.hasKey { return "add an API key in Settings › AI" }
        return "\(vee.providerLabel) · \(Self.shortModel(vee.settings.smartModel))"
    }

    static func shortModel(_ m: String) -> String {
        let last = String(m.split(separator: "/").last ?? Substring(m))
        if last.hasPrefix("claude-") {
            let p = last.dropFirst(7).split(separator: "-")
            if p.count >= 3 { return "\(p[0].capitalized) \(p[1]).\(p[2])" }
        }
        return last
    }

    var modeBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                modeButton("chat", "Chat", "bubble.left.and.bubble.right")
                modeButton("agent", "Agent", "bolt.fill")
                modeButton("book", "Book", "book")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
            Spacer(minLength: 4)
            ModelPicker()
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    func modeButton(_ id: String, _ title: String, _ icon: String) -> some View {
        let on = vee.mode == id
        return Button { vee.mode = id } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.accentDim : .clear))
            .foregroundColor(on ? .white : Theme.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id == "agent" ? "Agent: Vee plans, edits files, runs and tests the code, and fixes errors on its own"
              : id == "book" ? "Ask the Book: answers only from The Vanta Book and docs, with citations"
              : "Chat: ask questions about Vanta or your code")
    }

    // MARK: messages

    var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if store.current.items.isEmpty { EmptyState() }
                    ForEach(store.current.items) { item in
                        ChatItemView(item: item, streaming: item.id == vee.streamingItemID)
                            .id(item.id)
                    }
                    if vee.busy && vee.streamingItemID == nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(vee.status.isEmpty ? "Working…" : vee.status).font(.system(size: 11.5)).foregroundColor(Theme.muted)
                        }.padding(.leading, 4)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10).padding(.vertical, 10)
            }
            .onChange(of: store.current.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.current.items.last?.text.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: store.currentID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: footer

    var footer: some View {
        VStack(spacing: 8) {
            ReviewChangesView()
            QuestionCard()
            ChatInput()
        }
        .padding(10)
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .top)
    }
}

// MARK: - Empty state

struct EmptyState: View {
    @ObservedObject var vee = VeeAssistant.shared

    var suggestions: [(String, String)] {
        switch vee.mode {
        case "agent": return [("Build a quiz game", "Build a small quiz game in quiz.va that asks 3 questions and keeps score, with tests for the scoring."),
                              ("Add tests", "Add tests for the functions in the current file and make them pass."),
                              ("Fix my project", "Run my program and the tests, then fix whatever fails.")]
        case "book": return [("Default values", "How do default parameter values work?"),
                             ("Types", "How do I make my own type with methods?"),
                             ("Files", "How do I read and write a JSON file?")]
        default: return [("Explain my file", "Explain what my current file does, simply."),
                         ("Make something", "Write me a fun little Vanta program."),
                         ("Improve it", "Make my current file cleaner and more idiomatic Vanta.")]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(vee.mode == "agent" ? "Agent mode" : vee.mode == "book" ? "Ask the Book" : "Hi, I'm Vee 👋")
                .font(.system(size: 16, weight: .bold))
            Text(vee.mode == "agent"
                 ? "Give me a goal. I'll plan, write the files, run the program and the tests, read the errors and fix them until everything is clean. Every change waits for your review, and each request is a checkpoint you can roll back."
                 : vee.mode == "book"
                 ? "Ask anything about Vanta 6.0. I answer from The Vanta Book and the docs, and tell you which chapter to read."
                 : "Ask about Vanta or your code. Type @ to add context: a file, @selection, @problems, @console, @codebase, @book. Select code and press ⌘L to ask about it, or ⌘K to edit it in place.")
                .font(.system(size: 12.5)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggestions, id: \.0) { s in
                    Button { vee.send(s.1) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkle").font(.system(size: 10)).foregroundColor(Theme.accent)
                            Text(s.0).font(.system(size: 12, weight: .medium))
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if !vee.hasKey {
                Button { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) } label: {
                    Label("Add an API key in Settings › AI", systemImage: "key.fill").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).foregroundColor(Theme.amber)
            }
        }
        .padding(6)
    }
}

// MARK: - Messages

struct ChatItemView: View {
    let item: ChatItem
    var streaming = false
    @ObservedObject var vee = VeeAssistant.shared
    @ObservedObject var tracker = ChangeTracker.shared
    @State private var hover = false
    @State private var showThinking = false
    @State private var showRefs = false

    var body: some View {
        switch item.role {
        case .user: user
        case .assistant: assistant
        case .tool: if let t = item.tool { ToolCardView(step: t) }
        case .notice:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: item.isError ? "exclamationmark.circle" : "info.circle").font(.system(size: 11))
                    .foregroundColor(item.isError ? Theme.amber : Theme.muted)
                Text(MarkdownParser.inline(item.text)).font(.system(size: 11.5)).foregroundColor(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 6)
        }
    }

    var user: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if !item.attachments.isEmpty {
                FlowChips(items: item.attachments.map { ($0.label, "selection.pin.in.out") })
            }
            Text(item.text).font(.system(size: 12.5))
                .textSelection(.enabled)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 11).fill(vee.editingItemID == item.id ? Theme.amber.opacity(0.4) : Theme.accentDim))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: 8) {
                if !item.refs.isEmpty {
                    Button { showRefs.toggle() } label: {
                        Text("\(item.refs.count) context source\(item.refs.count == 1 ? "" : "s") \(showRefs ? "▴" : "▾")")
                            .font(.system(size: 10.5)).foregroundColor(Theme.muted)
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let cp = item.checkpointID, tracker.checkpoint(cp) != nil {
                    Button { vee.restoreCheckpoint(cp) } label: {
                        Label("Restore checkpoint", systemImage: "arrow.uturn.backward").font(.system(size: 10.5))
                    }.buttonStyle(.plain).foregroundColor(Theme.muted).disabled(vee.busy)
                        .help("Put every file back the way it was before this request")
                }
                if hover && !vee.busy {
                    Button { vee.beginEdit(item) } label: { Label("Edit", systemImage: "pencil").font(.system(size: 10.5)) }
                        .buttonStyle(.plain).foregroundColor(Theme.muted).help("Edit and resend this message")
                }
            }
            if showRefs {
                FlowChips(items: item.refs.map { ($0.label, $0.icon) }, onTap: { i in open(item.refs[i]) })
            }
        }
        .onHover { hover = $0 }
    }

    var assistant: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { showThinking.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "brain").font(.system(size: 10))
                        Text(streaming && item.text.isEmpty ? "Thinking…" : "Thought process").font(.system(size: 11))
                        Image(systemName: showThinking ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }.foregroundColor(Theme.muted)
                }.buttonStyle(.plain)
                if showThinking {
                    Text(item.thinking).font(.system(size: 11.5)).foregroundColor(Theme.muted).italic()
                        .padding(.leading, 8).overlay(Rectangle().fill(Theme.line).frame(width: 2), alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if item.text.isEmpty && streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(vee.status.isEmpty ? "Thinking…" : vee.status).font(.system(size: 11.5)).foregroundColor(Theme.muted)
                }
            } else if item.isError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.amber).font(.system(size: 11))
                    MarkdownView(text: item.text, codeActions: false, fontSize: 12.5)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.amber.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber.opacity(0.35)))
            } else {
                MarkdownView(text: item.text, codeActions: !streaming)
            }
            if let u = item.usage, !streaming, u.total > 0 {
                Text(u.summary).font(.system(size: 9.5)).foregroundColor(Theme.muted.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func open(_ r: ContextRef) {
        guard let p = r.path else { return }
        let url = URL(fileURLWithPath: p)
        if r.kind == .book || r.kind == .docs {
            BookReaderModel.shared.open(url: url, line: r.line ?? 0)
            Services.shared.layout.showSidebar(PanelID.book)
        } else if let line = r.line {
            Services.shared.editors.open(location: Location(uri: url, range: TextRange(start: TextPosition(line: line, column: 0), end: TextPosition(line: line, column: 0))))
        } else {
            Services.shared.editors.open(url)
        }
    }
}

/// Small wrapping row of chips.
struct FlowChips: View {
    let items: [(String, String)]
    var onTap: ((Int) -> Void)? = nil
    var onRemove: ((Int) -> Void)? = nil

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                HStack(spacing: 3) {
                    Image(systemName: it.1).font(.system(size: 9))
                    Text(it.0).font(.system(size: 10.5)).lineLimit(1)
                    if let onRemove {
                        Button { onRemove(i) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2.5)
                .background(Capsule().fill(Theme.panel2))
                .foregroundColor(Theme.ink.opacity(0.85))
                .onTapGesture { onTap?(i) }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(maxW, widest), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Input with @-mentions

struct ChatInput: View {
    @ObservedObject var vee = VeeAssistant.shared
    @ObservedObject var workspace = Services.shared.workspace
    @FocusState private var focused: Bool
    @State private var selected = 0

    struct Suggestion: Hashable { let insert: String; let label: String; let detail: String; let icon: String }

    var mentionQuery: String? {
        guard let last = vee.input.split(separator: " ", omittingEmptySubsequences: false).last.map(String.init),
              last.hasPrefix("@"), !vee.input.hasSuffix(" ") else { return nil }
        let lastLine = last.split(separator: "\n").last.map(String.init) ?? last
        return lastLine.hasPrefix("@") ? String(lastLine.dropFirst()) : nil
    }

    var suggestions: [Suggestion] {
        guard let q = mentionQuery else { return [] }
        var out: [(Int, Suggestion)] = []
        for s in ContextBuilder.specials {
            if let m = Fuzzy.match(q, s.name) { out.append((m.score + 1000, Suggestion(insert: "@" + s.name, label: "@" + s.name, detail: s.help, icon: s.icon))) }
        }
        let root = workspace.root
        var folders = Set<String>()
        for url in workspace.fileIndex.prefix(4000) {
            let rel = root.map { url.path.hasPrefix($0.path + "/") ? String(url.path.dropFirst($0.path.count + 1)) : url.lastPathComponent } ?? url.lastPathComponent
            if let m = Fuzzy.match(q, rel) {
                out.append((m.score + (url.pathExtension == "va" ? 50 : 0), Suggestion(insert: "@" + rel, label: url.lastPathComponent, detail: rel, icon: "doc.text")))
            }
            let dir = (rel as NSString).deletingLastPathComponent
            if !dir.isEmpty && !folders.contains(dir) {
                folders.insert(dir)
                if let m = Fuzzy.match(q, dir) { out.append((m.score - 20, Suggestion(insert: "@" + dir + "/", label: dir + "/", detail: "folder", icon: "folder"))) }
            }
        }
        return out.sorted { $0.0 > $1.0 }.prefix(8).map(\.1)
    }

    var body: some View {
        let sugg = suggestions
        VStack(alignment: .leading, spacing: 6) {
            if vee.editingItemID != nil {
                HStack {
                    Label("Editing a message — sending replaces it and everything after", systemImage: "pencil").font(.system(size: 10.5))
                        .foregroundColor(Theme.amber)
                    Spacer()
                    Button("Cancel") { vee.cancelEdit() }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold))
                }
            }
            if !sugg.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sugg.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 7) {
                            Image(systemName: s.icon).font(.system(size: 10.5)).foregroundColor(Theme.accent).frame(width: 14)
                            Text(s.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(s.detail).font(.system(size: 10.5)).foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(i == min(selected, sugg.count - 1) ? Theme.panel2 : .clear))
                        .contentShape(Rectangle())
                        .onTapGesture { accept(s) }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel).shadow(color: .black.opacity(0.25), radius: 8, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            }
            VStack(alignment: .leading, spacing: 6) {
                if !vee.attachments.isEmpty {
                    FlowChips(items: vee.attachments.map { ($0.label, "selection.pin.in.out") },
                              onRemove: { i in vee.attachments.remove(at: i) })
                }
                TextField(placeholder, text: $vee.input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12.5))
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit { submit(sugg) }
                    .onKeyPress(.upArrow) { if sugg.isEmpty { return .ignored }; selected = max(0, selected - 1); return .handled }
                    .onKeyPress(.downArrow) { if sugg.isEmpty { return .ignored }; selected = min(sugg.count - 1, selected + 1); return .handled }
                    .onKeyPress(.tab) { if sugg.isEmpty { return .ignored }; accept(sugg[min(selected, sugg.count - 1)]); return .handled }
                    .onKeyPress(.escape) {
                        if vee.busy { vee.stop(); return .handled }
                        if vee.editingItemID != nil { vee.cancelEdit(); return .handled }
                        return .ignored
                    }
                    .onChange(of: mentionQuery) { _, _ in selected = 0 }
                HStack(spacing: 8) {
                    Button { vee.input += (vee.input.isEmpty || vee.input.hasSuffix(" ") || vee.input.hasSuffix("\n") ? "@" : " @"); focused = true } label: {
                        Image(systemName: "at").font(.system(size: 11, weight: .semibold))
                    }.buttonStyle(.plain).foregroundColor(Theme.muted).help("Add context: a file, folder, @selection, @problems, @console, @codebase, @book, @docs")
                    if Services.shared.editor?.selectedText.isEmpty == false {
                        Button { vee.addSelectionToChat() } label: {
                            Label("selection", systemImage: "plus").font(.system(size: 10.5))
                        }.buttonStyle(.plain).foregroundColor(Theme.muted).help("Attach the editor selection (⌘L)")
                    }
                    Spacer()
                    UsageLabel()
                    if vee.busy {
                        Button { vee.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 20))
                        }.buttonStyle(.plain).foregroundColor(Theme.red).help("Stop (Esc)")
                    } else {
                        Button { submit(sugg) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        }.buttonStyle(.plain).foregroundColor(vee.input.trimmingCharacters(in: .whitespaces).isEmpty ? Theme.muted : Theme.accent)
                            .help(vee.mode == "agent" ? "Start the agent (↩)" : "Send (↩)")
                    }
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: 1))
        }
        .onChange(of: vee.focusToken) { _, _ in focused = true }
    }

    var placeholder: String {
        switch vee.mode {
        case "agent": return "Tell Vee what to build or fix…"
        case "book": return "Ask The Vanta Book…"
        default: return "Ask Vee… (@ for context)"
        }
    }

    func submit(_ sugg: [Suggestion]) {
        if !sugg.isEmpty { accept(sugg[min(selected, sugg.count - 1)]); return }
        vee.send()
    }

    func accept(_ s: Suggestion) {
        guard let q = mentionQuery else { return }
        vee.input = String(vee.input.dropLast(q.count + 1)) + s.insert + " "
        focused = true
    }
}

struct UsageLabel: View {
    @ObservedObject var store = ChatStore.shared
    var body: some View {
        let u = store.current.usage
        if u.total > 0 {
            Text(UsageLabel.text(u)).font(.system(size: 10)).foregroundColor(Theme.muted)
                .help("This conversation: \(u.summary)")
        }
    }
    static func text(_ u: LLMUsage) -> String {
        let tok = LLMUsage.short(u.total) + " tok"
        return u.cost > 0 ? tok + String(format: " · $%.3f", u.cost) : tok
    }
}

// MARK: - Model picker

struct ModelPicker: View {
    @ObservedObject var vee = VeeAssistant.shared
    var body: some View {
        Menu {
            Section("Smart model (chat · agent · ⌘K)") {
                ForEach(options, id: \.self) { m in
                    Button { vee.settings.smartModel = m } label: {
                        if m == vee.settings.smartModel { Label(m, systemImage: "checkmark") } else { Text(m) }
                    }
                }
            }
            Divider()
            Button("More models in Settings…") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cpu").font(.system(size: 9.5))
                Text(AIPanel.shortModel(vee.settings.smartModel)).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .foregroundColor(Theme.muted)
        .help("Model for chat, agent and ⌘K")
    }

    var options: [String] {
        var list = AIProvider.curatedModels(vee.settings.provider)
        for m in vee.modelCatalog.prefix(30) where !list.contains(m) { list.append(m) }
        if !list.contains(vee.settings.smartModel) { list.insert(vee.settings.smartModel, at: 0) }
        return list
    }
}

// MARK: - History

struct HistoryList: View {
    @ObservedObject var store = ChatStore.shared
    let close: () -> Void
    @State private var renaming: UUID?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chats").font(.system(size: 12, weight: .bold))
                Spacer()
                Button { store.newConversation(); close() } label: { Label("New", systemImage: "plus").font(.system(size: 11)) }.buttonStyle(.plain)
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(store.sorted) { c in row(c) }
                }
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 290)
    }

    func row(_ c: Conversation) -> some View {
        HStack(spacing: 6) {
            Image(systemName: c.items.contains { $0.mode == "agent" } ? "bolt" : "bubble.left").font(.system(size: 10)).foregroundColor(Theme.muted)
            if renaming == c.id {
                TextField("Name", text: $name, onCommit: { store.rename(c.id, to: name); renaming = nil })
                    .textFieldStyle(.roundedBorder).font(.system(size: 12))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.items.isEmpty ? "New chat" : c.title).font(.system(size: 12, weight: c.id == store.currentID ? .semibold : .regular)).lineLimit(1)
                    Text(c.updated.formatted(.relative(presentation: .named)) + " · \(c.items.filter { $0.role == .user }.count) messages")
                        .font(.system(size: 10)).foregroundColor(Theme.muted)
                }
            }
            Spacer()
            Button { renaming = c.id; name = c.title } label: { Image(systemName: "pencil").font(.system(size: 10)) }.buttonStyle(.plain).help("Rename")
            Button { store.delete(c.id) } label: { Image(systemName: "trash").font(.system(size: 10)) }.buttonStyle(.plain).help("Delete")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(c.id == store.currentID ? Theme.panel2.opacity(0.6) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.select(c.id); close() }
    }
}
