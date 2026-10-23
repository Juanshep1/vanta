import SwiftUI
import AppKit

// MARK: - Find / replace (in file)

final class FindModel: ObservableObject {
    @Published var visible = false
    @Published var showReplace = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var regex = false
    @Published var caseSensitive = false
    @Published var wholeWord = false
    @Published var inSelection = false
    @Published private(set) var matches: [NSRange] = []
    @Published var current: Int = -1
    @Published var error: String?
    @Published var focusToken = 0            // bump to focus the field

    func regexObject() -> NSRegularExpression? {
        guard !query.isEmpty else { return nil }
        var p = regex ? query : NSRegularExpression.escapedPattern(for: query)
        if wholeWord { p = "\\b(?:" + p + ")\\b" }
        var o: NSRegularExpression.Options = [.anchorsMatchLines]
        if !caseSensitive { o.insert(.caseInsensitive) }
        do { error = nil; return try NSRegularExpression(pattern: p, options: o) }
        catch { self.error = "Invalid regex"; return nil }
    }

    func compute(in text: String, scope: NSRange? = nil) {
        guard let re = regexObject() else { matches = []; current = -1; return }
        let ns = text as NSString
        let range = scope ?? NSRange(location: 0, length: ns.length)
        var out: [NSRange] = []
        re.enumerateMatches(in: text, range: range) { m, _, stop in
            if let m, m.range.length > 0 { out.append(m.range) }
            if out.count >= 20000 { stop.pointee = true }
        }
        matches = out
        if current >= out.count { current = out.isEmpty ? -1 : 0 }
    }

    /// Index of the first match at/after `offset` (wrapping).
    func index(after offset: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.location >= offset } ?? 0
    }
}

struct FindBar: View {
    @ObservedObject var model: FindModel
    var onNext: () -> Void
    var onPrev: () -> Void
    var onReplace: () -> Void
    var onReplaceAll: () -> Void
    var onClose: () -> Void
    @FocusState private var focus: Field?
    enum Field { case find, replace }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { model.showReplace.toggle() } label: {
                Image(systemName: model.showReplace ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 16, height: 24)
            }.buttonStyle(.plain).foregroundColor(Theme.muted)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    field("Find", text: $model.query, field: .find)
                        .onSubmit { onNext() }
                    toggle("Aa", on: $model.caseSensitive, help: "Match Case")
                    toggle("ab", on: $model.wholeWord, help: "Match Whole Word", underline: true)
                    toggle(".*", on: $model.regex, help: "Use Regular Expression")
                    Text(countText).font(.system(size: 11)).foregroundColor(model.error != nil ? Theme.red : Theme.muted)
                        .frame(width: 74, alignment: .leading).lineLimit(1)
                    iconButton("arrow.up", help: "Previous Match (⇧↩)", action: onPrev)
                    iconButton("arrow.down", help: "Next Match (↩)", action: onNext)
                    iconButton("xmark", help: "Close (Esc)", action: onClose)
                }
                if model.showReplace {
                    HStack(spacing: 4) {
                        field("Replace", text: $model.replacement, field: .replace)
                            .onSubmit { onReplace() }
                        iconButton("arrow.turn.down.right", help: "Replace (↩)", action: onReplace)
                        iconButton("text.badge.checkmark", help: "Replace All (⌘⌥↩)", action: onReplaceAll)
                            .keyboardShortcut(.return, modifiers: [.command, .option])
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 430)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
        .onExitCommand { onClose() }
        .onAppear { focus = .find }
        .onChange(of: model.focusToken) { _, _ in focus = model.showReplace && focus == .replace ? .replace : .find }
    }

    var countText: String {
        if let e = model.error { return e }
        if model.query.isEmpty { return "" }
        if model.matches.isEmpty { return "No results" }
        return "\(max(0, model.current) + 1) of \(model.matches.count)\(model.matches.count >= 20000 ? "+" : "")"
    }

    func field(_ placeholder: String, text: Binding<String>, field f: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 7).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editorBg))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focus == f ? Theme.accent : Theme.line))
            .focused($focus, equals: f)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                onPrev(); return .handled
            }
    }

    func toggle(_ label: String, on: Binding<Bool>, help: String, underline: Bool = false) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)).underline(underline)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(on.wrappedValue ? Theme.accentDim.opacity(0.45) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(on.wrappedValue ? Theme.accent : .clear))
        }.buttonStyle(.plain).foregroundColor(on.wrappedValue ? Theme.ink : Theme.muted).help(help)
    }

    func iconButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22)
        }.buttonStyle(.plain).foregroundColor(Theme.muted).help(help)
    }
}

// MARK: - Completion popup

final class CompletionModel: ObservableObject {
    @Published var items: [CompletionItem] = []
    @Published var selected = 0
    @Published var isVisible = false
    /// Range of the identifier fragment being completed.
    var replaceRange = NSRange(location: 0, length: 0)
    var matchIndices: [UUID: [Int]] = [:]

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        selected = max(0, min(items.count - 1, selected + d))
    }

    var current: CompletionItem? { items.indices.contains(selected) ? items[selected] : nil }
}

struct CompletionList: View {
    @ObservedObject var model: CompletionModel
    var onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == model.selected)
                                .id(i)
                                .contentShape(Rectangle())
                                .onTapGesture { onPick(i) }
                        }
                    }
                }
                .onChange(of: model.selected) { _, s in proxy.scrollTo(s) }
            }
            .frame(height: min(CGFloat(model.items.count), 9) * 22)
            if let doc = model.current?.documentation ?? model.current?.detail, !doc.isEmpty {
                Divider().overlay(Theme.line)
                Text(doc).font(.system(size: 11)).foregroundColor(Theme.muted)
                    .lineLimit(3).padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel)
            .shadow(color: .black.opacity(0.4), radius: 12, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    func row(_ item: CompletionItem, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 11)).foregroundColor(color(item.kind)).frame(width: 14)
            highlighted(item.label, indices: model.matchIndices[item.id] ?? [])
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let d = item.detail {
                Text(d).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).frame(height: 22)
        .background(selected ? Theme.accentDim.opacity(0.35) : Color.clear)
    }

    func highlighted(_ s: String, indices: [Int]) -> Text {
        let set = Set(indices)
        var t = Text("")
        for (i, ch) in s.utf16.enumerated() {
            let piece = Text(String(utf16CodeUnits: [ch], count: 1))
            t = t + (set.contains(i) ? piece.foregroundColor(Theme.accent).bold() : piece.foregroundColor(Theme.ink))
        }
        return t
    }

    func color(_ k: CompletionKind) -> Color {
        switch k {
        case .keyword: return Theme.accent
        case .function, .method: return Theme.blue
        case .type: return Theme.amber
        case .constant: return Theme.red
        case .snippet: return Theme.green
        default: return Theme.muted
        }
    }
}

// MARK: - Hover card

struct HoverCard: View {
    struct Entry: Identifiable { let id = UUID(); let severity: DiagnosticSeverity?; let text: String }
    let entries: [Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider().overlay(Theme.line) }
                HStack(alignment: .top, spacing: 6) {
                    if let s = e.severity {
                        Image(systemName: DiagnosticIcon.symbol(s)).foregroundColor(DiagnosticIcon.color(s))
                            .font(.system(size: 11))
                    }
                    MarkdownText(e.text)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel)
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
    }
}

/// Light Markdown: paragraphs + ``` code blocks + inline `code`/**bold** via AttributedString.
struct MarkdownText: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "```").enumerated()), id: \.offset) { i, part in
                if i % 2 == 1 {
                    let code = part.drop { $0 != "\n" }.dropFirst()
                    Text(String(code.isEmpty ? Substring(part) : code).trimmingCharacters(in: .newlines))
                        .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.ink)
                        .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.editorBg))
                } else if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text((try? AttributedString(markdown: part.trimmingCharacters(in: .whitespacesAndNewlines),
                                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                         ?? AttributedString(part))
                        .font(.system(size: 12)).foregroundColor(Theme.ink)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

enum DiagnosticIcon {
    static func symbol(_ s: DiagnosticSeverity) -> String {
        switch s {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .hint: return "lightbulb.fill"
        }
    }
    static func color(_ s: DiagnosticSeverity) -> Color { Color(nsColor: nsColor(s)) }
    static func nsColor(_ s: DiagnosticSeverity) -> NSColor {
        switch s {
        case .error: return Theme.nRose
        case .warning: return Theme.nAmber
        case .info: return Theme.nBlue
        case .hint: return Theme.nMint
        }
    }
}

// MARK: - Inline diff accept/reject bar

struct InlineDiffBar: View {
    let added: Int
    let removed: Int
    var onAccept: () -> Void
    var onReject: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(added)").foregroundColor(Theme.green)
            Text("−\(removed)").foregroundColor(Theme.red)
            Button(action: onAccept) {
                Text("Accept ⌘↩").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.green)).foregroundColor(.black)
            }.buttonStyle(.plain)
            Button(action: onReject) {
                Text("Reject ⎋").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel2)).foregroundColor(Theme.ink)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
            }.buttonStyle(.plain)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel).shadow(color: .black.opacity(0.3), radius: 6, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.line))
        .fixedSize()
    }
}

/// External-change banner inside an editor pane.
struct ConflictBanner: View {
    var onReload: () -> Void
    var onKeep: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.amber)
            Text("This file changed on disk and you have unsaved edits.").font(.system(size: 12))
            Spacer()
            Button("Reload from Disk", action: onReload).controlSize(.small)
            Button("Keep Mine", action: onKeep).controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.amber.opacity(0.14))
        .foregroundColor(Theme.ink)
    }
}
