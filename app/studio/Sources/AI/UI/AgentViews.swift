import SwiftUI

/// A collapsible card for one agent tool call: name + arguments + live status, result on expand.
struct ToolCardView: View {
    let step: ToolStep
    @State private var expanded = false

    var body: some View {
        let args = LLMToolCall(id: step.callID, name: step.name, arguments: step.arguments).args
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: AgentTools.icon(step.name)).font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(tint).frame(width: 14)
                    Text(AgentTools.title(step.name)).font(.system(size: 11.5, weight: .semibold))
                    Text(AgentTools.summary(step.name, args)).font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Theme.muted).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    statusBadge
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundColor(Theme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    argumentsView(args)
                    if !step.result.isEmpty {
                        Text("RESULT").font(.system(size: 9.5, weight: .bold)).tracking(0.5).foregroundColor(Theme.muted)
                        ScrollView {
                            Text(step.result).font(.system(size: 11, design: .monospaced))
                                .foregroundColor(step.status == .failed ? Theme.red : Theme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
                .padding(9)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(step.status == .failed ? Theme.red.opacity(0.35) : Theme.line, lineWidth: 1))
    }

    var tint: Color {
        switch step.status {
        case .failed: return Theme.red
        case .running, .waiting: return Theme.accent
        case .denied: return Theme.muted
        case .done: return AgentTools.writeTools.contains(step.name) ? Theme.amber : Theme.green
        }
    }

    @ViewBuilder var statusBadge: some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini)
        case .waiting: Text("waiting").font(.system(size: 10)).foregroundColor(Theme.accent)
        case .failed: Image(systemName: "xmark.circle.fill").font(.system(size: 10.5)).foregroundColor(Theme.red)
        case .denied: Image(systemName: "stop.circle").font(.system(size: 10.5)).foregroundColor(Theme.muted)
        case .done:
            HStack(spacing: 3) {
                if step.durationMs >= 400 { Text(step.durationMs >= 1000 ? String(format: "%.1fs", Double(step.durationMs) / 1000) : "\(step.durationMs)ms")
                    .font(.system(size: 9.5)).foregroundColor(Theme.muted) }
                Image(systemName: "checkmark.circle.fill").font(.system(size: 10.5)).foregroundColor(Theme.green)
            }
        }
    }

    @ViewBuilder
    func argumentsView(_ a: [String: Any]) -> some View {
        switch step.name {
        case "write_file", "create_file":
            CodeBlockView(code: ContextBuilder.clip(a["content"] as? String ?? "", 4000), lang: "vanta",
                          fileHint: a["path"] as? String, showActions: false)
        case "edit_file":
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(LineDiff.diff(a["old_string"] as? String ?? "", a["new_string"] as? String ?? "").enumerated()), id: \.offset) { _, d in
                    DiffRow(kind: d.kind, text: d.text)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        default:
            let pretty = a.filter { $0.key != "content" }.sorted { $0.key < $1.key }
                .map { "\($0.key): \(($0.value as? String).map { "\"\($0)\"" } ?? "\($0.value)")" }.joined(separator: "\n")
            if !pretty.isEmpty {
                Text(pretty).font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.muted).textSelection(.enabled)
            }
        }
    }
}

struct DiffRow: View {
    let kind: DiffKind
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            Text(kind == .add ? "+" : kind == .remove ? "−" : " ").font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(kind == .add ? Theme.green : kind == .remove ? Theme.red : Theme.muted).frame(width: 10)
            Text(text.isEmpty ? " " : text).font(.system(size: 11, design: .monospaced)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5).padding(.vertical, 0.5)
        .background(kind == .add ? Color(nsColor: Theme.ndiffAdded) : kind == .remove ? Color(nsColor: Theme.ndiffRemoved) : .clear)
    }
}

/// "Review changes": the agent's staged file changes with per-hunk, per-file and all-at-once Accept/Reject.
struct ReviewChangesView: View {
    @ObservedObject var tracker = ChangeTracker.shared
    @State private var openFiles: Set<URL> = []
    @State private var listHeight: CGFloat = 60

    var body: some View {
        if !tracker.pending.isEmpty {
            let st = tracker.totalStats
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.15)) { tracker.reviewExpanded.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(tracker.reviewExpanded ? 90 : 0))
                            Text("\(st.files) file\(st.files == 1 ? "" : "s") changed").font(.system(size: 11.5, weight: .semibold))
                            Text("+\(st.added)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Theme.green)
                            Text("−\(st.removed)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(Theme.red)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Spacer()
                    smallButton("Reject all", Theme.red) { tracker.rejectAll() }
                    smallButton("Accept all", Theme.green, filled: true) { tracker.acceptAll() }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                if tracker.reviewExpanded {
                    Rectangle().fill(Theme.line).frame(height: 1)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(tracker.pending) { f in fileRow(f) }
                        }
                        .padding(8)
                        .background(GeometryReader { g in Color.clear.preference(key: ListHeightKey.self, value: g.size.height) })
                    }
                    .frame(height: min(340, max(36, listHeight)))
                    .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
                }
            }
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.amber.opacity(0.45), lineWidth: 1))
            .id(tracker.revision)
        }
    }

    func fileRow(_ f: ChangeTracker.PendingFile) -> some View {
        let s = tracker.stats(f)
        let open = openFiles.contains(f.url)
        let created = f.baseline == nil
        let deleted = tracker.current(f) == nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    if open { openFiles.remove(f.url) } else { openFiles.insert(f.url) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).rotationEffect(.degrees(open ? 90 : 0))
                        FileIcon(name: f.url.lastPathComponent, isDirectory: false)
                        Text(WorkspaceFS.relative(f.url)).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                        if created { tag("new", Theme.green) }
                        if deleted { tag("deleted", Theme.red) }
                        Text("+\(s.added) −\(s.removed)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.muted)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                Spacer(minLength: 2)
                if !deleted {
                    IconButton(icon: "arrow.up.forward.square", help: "Open file", size: 11) { Services.shared.editors.open(f.url) }
                }
                IconButton(icon: "xmark", help: "Reject this file", size: 10.5) { tracker.reject(f) }
                IconButton(icon: "checkmark", help: "Accept this file", size: 10.5) { tracker.accept(f) }
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tracker.hunks(f)) { h in hunkView(h, f) }
                }
                .padding(.leading, 14)
            }
        }
    }

    func hunkView(_ h: DiffHunk, _ f: ChangeTracker.PendingFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("line \(h.newStart + 1)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.muted)
                Spacer()
                Button("Reject") { tracker.reject(h, in: f) }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.red)
                Button("Accept") { tracker.accept(h, in: f) }.buttonStyle(.plain).font(.system(size: 10.5, weight: .semibold)).foregroundColor(Theme.green)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Theme.panel2.opacity(0.5))
            ForEach(Array(h.baseLines.prefix(40).enumerated()), id: \.offset) { _, l in DiffRow(kind: .remove, text: l) }
            ForEach(Array(h.newLines.prefix(60).enumerated()), id: \.offset) { _, l in DiffRow(kind: .add, text: l) }
            if h.newLines.count > 60 { Text("… \(h.newLines.count - 60) more lines").font(.system(size: 10)).foregroundColor(Theme.muted).padding(4) }
        }
        .background(Theme.editorBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
    }

    func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 9, weight: .bold)).padding(.horizontal, 4).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.18))).foregroundColor(c)
    }

    func smallButton(_ title: String, _ color: Color, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(filled ? color.opacity(0.85) : color.opacity(0.12)))
                .foregroundColor(filled ? .white : color)
        }.buttonStyle(.plain)
    }
}

/// The agent's ask_user question, with an answer field.
struct QuestionCard: View {
    @ObservedObject var vee = VeeAssistant.shared
    @State private var answer = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let q = vee.question {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "questionmark.bubble.fill").foregroundColor(Theme.accent)
                    Text("Vee needs your input").font(.system(size: 11.5, weight: .semibold))
                }
                Text(MarkdownParser.inline(q.text)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TextField("Your answer…", text: $answer).textFieldStyle(.roundedBorder).focused($focused)
                        .onSubmit { send() }
                    Button("Send") { send() }.keyboardShortcut(.return, modifiers: [])
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.accent.opacity(0.5)))
            .onAppear { focused = true }
        }
    }

    func send() { vee.answerQuestion(answer); answer = "" }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
