import SwiftUI
import Combine

// MARK: - Signature help

/// Parameter hints while typing a call: `add(1, |` shows `add(a: number, b: number)`
/// with the current parameter highlighted, floating above the caret.
final class SignatureHelpController: ObservableObject {
    static let shared = SignatureHelpController()

    @Published private(set) var signature: LanguageService.Signature?
    private weak var pane: EditorPane?
    private var host: NSHostingView<SignatureCard>?
    private var paneBag = Set<AnyCancellable>()
    private var bag = Set<AnyCancellable>()
    private var work: DispatchWorkItem?
    private var request = 0
    private var active = false            // a call is open: follow the caret

    func start(_ s: Services) {
        s.activeEditorChanged.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.attach(s.editors.activePane) }
            .store(in: &bag)
    }

    private func attach(_ p: EditorPane?) {
        guard p !== pane else { return }
        hide()
        paneBag = []
        pane = p
        guard let p else { return }
        p.textChanges.receive(on: DispatchQueue.main).sink { [weak self, weak p] change in
            guard let self, let p, p.document.language == .vanta else { return }
            let ns = p.text as NSString
            let end = change.range.location + change.range.length
            if change.delta == 1, end > 0, end <= ns.length {
                let ch = ns.character(at: end - 1)
                if ch == 40 || ch == 44 { self.active = true; self.schedule(0.05); return }   // ( ,
                if ch == 41 { self.schedule(0.05); return }                                  // )
            }
            if self.active { self.schedule(0.12) }
        }.store(in: &paneBag)
        p.selectionChanges.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self, self.active else { return }
            self.schedule(0.12)
        }.store(in: &paneBag)
    }

    /// ⌘⇧Space: show hints for the call around the caret.
    func trigger() {
        if pane !== Services.shared.editors.activePane { attach(Services.shared.editors.activePane) }
        active = true
        schedule(0)
    }

    private func schedule(_ delay: TimeInterval) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.fetch() }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func fetch() {
        guard let p = pane, p.window != nil || Services.shared.isSnapshot, p.textView.allRanges.count == 1 else { hide(); return }
        let caret = p.textView.selectedRange().location
        guard p.textView.selectedRange().length == 0 else { hide(); return }
        request += 1
        let id = request
        let uri = p.document.uri, text = p.text, pos = p.position(of: caret)
        Task { [weak self] in
            let sig = await LanguageService.shared.signatureHelp(uri: uri, text: text, position: pos)
            await MainActor.run {
                guard let self, id == self.request else { return }
                if let sig { self.show(sig, at: caret) } else { self.hide() }
            }
        }
    }

    private func show(_ sig: LanguageService.Signature, at caret: Int) {
        guard let p = pane else { return }
        signature = sig
        if host == nil || host?.superview !== p {
            host?.removeFromSuperview()
            let h = NSHostingView(rootView: SignatureCard(model: self))
            p.addSubview(h)
            host = h
        }
        guard let host else { return }
        host.isHidden = false
        host.rootView = SignatureCard(model: self)
        let size = host.fittingSize
        let caretRect = p.convert(p.caretRect(at: caret), from: p.textView)
        var y = caretRect.minY - size.height - 4
        if y < 2 { y = caretRect.maxY + 4 }
        let x = min(max(4, caretRect.minX - 30), max(4, p.bounds.width - size.width - 8))
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    func hide() {
        active = false
        work?.cancel()
        request += 1
        signature = nil
        host?.isHidden = true
    }

    var isVisible: Bool { signature != nil && host?.isHidden == false }
}

struct SignatureCard: View {
    @ObservedObject var model: SignatureHelpController

    var body: some View {
        if let sig = model.signature {
            VStack(alignment: .leading, spacing: 4) {
                label(sig).lineLimit(1).fixedSize()
                if let doc = sig.documentation, !doc.isEmpty {
                    Text(doc).font(.system(size: 11)).foregroundColor(Theme.muted).lineLimit(2)
                        .frame(maxWidth: 420, alignment: .leading)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel).shadow(color: .black.opacity(0.35), radius: 8, y: 3))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line))
            .fixedSize()
        }
    }

    func label(_ sig: LanguageService.Signature) -> Text {
        let ns = sig.label as NSString
        let font = Font.system(size: 12, design: .monospaced)
        guard sig.active >= 0, sig.active < sig.parameters.count,
              sig.parameters[sig.active].location != NSNotFound,
              NSMaxRange(sig.parameters[sig.active]) <= ns.length else {
            return Text(sig.label).font(font).foregroundColor(Theme.ink)
        }
        let r = sig.parameters[sig.active]
        return Text(ns.substring(to: r.location)).font(font).foregroundColor(Theme.ink)
            + Text(ns.substring(with: r)).font(font.weight(.bold)).foregroundColor(Theme.accent).underline()
            + Text(ns.substring(from: NSMaxRange(r))).font(font).foregroundColor(Theme.ink)
    }
}

// MARK: - Quick fixes

enum QuickFixes {
    /// ⌥↩: the fixes for the problems on the caret's line. One preferred fix is applied
    /// straight away; several are offered in a menu at the caret.
    static func atCursor() {
        let s = Services.shared
        guard let pane = s.editors.activePane else { return }
        let caret = pane.textView.selectedRange().location
        let line = pane.position(of: caret).line
        let range = TextRange(start: TextPosition(line: line, column: 0), end: TextPosition(line: line, column: Int.max / 4))
        let uri = pane.document.uri, text = pane.text
        Task {
            let fixes = await LanguageService.shared.quickFixes(uri: uri, text: text, range: range)
            await MainActor.run {
                guard !fixes.isEmpty else { s.flash("No quick fixes on this line"); return }
                if fixes.count == 1 || s.isSnapshot {
                    apply(fixes[0])
                    return
                }
                let menu = NSMenu()
                for f in fixes {
                    let item = NSMenuItem(title: f.title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
                    item.target = MenuTarget.shared
                    item.representedObject = f.id
                    menu.addItem(item)
                }
                MenuTarget.shared.fixes = fixes
                let r = pane.caretRect(at: caret)
                menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.maxY + 2), in: pane.textView)
            }
        }
    }

    static func apply(_ f: QuickFix) {
        LanguageService.shared.apply(f.edits)
        Services.shared.flash(f.title)
    }

    /// Fixes known locally for a diagnostic (from the server's `data`), for the Problems panel.
    static func local(for d: Diagnostic, uri: URL) -> QuickFix? {
        guard let f = LanguageService.shared.fixes[uri]?.first(where: { $0.range == d.range && $0.message == d.message }) else { return nil }
        return QuickFix(title: "Change to '\(f.replacement)'", uri: uri,
                        edits: [uri: [LSPTextEdit(range: f.range, newText: f.replacement)]], diagnosticRange: f.range, isPreferred: true)
    }

    final class MenuTarget: NSObject {
        static let shared = MenuTarget()
        var fixes: [QuickFix] = []
        @objc func pick(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID, let f = fixes.first(where: { $0.id == id }) else { return }
            QuickFixes.apply(f)
        }
    }
}

/// The Problems panel, with a one-click fix button on problems that have one.
struct LanguageProblemsView: View {
    @ObservedObject var store = DiagnosticsStore.shared
    @ObservedObject var workspace = Services.shared.workspace

    var body: some View {
        let all = store.all.filter { !$0.1.isEmpty }
        if all.isEmpty {
            PlaceholderPanel(title: "No problems", icon: "checkmark.circle",
                             message: "Errors and warnings from `vanta check` appear here as you type.")
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
                        ForEach(diags) { d in row(d, uri) }
                    }
                }.padding(.vertical, 4)
            }
        }
    }

    func row(_ d: Diagnostic, _ uri: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: DiagnosticIcon.symbol(d.severity)).foregroundColor(DiagnosticIcon.color(d.severity))
                .font(.system(size: 11))
            Text(d.message).font(.system(size: 12)).lineLimit(1)
            Text("\(d.source)  [\(d.range.start.line + 1), \(d.range.start.column + 1)]")
                .font(.system(size: 11)).foregroundColor(Theme.muted)
            if let fix = QuickFixes.local(for: d, uri: uri) {
                Button { QuickFixes.apply(fix) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "lightbulb.fill").font(.system(size: 9.5))
                        Text(fix.title).font(.system(size: 11))
                    }
                    .foregroundColor(Theme.amber)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().stroke(Theme.amber.opacity(0.5)))
                }.buttonStyle(.plain).help("Quick Fix (⌥↩)")
            }
            Spacer()
        }
        .padding(.leading, 30).frame(height: 21).contentShape(Rectangle())
        .onTapGesture { Services.shared.editors.open(location: Location(uri: uri, range: d.range)) }
    }
}
