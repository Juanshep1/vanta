import SwiftUI
import AppKit

/// Screen geometry of the focused editor's text, in SwiftUI global (window,
/// top-left origin) coordinates — used to float the ⌘K bar and the lightbulb
/// next to the code they act on.
enum EditorGeometry {
    static func rect(forOffset offset: Int) -> CGRect? {
        guard let pane = Services.shared.editor as? EditorPane, let win = pane.window else { return nil }
        let len = (pane.textView.string as NSString).length
        var actual = NSRange()
        let screen = pane.textView.firstRect(forCharacterRange: NSRange(location: min(max(0, offset), len), length: 0), actualRange: &actual)
        guard screen != .zero else { return nil }
        let wr = win.convertFromScreen(screen)
        let h = win.contentView?.bounds.height ?? win.frame.height
        return CGRect(x: wr.minX, y: h - wr.maxY, width: max(1, wr.width), height: wr.height)
    }

    /// Visible part of the editor text view (global coordinates).
    static var visibleRect: CGRect? {
        guard let pane = Services.shared.editor as? EditorPane, let win = pane.window else { return nil }
        let r = pane.convert(pane.bounds, to: nil)
        let h = win.contentView?.bounds.height ?? win.frame.height
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}

/// The ⌘K prompt bar, floating just above (or below) the region being edited.
struct InlineEditView: View {
    @ObservedObject var model = InlineEditController.shared
    @ObservedObject var editors = Services.shared.editors

    var body: some View {
        if model.phase != .idle {
            GeometryReader { geo in
                let frame = geo.frame(in: .global)
                let pos = position(in: frame)
                InlineEditBar()
                    .frame(width: min(540, max(320, frame.width - 40)))
                    .offset(x: pos.x, y: pos.y)
            }
            .id(model.anchorRevision)
        }
    }

    func position(in area: CGRect) -> CGPoint {
        let width = min(540, max(320, area.width - 40))
        let barH: CGFloat = model.error == nil ? 46 : 70
        guard let line = EditorGeometry.rect(forOffset: model.range.location) else { return CGPoint(x: (area.width - width) / 2, y: 56) }
        var x = line.minX - area.minX - 10
        x = min(max(16, x), max(16, area.width - width - 16))
        var y = line.minY - area.minY - barH - 6 - CGFloat(model.phase == .prompting ? 0 : model.leadingInserted) * line.height
        if y < 40 {   // no room above: go below the whole region (after any phantom diff lines)
            if model.phase != .prompting, let after = EditorGeometry.rect(forOffset: NSMaxRange(model.range)) {
                y = after.minY - area.minY + 4
            } else {
                y = line.maxY - area.minY + 6
            }
        }
        y = min(max(36, y), max(36, area.height - barH - 10))
        return CGPoint(x: x, y: y)
    }
}

struct InlineEditBar: View {
    @ObservedObject var model = InlineEditController.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.accent)
                switch model.phase {
                case .generating:
                    ProgressView().controlSize(.small)
                    Text(model.isGenerate ? "Vee is writing new code…" : "Vee is rewriting \(model.regionLabel)…")
                        .font(.system(size: 12.5)).foregroundColor(Theme.muted)
                    Spacer()
                    pill("Stop", key: "Esc", color: Theme.red) { model.stopGenerating() }
                case .reviewing:
                    TextField("Ask for changes, or ⌘↩ to accept", text: $model.prompt)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                        .onSubmit { model.submit() }
                        .onExitCommand { model.cancel() }
                    pill("Accept", key: "⌘↩", color: Theme.green, filled: true) { model.accept() }
                    pill("Reject", key: "Esc", color: Theme.red) { model.cancel() }
                default:
                    TextField(model.isGenerate ? "Describe the code to generate…" : "Edit \(model.regionLabel): tell Vee what to change…",
                              text: $model.prompt)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($focused)
                        .onSubmit { model.submit() }
                        .onExitCommand { model.cancel() }
                    pill(model.isGenerate ? "Generate" : "Edit", key: "↩", color: Theme.accent, filled: true) { model.submit() }
                    Button { model.cancel() } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundColor(Theme.muted).help("Close (Esc)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            if let err = model.error {
                Text(err).font(.system(size: 11.5)).foregroundColor(Theme.red)
                    .padding(.horizontal, 12).padding(.bottom, 9).fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel).shadow(color: .black.opacity(0.4), radius: 16, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.65)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _, _ in focused = true }
    }

    func pill(_ title: String, key: String, color: Color, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(key).font(.system(size: 10)).opacity(0.75)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(filled ? color.opacity(0.9) : color.opacity(0.13)))
            .foregroundColor(filled ? .white : color)
        }.buttonStyle(.plain)
    }
}

/// A lightbulb at the end of the caret's line when that line has a problem:
/// click for an explanation and a proposed fix.
struct FixLightbulb: View {
    @ObservedObject var editors = Services.shared.editors
    @ObservedObject var diagnostics = DiagnosticsStore.shared
    @ObservedObject var inline = InlineEditController.shared
    @ObservedObject var vee = VeeAssistant.shared
    @State private var hover = false

    var body: some View {
        if inline.phase == .idle, !vee.busy, let ed = Services.shared.editor, !ed.hasInlineDiff,
           let d = diagnostics.diagnostics(for: ed.document.uri).first(where: { $0.range.start.line == editors.cursor.line && $0.severity <= .warning }) {
            GeometryReader { geo in
                let area = geo.frame(in: .global)
                if let p = anchor(ed, area) {
                    Button { vee.fixDiagnostic(d, uri: ed.document.uri) } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "lightbulb.fill").font(.system(size: 10.5))
                            if hover { Text("Fix with Vee").font(.system(size: 10.5, weight: .semibold)) }
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.amber.opacity(hover ? 0.95 : 0.22)))
                        .foregroundColor(hover ? .black : Theme.amber)
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 }
                    .help("Vee: explain “\(d.message)” and propose a fix")
                    .offset(x: p.x, y: p.y)
                }
            }
        }
    }

    func anchor(_ ed: EditorController, _ area: CGRect) -> CGPoint? {
        let ns = ed.text as NSString
        let line = editors.cursor.line
        let lines = ed.document.lines
        guard line < lines.count else { return nil }
        let end = NSMaxRange(lines.contentRange(of: line, in: ns))
        guard let r = EditorGeometry.rect(forOffset: end), let vis = EditorGeometry.visibleRect, vis.contains(CGPoint(x: vis.midX, y: r.midY)) else { return nil }
        return CGPoint(x: min(r.maxX - area.minX + 14, area.width - 120), y: r.minY - area.minY)
    }
}
